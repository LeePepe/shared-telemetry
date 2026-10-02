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
        let sending = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        telemetry.track(name: "next", properties: [:])
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
