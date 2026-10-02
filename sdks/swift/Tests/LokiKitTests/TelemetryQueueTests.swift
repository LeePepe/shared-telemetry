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

    func testUnsearchableDirectoryRemovalIsCountedAndRetryable() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        q.enqueue(TelemetryEvent(name: "retained"))
        let id = try XCTUnwrap(q.loadPersistedBatches().first?.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path) }
        XCTAssertThrowsError(try q.removeBatch(id: id), "EACCES is not ENOENT")
        XCTAssertEqual(q.persistenceFailureCount, 1)
        XCTAssertThrowsError(try q.removeBatch(id: id))
        XCTAssertEqual(q.persistenceFailureCount, 2, "Count each actual removal attempt")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        XCTAssertEqual(try q.loadPersistedBatches().map(\.id), [id])
        try q.removeBatch(id: id)
        XCTAssertTrue(try q.batchesForFlush().isEmpty)
        XCTAssertEqual(q.persistenceFailureCount, 2)
    }

    func testUnsearchableAncestorReadIsCountedAndRetryable() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir.appendingPathComponent("queue"))
        q.enqueue(TelemetryEvent(name: "retained"))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path) }
        XCTAssertThrowsError(try q.loadPersistedBatches(), "EACCES is not an empty queue")
        XCTAssertEqual(q.persistenceFailureCount, 1)
        XCTAssertThrowsError(try q.loadPersistedBatches())
        XCTAssertEqual(q.persistenceFailureCount, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        XCTAssertEqual(try q.loadPersistedBatches().flatMap(\.events).map(\.name), ["retained"])
        XCTAssertEqual(q.persistenceFailureCount, 2)
    }

    func testRemovingActuallyMissingFileDoesNotCountFailure() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir.appendingPathComponent("missing"))
        try q.removeBatch(id: UUID())
        XCTAssertTrue(try q.loadPersistedBatches().isEmpty)
        q.enqueue(TelemetryEvent(name: "acknowledged"))
        let id = try XCTUnwrap(q.loadPersistedBatches().first?.id)
        try FileManager.default.removeItem(at: q.storeDirectory.appendingPathComponent("\(id).json"))
        try q.removeBatch(id: id)
        XCTAssertTrue(try q.batchesForFlush().isEmpty)
        XCTAssertEqual(q.persistenceFailureCount, 0)
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

    func testEnqueueRotatesBoundedLegacyFilesWithoutDroppingOrRewritingSealedBatches() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sealed: [URL: Data] = [:]
        for chunk in 0..<4 {
            for index in (chunk * 64)..<((chunk + 1) * 64) {
                q.enqueue(TelemetryEvent(name: "synthetic.\(index)"))
            }
            for (url, bytes) in sealed {
                XCTAssertEqual(try Data(contentsOf: url), bytes, "Later enqueue must not grow a sealed batch")
            }
            let files = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, chunk + 1)
            for url in files {
                XCTAssertNotNil(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
                let bytes = try Data(contentsOf: url)
                XCTAssertEqual(try decoder.decode([TelemetryEvent].self, from: bytes).count, 64)
                sealed[url] = bytes
            }
        }
        let restored = try TelemetryQueue(storeDirectory: tmpDir).loadPersistedBatches().flatMap(\.events)
        XCTAssertEqual(restored.count, 256)
        XCTAssertEqual(Set(restored.map(\.name)), Set((0..<256).map { "synthetic.\($0)" }))
        XCTAssertEqual(q.persistenceFailureCount, 0)
    }

    func testSynchronousEnqueueLatencySampleAndFullBatchRecovery() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        var durations: [Double] = []
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<5_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            q.enqueue(TelemetryEvent(name: "synthetic.\(index)", properties: ["count": "1"]))
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            if (index + 1).isMultiple(of: 1_000) {
                let window = durations.suffix(200).sorted()
                print("ENQUEUE_WINDOW_MS total=\(index + 1) median=\(window[100]) p95=\(window[190]) max=\(window[199])")
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let restored = try TelemetryQueue(storeDirectory: tmpDir).loadPersistedBatches().flatMap(\.events)
        XCTAssertEqual(restored.count, 5_000)
        XCTAssertEqual(Set(restored.map(\.name)), Set((0..<5_000).map { "synthetic.\($0)" }))
        XCTAssertEqual(q.persistenceFailureCount, 0)
        durations.sort()
        // Indicative host timings only: correctness is gated by recovery/rotation, not the clock.
        print("ENQUEUE_LATENCY_MS sample=5000 total=\(elapsed) median=\(durations[2500]) p95=\(durations[4750]) max=\(durations[4999])")
    }

    func testRotationRetainsFailedRewritePrefixAndMemorySuffixAcrossRemovalFailure() throws {
        let q = TelemetryQueue(storeDirectory: tmpDir)
        for index in 0..<63 { q.enqueue(TelemetryEvent(name: "synthetic.\(index)")) }
        let originalID = try XCTUnwrap(q.loadPersistedBatches().first?.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path) }
        q.enqueue(TelemetryEvent(name: "synthetic.63"))
        q.enqueue(TelemetryEvent(name: "synthetic.64"))
        XCTAssertEqual(q.persistenceFailureCount, 2)
        XCTAssertEqual(try q.loadPersistedBatches().first?.events.count, 63, "Failed rewrite leaves the durable prefix")
        let snapshot = try q.batchesForFlush()
        XCTAssertEqual(snapshot.map(\.events.count), [64, 1])
        XCTAssertEqual(snapshot.first?.id, originalID)
        XCTAssertEqual(snapshot.flatMap(\.events).map(\.name), (0..<65).map { "synthetic.\($0)" })
        XCTAssertEqual(q.persistenceFailureCount, 4)
        XCTAssertThrowsError(try q.removeBatch(id: originalID))
        XCTAssertEqual(q.persistenceFailureCount, 5)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        let recovered = try q.batchesForFlush()
        XCTAssertEqual(Set(recovered.map(\.id)), Set(snapshot.map(\.id)))
        let restarted = try TelemetryQueue(storeDirectory: tmpDir).loadPersistedBatches().flatMap(\.events)
        XCTAssertEqual(restarted.count, 65)
        XCTAssertEqual(Set(restarted.map(\.name)), Set((0..<65).map { "synthetic.\($0)" }))
        for batch in recovered { try q.removeBatch(id: batch.id) }
        XCTAssertTrue(try q.batchesForFlush().isEmpty)
        XCTAssertEqual(q.persistenceFailureCount, 5)
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

    func testRestartUsesLegacyFileOrderRatherThanLostInMemoryOrder() throws {
        let queue = TelemetryQueue(storeDirectory: tmpDir)
        queue.enqueue(TelemetryEvent(name: "first"))
        let firstID = try XCTUnwrap(queue.batchesForFlush().first?.id)
        queue.enqueue(TelemetryEvent(name: "second"))
        let secondID = try XCTUnwrap(queue.loadPersistedBatches().first { $0.id != firstID }?.id)
        // Simulate creation times refreshed by an older batch's atomic retry.
        for (id, seconds) in [(firstID, 1_700_000_020.0), (secondID, 1_700_000_010.0)] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: tmpDir.appendingPathComponent("\(id).json").path)
        }
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["first", "second"])
        let restarted = TelemetryQueue(storeDirectory: tmpDir)
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["second", "first"],
                       "Legacy files contain no durable enqueue-order key; restart keeps file-creation order")
        XCTAssertEqual(queue.persistenceFailureCount, 0)
        XCTAssertEqual(restarted.persistenceFailureCount, 0)
    }
}
