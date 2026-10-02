import XCTest
@testable import LokiKit

final class TelemetryQueueTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - Durable enqueue

    func testEnqueueAndSnapshot() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        let e1 = TelemetryEvent(name: "a", properties: ["k": "v"])
        let e2 = TelemetryEvent(name: "b")

        q.enqueue(e1)
        q.enqueue(e2)

        let taken = try q.batchesForFlush().flatMap(\.events)
        XCTAssertEqual(taken.count, 2)
        XCTAssertEqual(taken[0].name, "a")
        XCTAssertEqual(taken[1].name, "b")
    }

    func testSnapshotRetainsEventsUntilAcknowledged() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        q.enqueue(TelemetryEvent(name: "x"))
        let first = try q.batchesForFlush()

        let second = try q.batchesForFlush()
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(second.flatMap(\.events).map(\.name), ["x"])
        try q.removeBatch(id: XCTUnwrap(first.first?.id))
        XCTAssertTrue(try q.batchesForFlush().isEmpty)
        XCTAssertTrue(try q.loadPersistedBatches().isEmpty)
    }

    func testPersistedCountTracksEveryEnqueue() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        let count0 = try q.loadPersistedBatches().flatMap(\.events).count
        XCTAssertEqual(count0, 0)
        q.enqueue(TelemetryEvent(name: "x"))
        let count1 = try q.loadPersistedBatches().flatMap(\.events).count
        XCTAssertEqual(count1, 1)
        q.enqueue(TelemetryEvent(name: "y"))
        let count2 = try q.loadPersistedBatches().flatMap(\.events).count
        XCTAssertEqual(count2, 2)
    }

    // MARK: - Disk persistence

    func testPersistAndLoad() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        let events = [
            TelemetryEvent(name: "transcription.completed", properties: ["duration_ms": "1234"]),
            TelemetryEvent(name: "refinement.completed", properties: ["duration_ms": "567"])
        ]

        let id = UUID()
        try q.persistBatch(id: id, events: events)

        let loaded = try q.loadPersistedBatches()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].events.count, 2)
        XCTAssertEqual(loaded[0].events[0].name, "transcription.completed")
        XCTAssertEqual(loaded[0].events[0].properties["duration_ms"], "1234")
    }

    func testRemoveBatch() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        let id = UUID()
        try q.persistBatch(id: id, events: [TelemetryEvent(name: "x")])
        try q.removeBatch(id: id)

        let loaded = try q.loadPersistedBatches()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLoadNonExistentDirectory() async throws {
        let noDir = tmpDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let q = TelemetryQueue(storeDirectory: noDir)

        let loaded = try q.loadPersistedBatches()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testPersistRoundtripPreservesAllFields() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let event = TelemetryEvent(
            name: "test.event",
            properties: ["duration_ms": "999", "provider": "appleIntelligence"],
            timestamp: fixedDate
        )

        let id = UUID()
        try q.persistBatch(id: id, events: [event])

        let loaded = try q.loadPersistedBatches()
        let loadedEvent = try XCTUnwrap(loaded.first?.events.first)

        XCTAssertEqual(loadedEvent.name, event.name)
        XCTAssertEqual(loadedEvent.properties["duration_ms"], "999")
        XCTAssertEqual(loadedEvent.properties["provider"], "appleIntelligence")
        XCTAssertEqual(
            loadedEvent.timestamp.timeIntervalSince1970,
            event.timestamp.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testMultipleBatchesLoadedInOrder() async throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)

        let id1 = UUID()
        let id2 = UUID()
        try q.persistBatch(id: id1, events: [TelemetryEvent(name: "first")])
        // Small sleep to ensure different creation timestamps
        try await Task.sleep(for: .milliseconds(10))
        try q.persistBatch(id: id2, events: [TelemetryEvent(name: "second")])

        let loaded = try q.loadPersistedBatches()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].events[0].name, "first")
        XCTAssertEqual(loaded[1].events[0].name, "second")
    }

    func testUnreadableBatchIsRetainedAndCountedWhileHealthyBatchLoads() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        let corrupt = tmpDir.appendingPathComponent("\(UUID()).json")
        try Data("not-json".utf8).write(to: corrupt)
        q.enqueue(TelemetryEvent(name: "healthy"))
        XCTAssertEqual(try q.loadPersistedBatches().flatMap(\.events).map(\.name), ["healthy"])
        XCTAssertEqual(q.persistenceFailureCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testReadFailureIsCountedAndPropagates() throws {
        let blocked = tmpDir.appendingPathComponent("file")
        try Data().write(to: blocked)
        let q = TelemetryQueue(storeDirectory: blocked)
        XCTAssertThrowsError(try q.loadPersistedBatches())
        XCTAssertEqual(q.persistenceFailureCount, 1)
    }

    func testRemovalFailureKeepsBatchAndCountsOncePerAttempt() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        q.enqueue(TelemetryEvent(name: "retained"))
        let id = try XCTUnwrap(q.loadPersistedBatches().first?.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path) }
        XCTAssertThrowsError(try q.removeBatch(id: id))
        XCTAssertEqual(q.persistenceFailureCount, 1)
        XCTAssertEqual(try q.loadPersistedBatches().map(\.id), [id])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        try q.removeBatch(id: id)
        XCTAssertEqual(q.persistenceFailureCount, 1)
        XCTAssertTrue(try q.loadPersistedBatches().isEmpty)
    }

    func testLegacyBatchLoadsAndNewBatchIsReadableByLegacyDecoder() throws {
        let legacyID = UUID()
        let legacy = "[{\"name\":\"legacy\",\"properties\":{\"count\":\"2\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}]"
        try Data(legacy.utf8).write(to: tmpDir.appendingPathComponent("\(legacyID).json"))
        let q = TelemetryQueue(storeDirectory: tmpDir)
        XCTAssertEqual(try q.batchesForFlush().first?.events.first?.properties["count"], "2")
        q.enqueue(TelemetryEvent(name: "new"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let restored = try files.flatMap { try decoder.decode([TelemetryEvent].self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(Set(restored.map(\.name)), ["legacy", "new"])
    }

    func testFailedRewriteKeepsDurablePrefixAndRetriesMemorySuffix() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        q.enqueue(TelemetryEvent(name: "durable"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path) }
        q.enqueue(TelemetryEvent(name: "memory-only"))
        XCTAssertEqual(q.persistenceFailureCount, 1)
        XCTAssertEqual(try q.loadPersistedBatches().flatMap(\.events).map(\.name), ["durable"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        XCTAssertEqual(try q.batchesForFlush().flatMap(\.events).map(\.name), ["durable", "memory-only"])
        XCTAssertEqual(try TelemetryQueue(storeDirectory: tmpDir).loadPersistedBatches()
            .flatMap(\.events).map(\.name), ["durable", "memory-only"])
        XCTAssertEqual(q.persistenceFailureCount, 1)
    }

    func testSynchronousEnqueueLatencySampleAndFullBatchRecovery() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        var durations: [Double] = []
        for index in 0..<200 {
            let start = Date()
            q.enqueue(TelemetryEvent(name: "synthetic.\(index)", properties: ["count": "1"]))
            durations.append(Date().timeIntervalSince(start) * 1_000)
        }
        XCTAssertEqual(try TelemetryQueue(storeDirectory: tmpDir).loadPersistedBatches().flatMap(\.events).count, 200)
        XCTAssertEqual(q.persistenceFailureCount, 0)
        durations.sort()
        print("ENQUEUE_LATENCY_MS sample=200 median=\(durations[100]) p95=\(durations[190]) max=\(durations[199])")
    }

    func testConcurrentEnqueuesPersistEveryEvent() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            q.enqueue(TelemetryEvent(name: "synthetic.\(index)"))
        }
        let restored = try TelemetryQueue(storeDirectory: tmpDir).loadPersistedBatches().flatMap(\.events)
        XCTAssertEqual(restored.count, 50)
        XCTAssertEqual(Set(restored.map(\.name)), Set((0..<50).map { "synthetic.\($0)" }))
        XCTAssertEqual(q.persistenceFailureCount, 0)
    }
}
