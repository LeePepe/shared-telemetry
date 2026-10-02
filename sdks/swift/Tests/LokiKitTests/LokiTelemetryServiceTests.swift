import Foundation
import Synchronization
import XCTest
@testable import LokiKit

final class LokiTelemetryServiceTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LokiService-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryURLProtocol.self]
        session = URLSession(configuration: config)
        TelemetryURLProtocol.state.withLock { $0 = .init() }
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: directory)
    }

    private func service(queue: TelemetryQueue? = nil) -> LokiTelemetryService {
        LokiTelemetryService(
            queue: queue ?? TelemetryQueue(storeDirectory: directory),
            shipper: LokiShipper(endpoint: URL(string: "https://telemetry.example.invalid/push")!, session: session)
        )
    }

    func testFailureRetainsBatchAndRestartRetriesBeforeSuccessfulDeletion() async throws {
        let first = service()
        let event = TelemetryEvent(name: "synthetic", properties: ["count": "1"],
                                   timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        first.track(event)
        let observer = TelemetryQueue(storeDirectory: directory)
        let original = try observer.loadPersistedBatches()
        XCTAssertEqual(original.count, 1)
        TelemetryURLProtocol.state.withLock { $0.status = 503 }
        await first.flush()
        XCTAssertEqual(try observer.loadPersistedBatches().map(\.id), original.map(\.id))

        let restarted = service()
        TelemetryURLProtocol.state.withLock { $0.status = 204 }
        await restarted.flush()
        await restarted.flush()
        XCTAssertTrue(try observer.loadPersistedBatches().isEmpty)
        let bodies = TelemetryURLProtocol.state.withLock { $0.bodies }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary)
        XCTAssertEqual(restarted.persistenceFailureCount, 0)
    }

    func testImmediateFlushIncludesAllTracksWithOriginalTimestampPrecision() async throws {
        let telemetry = service()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        telemetry.track(TelemetryEvent(name: "first", timestamp: timestamp))
        telemetry.track(name: "second", properties: [:])
        await telemetry.flush()
        let bodies = TelemetryURLProtocol.state.withLock { $0.bodies }
        XCTAssertEqual(bodies.count, 1, "Keep current events batched, not one HTTP request per event")
        let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("first"))
        XCTAssertTrue(body.contains("second"))
        XCTAssertTrue(body.contains(String(Int64(timestamp.timeIntervalSince1970 * 1_000_000_000))))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches().isEmpty)
    }

    func testFailedFinalEnqueueRewriteDoesNotSendNewerBatchBeforeOlderBatch() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let telemetry = service(queue: queue)
        for index in 0..<63 {
            telemetry.track(name: "synthetic.ordered", properties: ["sequence": "\(index)"])
        }
        let olderID = try XCTUnwrap(queue.loadPersistedBatches().first?.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        telemetry.track(name: "synthetic.ordered", properties: ["sequence": "63"])
        XCTAssertEqual(telemetry.persistenceFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        telemetry.track(name: "synthetic.ordered", properties: ["sequence": "64"])
        let before = try queue.loadPersistedBatches()
        XCTAssertEqual(before.map(\.events.count), [63, 1])
        let newerID = try XCTUnwrap(before.last?.id)
        // Separate file dates without a clock/sleep race. Retrying A's atomic write
        // can refresh its creation time past B; that must not change live send order.
        for (id, seconds) in [(olderID, 1_700_000_000.0), (newerID, 1_700_000_010.0)] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: directory.appendingPathComponent("\(id).json").path)
        }
        XCTAssertEqual(try queue.loadPersistedBatches().map(\.id), [olderID, newerID])

        await telemetry.flush()
        await telemetry.flush()
        XCTAssertEqual(try sentLines(), [(0..<64).map { "sequence=\($0)" }, ["sequence=64"]],
                       "Every event, including the failed-write suffix, must be sent once in live batch order")
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertTrue(try queue.loadPersistedBatches().isEmpty)
        XCTAssertEqual(telemetry.persistenceFailureCount, 1)
    }

    func testRecoveredHistoryPrecedesKnownBatchesAndMemoryOnlyFallbackWithoutDuplicates() async throws {
        let history = TelemetryQueue(storeDirectory: directory)
        let firstID = UUID()
        let secondID = UUID()
        try history.persistBatch(id: firstID, events: [TelemetryEvent(name: "synthetic.ordered",
            properties: ["sequence": "history.first"])])
        try history.persistBatch(id: secondID, events: [TelemetryEvent(name: "synthetic.ordered",
            properties: ["sequence": "history.second"])])
        let queue = TelemetryQueue(storeDirectory: directory)
        let telemetry = service(queue: queue)
        for index in 0..<64 {
            telemetry.track(name: "synthetic.ordered", properties: ["sequence": "\(index)"])
        }
        let currentID = try XCTUnwrap(queue.loadPersistedBatches()
            .first { $0.id != firstID && $0.id != secondID }?.id)
        // History's own disk order is authoritative, even if filesystem dates put
        // a known current-process batch before it. Event timestamps are not a FIFO key.
        for (id, seconds) in [(currentID, 1_700_000_000.0), (secondID, 1_700_000_020.0),
                              (firstID, 1_700_000_010.0)] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: directory.appendingPathComponent("\(id).json").path)
        }
        XCTAssertEqual(try queue.loadPersistedBatches().map(\.id), [currentID, firstID, secondID])
        let store = try XCTUnwrap(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        telemetry.track(name: "synthetic.ordered", properties: ["sequence": "64"])
        XCTAssertEqual(telemetry.persistenceFailureCount, 1)
        TelemetryURLProtocol.state.withLock {
            $0.onRequest = {
                // Snapshot retries have already failed. Restore only for post-send
                // deletion, keeping the final event memory-only in this snapshot.
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
                } catch {
                    XCTFail("Failed to restore synthetic store permissions")
                }
            }
        }

        await telemetry.flush()
        await telemetry.flush()
        XCTAssertEqual(try sentLines(), [["sequence=history.first"], ["sequence=history.second"],
            (0..<64).map { "sequence=\($0)" }, ["sequence=64"]])
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertTrue(try queue.loadPersistedBatches().isEmpty)
        XCTAssertEqual(telemetry.persistenceFailureCount, 2, "Only enqueue and snapshot write retries failed")
    }

    private func sentLines() throws -> [[String]] {
        try TelemetryURLProtocol.state.withLock { $0.bodies }.map { data in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let streams = try XCTUnwrap(body["streams"] as? [[String: Any]])
            XCTAssertEqual(streams.count, 1, "Ordering fixtures use a single event name per request")
            let values = try XCTUnwrap(streams.first?["values"] as? [[String]])
            return try values.map { value in
                XCTAssertEqual(value.count, 2)
                return try XCTUnwrap(value.last)
            }
        }
    }

    func testConcurrentFlushDoesNotDuplicateAndEnqueueDuringSendSurvives() async throws {
        let telemetry = service()
        let entered = expectation(description: "transport started")
        let release = DispatchSemaphore(value: 0)
        TelemetryURLProtocol.state.withLock {
            $0.onRequest = {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        telemetry.track(name: "in-flight", properties: [:])
        let original = try XCTUnwrap(TelemetryQueue(storeDirectory: directory).loadPersistedBatches().first)
        let originalFile = directory.appendingPathComponent("\(original.id).json")
        let frozenBytes = try Data(contentsOf: originalFile)
        let sending = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        telemetry.track(name: "next", properties: [:])
        XCTAssertEqual(try Data(contentsOf: originalFile), frozenBytes, "In-flight data must remain frozen")
        await telemetry.flush()
        XCTAssertEqual(TelemetryURLProtocol.state.withLock { $0.bodies.count }, 1)
        TelemetryURLProtocol.state.withLock { $0.onRequest = nil }
        release.signal()
        await sending.value
        let remaining = try TelemetryQueue(storeDirectory: directory).loadPersistedBatches()
        XCTAssertEqual(remaining.flatMap(\.events).map(\.name), ["next"])
        await telemetry.flush()
        XCTAssertEqual(TelemetryURLProtocol.state.withLock { $0.bodies.count }, 2)
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches().isEmpty)
    }

    func testFailedWriteIsCountedAndMemoryRecoversWhenStorageReturns() async throws {
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("synthetic".utf8).write(to: blocked)
        let queue = TelemetryQueue(storeDirectory: blocked)
        let telemetry = service(queue: queue)
        telemetry.track(name: "retained", properties: [:])
        XCTAssertEqual(telemetry.persistenceFailureCount, 1)
        XCTAssertEqual(telemetry.persistenceFailureCount, 1, "Reads must not retry or reset counters")
        try FileManager.default.removeItem(at: blocked)
        let snapshot = try queue.batchesForFlush()
        XCTAssertEqual(snapshot.flatMap(\.events).map(\.name), ["retained"])
        XCTAssertEqual(try TelemetryQueue(storeDirectory: blocked).loadPersistedBatches().count, 1)
        await telemetry.flush()
        XCTAssertTrue(try queue.loadPersistedBatches().isEmpty)
        XCTAssertEqual(telemetry.persistenceFailureCount, 1)
    }

    func testBlockedStoreStillDeliversMemoryAndRetainsFailedTransport() async throws {
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("synthetic".utf8).write(to: blocked)
        let queue = TelemetryQueue(storeDirectory: blocked)
        let telemetry = service(queue: queue)
        telemetry.track(name: "memory-only", properties: [:])
        XCTAssertEqual(telemetry.persistenceFailureCount, 1)

        TelemetryURLProtocol.state.withLock { $0.status = 503 }
        await telemetry.flush()
        XCTAssertEqual(TelemetryURLProtocol.state.withLock { $0.bodies.count }, 1)
        XCTAssertEqual(telemetry.persistenceFailureCount, 3, "Enqueue, retry write and directory read failed")

        TelemetryURLProtocol.state.withLock { $0.status = 204 }
        await telemetry.flush()
        let bodies = TelemetryURLProtocol.state.withLock { $0.bodies }
        XCTAssertEqual(bodies.count, 2, "Failed transport must retain the memory event for retry")
        XCTAssertTrue(String(decoding: try XCTUnwrap(bodies.last), as: UTF8.self).contains("memory-only"))
        XCTAssertEqual(try Data(contentsOf: blocked), Data("synthetic".utf8), "Store stays blocked throughout both flushes")
        XCTAssertEqual(telemetry.persistenceFailureCount, 6, "Retry write, read and removal also failed")
        try FileManager.default.removeItem(at: blocked)
        await telemetry.flush()
        XCTAssertEqual(TelemetryURLProtocol.state.withLock { $0.bodies.count }, 3,
                       "An unconfirmed removal retains retryable work; duplicate delivery is possible")
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertEqual(telemetry.persistenceFailureCount, 6)
    }

    func testDisabledServiceDoesNotEnqueueOrErasePendingData() async throws {
        let telemetry = service()
        telemetry.track(name: "kept", properties: [:])
        telemetry.isEnabled = false
        telemetry.track(name: "ignored", properties: [:])
        await telemetry.flush()
        XCTAssertTrue(TelemetryURLProtocol.state.withLock { $0.bodies.isEmpty })
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches()
            .flatMap(\.events).map(\.name), ["kept"])
        telemetry.isEnabled = true
        await telemetry.flush()
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches().isEmpty)
    }

    func testOfflineAndUnauthorizedResponsesRetainEvents() async throws {
        let telemetry = service()
        telemetry.track(name: "offline", properties: [:])
        TelemetryURLProtocol.state.withLock { $0.error = URLError(.notConnectedToInternet) }
        await telemetry.flush()
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches().count, 1)
        TelemetryURLProtocol.state.withLock { $0.error = nil; $0.status = 403 }
        await telemetry.flush()
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches().count, 1)
        XCTAssertEqual(telemetry.persistenceFailureCount, 0)
        TelemetryURLProtocol.state.withLock { $0.status = 204 }
        await telemetry.flush()
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).loadPersistedBatches().isEmpty)
    }
}

private final class TelemetryURLProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var status = 204
        var bodies: [Data] = []
        var onRequest: (@Sendable () -> Void)?
        var error: URLError?
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, onRequest, error) = Self.state.withLock {
            $0.bodies.append(body)
            return ($0.status, $0.onRequest, $0.error)
        }
        onRequest?()
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
