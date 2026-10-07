import Foundation
import XCTest
@testable import LokiKit

final class TelemetryQueueCapacityTests: XCTestCase {
    private var directory: URL!
    // Independent legacy wire fixture: exactly one single-character event.
    private let eventBytes = Data(#"[{"name":"a","properties":{},"timestamp":"2023-11-14T22:13:20Z"}]"#.utf8).count

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueCapacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func event(_ name: String) -> TelemetryEvent {
        TelemetryEvent(name: name, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testExactBoundaryAcceptsEventButOneByteOversizeIsDroppedAndCountedAcrossRestart() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        queue.enqueue(event("a"))
        queue.enqueue(event("bb"))
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["a"])
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        XCTAssertEqual(restarted.droppedEventCount, 1)
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["a"])
    }

    func testOverflowEvictsOldestBatchAndCountsItsEventsOnceAfterRestart() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 3)
        queue.enqueue(event("a"))
        queue.enqueue(event("b"))
        _ = try queue.batchesForFlush() // Seal the two-event oldest batch.
        queue.enqueue(event("c"))
        _ = try queue.batchesForFlush()
        XCTAssertEqual(queue.droppedEventCount, 0)
        queue.enqueue(event("d"))
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["c", "d"])
        XCTAssertEqual(queue.droppedEventCount, 2, "Count events, not evicted files")
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 3)
        XCTAssertEqual(restarted.droppedEventCount, 2)
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["c", "d"])
        XCTAssertEqual(restarted.droppedEventCount, 2, "Loading does not recount an eviction")
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testEvictingEarlierBatchKeepsCurrentBatchAppendableAcrossRestart() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 3)
        queue.enqueue(event("a"))
        queue.enqueue(event("b"))
        let oldestID = try XCTUnwrap(queue.batchesForFlush().first?.id)
        queue.enqueue(event("c"))
        let currentID = try XCTUnwrap(queue.loadPersistedBatches().first { $0.id != oldestID }?.id)
        XCTAssertEqual(queue.droppedEventCount, 0)

        // Growing the current batch evicts the earlier two-event batch. Do not
        // take a flush snapshot here: it would seal the batch before the append.
        queue.enqueue(event("d"))
        let afterEviction = try queue.loadPersistedBatches()
        XCTAssertEqual(afterEviction.map(\.id), [currentID])
        XCTAssertEqual(afterEviction.flatMap(\.events).map(\.name), ["c", "d"])
        XCTAssertEqual(queue.droppedEventCount, 2)

        queue.enqueue(event("e"))
        let afterAppend = try queue.batchesForFlush()
        XCTAssertEqual(afterAppend.map(\.id), [currentID], "Append to the surviving batch, not a replacement")
        XCTAssertEqual(afterAppend.flatMap(\.events).map(\.name), ["c", "d", "e"])
        XCTAssertEqual(queue.droppedEventCount, 2)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 3)
        let recovered = try restarted.loadPersistedBatches()
        XCTAssertEqual(recovered.map(\.id), [currentID])
        XCTAssertEqual(recovered.flatMap(\.events).map(\.name), ["c", "d", "e"])
        XCTAssertEqual(restarted.droppedEventCount, 2)
        XCTAssertEqual(restarted.persistenceFailureCount, 0)
    }

    func testOverflowDuringFlushKeepsCapturedBatchUntilFlushEnds() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        queue.enqueue(event("a"))
        XCTAssertTrue(queue.beginFlush())
        let batch = try XCTUnwrap(queue.batchesForFlush().first)
        let original = try Data(contentsOf: directory.appendingPathComponent("\(batch.id).json"))
        queue.enqueue(event("b"))
        XCTAssertEqual(queue.droppedEventCount, 0, "Do not evict a request's source/identity while it owns the flush")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(batch.id).json")), original)
        queue.endFlush()
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["b"])
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 0, "Deferred quota admission is not a failed filesystem call")
    }

    func testBlobSidecarReservationCannotExceedCapOrOutliveItsEvictedSource() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 512)
        queue.enqueue(event("a"))
        XCTAssertTrue(queue.beginFlush())
        let batch = try XCTUnwrap(queue.batchesForFlush(retryingWrites: false).first)
        let journal = AzureBlobBatch(version: 1, queueID: batch.id,
            containerURL: URL(string: "https://blob.example.invalid/telemetry")!,
            path: ["app", "build", "2023-11-14", "install", "batch.ndjson.gz"],
            sourceDigest: Data(repeating: 0, count: 32), body: Data(repeating: 1, count: 512),
            mayHaveBeenSent: true)
        XCTAssertThrowsError(try journal.save(queue: queue))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(batch.id).azure-blob").path))
        XCTAssertEqual(queue.droppedEventCount, 0, "The captured snapshot stays intact until release")
        queue.endFlush()
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(batch.id).json").path))
        XCTAssertEqual(TelemetryQueue(storeDirectory: directory, maxDiskBytes: 512).droppedEventCount, 1)
    }

    private func journal(id: UUID) -> AzureBlobBatch {
        AzureBlobBatch(version: 1, queueID: id,
            containerURL: URL(string: "https://blob.example.invalid/telemetry")!,
            path: ["app", "build", "2023-11-14", "install", "batch.ndjson.gz"],
            sourceDigest: Data(repeating: 0, count: 32), body: Data(repeating: 1, count: 64),
            mayHaveBeenSent: true)
    }

    func testSidecarBytesTriggerWholePairEvictionWithoutOrphanFiles() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2048)
        queue.enqueue(event("a"))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        try journal(id: id).save(queue: queue)
        queue.enqueue(event(String(repeating: "b", count: 1500)))
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), [String(repeating: "b", count: 1500)])
        for suffix in ["json", "azure-blob"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).\(suffix)").path))
        }
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testSidecarDeletionFailureIsJournaledAndRestartNeverReplaysOrRecountsLoss() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2048)
        queue.enqueue(event("a"))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        try journal(id: id).save(queue: queue)
        let sidecar = directory.appendingPathComponent("\(id).azure-blob")
        let original = try Data(contentsOf: sidecar)
        // Real unlink failure on a test-owned file; the loss ledger remains writable.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }
        queue.enqueue(event(String(repeating: "b", count: 1500)))
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path))
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2048)
        XCTAssertEqual(restarted.droppedEventCount, 1)
        XCTAssertTrue(try restarted.loadPersistedBatches().isEmpty, "A durable tombstone excludes the undeletable source")
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path)
        XCTAssertTrue(try restarted.batchesForFlush().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "A flush retries cleanup even without new events")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path))
        restarted.enqueue(event("c"))
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["c"])
        XCTAssertEqual(restarted.droppedEventCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path))
    }

    func testFailedOversizeCounterWriteRetriesWithoutLosingOrDoubleCountingTheDrop() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(event("oversized"))
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        queue.enqueue(event("a"))
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes).droppedEventCount, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["a"])
    }

    func testOrphanSidecarSaveCannotEvictUnrelatedSource() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 2)
        queue.enqueue(event("a"))
        XCTAssertThrowsError(try journal(id: UUID()).save(queue: queue))
        XCTAssertEqual(queue.droppedEventCount, 0)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["a"])
    }

    func testSuccessfulFlushFreesDeferredCapacityWithoutCountingDeliveredEventsAsDropped() throws {
        XCTAssertEqual(TelemetryQueue(storeDirectory: directory).maxDiskBytes, 52_428_800)
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        queue.enqueue(event("a"))
        XCTAssertTrue(queue.beginFlush())
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        queue.enqueue(event("b"))
        try queue.removeBatch(id: id) // Queue's existing confirmed-delivery interface.
        queue.endFlush()
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        XCTAssertEqual(try restarted.loadPersistedBatches().flatMap(\.events).map(\.name), ["b"])
        XCTAssertEqual(restarted.droppedEventCount, 0)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testRecoveredFileOrderPrecedesNewEventsAndFitsExactlyAtTheLimit() throws {
        let seed = TelemetryQueue(storeDirectory: directory)
        let oldest = UUID(), newer = UUID()
        try seed.persistBatch(id: newer, events: [event("b")])
        try seed.persistBatch(id: oldest, events: [event("a")])
        for (id, seconds) in [(oldest, 1_700_000_000.0), (newer, 1_700_000_010.0)] {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: directory.appendingPathComponent("\(id).json").path)
        }
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 2)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["a", "b"])
        XCTAssertEqual(queue.droppedEventCount, 0)
        queue.enqueue(event("c"))
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["b", "c"])
        XCTAssertEqual(queue.droppedEventCount, 1)
    }

    func testRetryOfOldestDirtyBatchDoesNotEvictNewerBatchOrReplayDroppedMemorySuffix() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 2)
        queue.enqueue(event("a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(event("b"))
        _ = try queue.batchesForFlush(retryingWrites: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        queue.enqueue(event("c"))
        XCTAssertEqual(queue.droppedEventCount, 0)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["c"])
        XCTAssertEqual(queue.droppedEventCount, 2)
        XCTAssertEqual(queue.persistenceFailureCount, 1, "Quota eviction is not another failed storage operation")
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 2)
        XCTAssertEqual(try restarted.loadPersistedBatches().flatMap(\.events).map(\.name), ["c"])
        XCTAssertEqual(restarted.droppedEventCount, 2)
    }

    func testLowerConfiguredCapAppliesToRecoveredBacklogBeforeFirstFlushSnapshot() throws {
        let seed = TelemetryQueue(storeDirectory: directory)
        for (index, name) in ["a", "b", "c"].enumerated() {
            let id = UUID()
            try seed.persistBatch(id: id, events: [event(name)])
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))],
                ofItemAtPath: directory.appendingPathComponent("\(id).json").path)
        }
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 2)
        XCTAssertTrue(queue.beginFlush())
        defer { queue.endFlush() }
        XCTAssertEqual(try queue.batchesForFlush(retryingWrites: false).flatMap(\.events).map(\.name), ["b", "c"])
        XCTAssertEqual(queue.droppedEventCount, 1)
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes * 2)
        XCTAssertEqual(restarted.droppedEventCount, 1)
        XCTAssertEqual(try restarted.loadPersistedBatches().flatMap(\.events).map(\.name), ["b", "c"])
    }

    func testRepeatedRestartReconciliationDoesNotRecountAnUndeletableTombstone() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2048)
        queue.enqueue(event("a"))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        try journal(id: id).save(queue: queue)
        let sidecar = directory.appendingPathComponent("\(id).azure-blob")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }
        queue.enqueue(event(String(repeating: "b", count: 1500)))
        XCTAssertEqual(queue.droppedEventCount, 1)
        for _ in 0..<2 {
            let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
            XCTAssertTrue(try restarted.batchesForFlush().isEmpty)
            XCTAssertEqual(restarted.droppedEventCount, 1)
            XCTAssertEqual(restarted.persistenceFailureCount, 1)
        }
    }

    func testMalformedSidecarDirectoryIsNotRecursivelyDeletedByCapacityCleanup() throws {
        let seed = TelemetryQueue(storeDirectory: directory)
        seed.enqueue(event("a"))
        let id = try XCTUnwrap(seed.batchesForFlush().first?.id)
        let malformed = directory.appendingPathComponent("\(id).azure-blob")
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
        let sentinel = malformed.appendingPathComponent("must-remain")
        try Data("owned synthetic sentinel".utf8).write(to: sentinel)
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes - 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["a"])
        XCTAssertEqual(queue.droppedEventCount, 0)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("owned synthetic sentinel".utf8))
    }

    func testLossRecordWriteFailureLeavesOldestBatchUnchangedUntilRetrySucceeds() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        queue.enqueue(event("a"))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let source = directory.appendingPathComponent("\(id).json")
        let original = try Data(contentsOf: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(event("b"))
        XCTAssertEqual(queue.droppedEventCount, 0)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["b"])
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes).droppedEventCount, 1)
    }

    func testSourceDeletionFailureAfterSidecarRemovalRemainsTombstonedAcrossRestart() throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2048)
        queue.enqueue(event("a"))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        try journal(id: id).save(queue: queue)
        let source = directory.appendingPathComponent("\(id).json")
        let sidecar = directory.appendingPathComponent("\(id).azure-blob")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source.path) }
        queue.enqueue(event(String(repeating: "b", count: 1500)))
        XCTAssertEqual(queue.droppedEventCount, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2048)
        XCTAssertTrue(try restarted.loadPersistedBatches().isEmpty)
        XCTAssertEqual(restarted.droppedEventCount, 1)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source.path)
        restarted.enqueue(event("c"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["c"])
        XCTAssertEqual(restarted.droppedEventCount, 1)
    }

    func testInvalidNegativeLossRecordIsRetainedAndNotUsedToInventAQueueCount() throws {
        let record = directory.appendingPathComponent(".queue-capacity")
        let invalid = Data(#"{"droppedEvents":-1,"removing":[]}"#.utf8)
        try invalid.write(to: record)
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        XCTAssertThrowsError(try queue.loadPersistedBatches())
        XCTAssertEqual(queue.droppedEventCount, 0)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: record), invalid)
    }

    func testLossCounterSaturatesInsteadOfWrappingAtItsRepresentableLimit() throws {
        let record = directory.appendingPathComponent(".queue-capacity")
        try Data("{\"droppedEvents\":\(Int.max),\"removing\":[]}".utf8).write(to: record)
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes)
        queue.enqueue(event("oversized"))
        XCTAssertEqual(queue.droppedEventCount, Int.max)
        XCTAssertEqual(TelemetryQueue(storeDirectory: directory, maxDiskBytes: eventBytes).droppedEventCount, Int.max)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }
}
