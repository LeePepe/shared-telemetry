import Foundation
import Synchronization
import XCTest
import zlib
#if os(macOS)
import Darwin
#endif
@testable import LokiKit

final class AzureBlobTransportTests: XCTestCase {
    func testPublicHeartbeatPreservesOriginalPersistenceCauseOnLaterTicks() throws {
        let tick = Mutex<(@Sendable () -> Void)?>(nil)
        let clock = BlobHeartbeatClock(now: { Date(timeIntervalSince1970: 1_700_000_000) }, scheduleDaily: { callback in
            tick.withLock { $0 = callback }
            return { tick.withLock { $0 = nil } }
        })
        let telemetry = try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1",
            privacy: AzureBlobPrivacyPolicy(apps: ["sample"], builds: ["test build+1"], versions: ["1.2.3"]),
            storeDirectory: directory, isEnabled: true, identityProvider: { UUID() },
            configuration: http.session.configuration, synchronization: nil,
            heartbeatVersion: "1.2.3", heartbeatClock: clock)
        let source = try XCTUnwrap(try publicStoreBytes().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        let epoch = directory.appendingPathComponent(source).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: epoch.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: epoch.path) }
        tick.withLock { $0 }?()
        XCTAssertEqual(telemetry.diagnostics.lastError, .persistenceFailure)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: epoch.path)
        tick.withLock { $0 }?()
        XCTAssertEqual(telemetry.diagnostics.lastError, .persistenceFailure)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        XCTAssertEqual(telemetry.diagnostics.lastHeartbeat?.properties["transport"], "failed")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testPublicHeartbeatReadFailureClosesCapturedGenerationBeforeStart() async throws {
        let entered = expectation(description: "real request has not been created")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let tick = Mutex<(@Sendable () -> Void)?>(nil)
        let clock = BlobHeartbeatClock(now: { Date(timeIntervalSince1970: 1_700_000_000) }, scheduleDaily: { callback in
            tick.withLock { $0 = callback }
            return { tick.withLock { $0 = nil } }
        })
        let telemetry = try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1",
            privacy: AzureBlobPrivacyPolicy(apps: ["sample"], builds: ["test build+1"], versions: ["1.2.3"]),
            storeDirectory: directory, isEnabled: true, identityProvider: { UUID() },
            configuration: http.session.configuration,
            synchronization: BlobRequestSynchronization(beforeRequestStart: { await gate.wait() }),
            heartbeatVersion: "1.2.3", heartbeatClock: clock)
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        let source = try XCTUnwrap(try publicStoreBytes().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        try Data("synthetic-invalid-source".utf8).write(to: directory.appendingPathComponent(source))
        let retained = try publicStoreBytes()
        tick.withLock { $0 }?()
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(telemetry.diagnostics.lastHeartbeat?.properties["pending_batches"], "-1")
        gate.release()
        await flushing.value
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), retained)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
    }

    func testPublicCrossEpochCapacityCleanupDoesNotRewriteLaterDirtyPayload() async throws {
        let entered = expectation(description: "old epoch at real request-start cut")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let identities = Mutex([UUID(), UUID()])
        let telemetry = try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", privacy: Self.fixturePrivacy, storeDirectory: directory,
            isEnabled: true, identityProvider: { identities.withLock { $0.removeFirst() } },
            configuration: http.session.configuration,
            synchronization: BlobRequestSynchronization(beforeRequestStart: { await gate.wait() }), maxDiskBytes: 1200)
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        telemetry.resetIdentifier()
        for _ in 0..<8 { telemetry.track(name: "synthetic.first", properties: ["count": "1234567890"]) }
        let before = try publicStoreBytes()
        let sources = before.filter { $0.key.hasSuffix(".json") && $0.key != "catalog.json" }
        XCTAssertEqual(sources.count, 2, "Fixture has both the old source and a newer durable prefix")
        XCTAssertEqual(telemetry.diagnostics.droppedEventCount, 0, "Captured old snapshot is protected")
        telemetry.isEnabled = false
        gate.release()
        await flushing.value
        let after = try publicStoreBytes()
        XCTAssertEqual(telemetry.diagnostics.droppedEventCount, 1)
        for (name, bytes) in sources where after[name] != nil {
            XCTAssertEqual(after[name], bytes, "Quota cleanup cannot rewrite another epoch's unvalidated memory suffix")
        }
        XCTAssertTrue(http.requests.isEmpty)
        telemetry.isEnabled = true
        await telemetry.flush()
        // A source+sidecar pair that cannot fit is explicitly evicted, not retried forever.
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(telemetry.diagnostics.droppedEventCount, 9)
    }

    func testPublicDailyHeartbeatUsesRealLossAndReceiptAndStopsWithOwner() async throws {
        let instant = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let tick = Mutex<(@Sendable () -> Void)?>(nil)
        let cancellations = Mutex(0)
        let clock = BlobHeartbeatClock(now: { instant.withLock { $0 } }, scheduleDaily: { callback in
            tick.withLock { $0 = callback }
            return { tick.withLock { $0 = nil }; cancellations.withLock { $0 += 1 } }
        })
        let oversize = String(repeating: "x", count: 5_000)
        var telemetry: AzureBlobTelemetryService? = try AzureBlobTelemetryService(
            containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1",
            privacy: AzureBlobPrivacyPolicy(events: ["synthetic.large": ["label": .label([oversize])]],
                apps: ["sample"], builds: ["test build+1"], versions: ["1.2.3"]),
            storeDirectory: directory, isEnabled: true, identityProvider: { UUID() },
            configuration: http.session.configuration, synchronization: nil, maxDiskBytes: 4096,
            heartbeatVersion: "1.2.3", heartbeatClock: clock)
        weak var weakTelemetry = telemetry
        XCTAssertNotNil(tick.withLock { $0 }, "A daily clock must actually be installed")
        telemetry?.track(name: "synthetic.large", properties: ["label": oversize])
        XCTAssertEqual(telemetry?.diagnostics.droppedEventCount, 1)
        await telemetry?.flush()
        XCTAssertEqual(telemetry?.diagnostics.lastSuccessfulUpload, Date(timeIntervalSince1970: 1_700_000_000))
        instant.withLock { $0 = Date(timeIntervalSince1970: 1_700_086_400) }
        tick.withLock { $0 }?()
        let heartbeat = try XCTUnwrap(telemetry?.diagnostics.lastHeartbeat)
        XCTAssertEqual(heartbeat.timestamp, Date(timeIntervalSince1970: 1_700_086_400))
        XCTAssertEqual(heartbeat.properties["dropped_events"], "1")
        XCTAssertEqual(heartbeat.properties["pending_batches"], "0")
        XCTAssertEqual(heartbeat.properties["last_successful_upload"], "1700000000.0")
        XCTAssertEqual(heartbeat.properties["transport"], "enabled")
        await telemetry?.flush()
        XCTAssertEqual(http.requests.count, 2, "Startup and daily heartbeat each reach the real synthetic receiver")
        let accepted = telemetry?.diagnostics.acceptedEventCount
        let bytes = try publicStoreBytes()
        telemetry?.isEnabled = false
        instant.withLock { $0 = Date(timeIntervalSince1970: 1_700_172_800) }
        tick.withLock { $0 }?()
        XCTAssertEqual(telemetry?.diagnostics.lastHeartbeat?.properties["transport"], "disabled")
        XCTAssertEqual(telemetry?.diagnostics.acceptedEventCount, accepted)
        XCTAssertEqual(try publicStoreBytes(), bytes, "Disabled daily diagnostics do not enter the queue")
        await telemetry?.flush()
        XCTAssertEqual(http.requests.count, 2)
        telemetry = nil
        XCTAssertNil(weakTelemetry)
        XCTAssertNil(tick.withLock { $0 })
        XCTAssertEqual(cancellations.withLock { $0 }, 1)
    }

    func testPublicRegisteredCancellationIsCountedAfterWorkerFinalizesBeforeHandlerAccounting() async throws {
        let atStart = expectation(description: "worker stopped at real Cut S")
        let closed = expectation(description: "caller closed its real control before service accounting")
        let finalized = expectation(description: "worker actually released its active generation")
        let startGate = BlobTimingGate(entered: atStart)
        let releaseAccounting = DispatchSemaphore(value: 0)
        defer { startGate.release(); releaseAccounting.signal() }
        let resumed = Mutex(0)
        let finished = Mutex(0)
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(
            afterCallerControlCancelled: {
                closed.fulfill()
                XCTAssertEqual(releaseAccounting.wait(timeout: .now() + 5), .success)
            }, afterGenerationFinished: {
                if finished.withLock({ $0 += 1; return $0 == 1 }) { finalized.fulfill() }
            }, beforeRequestStart: { await startGate.wait() }, observeStart: { event in
                if case .didInvokeResume = event { resumed.withLock { $0 += 1 } }
            }))
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [atStart], timeout: 3)
        let retained = try publicStoreBytes()
        // Cancellation handling is synchronous. Pause only this owned caller thread,
        // outside SDK locks; the real worker must remain free to finish independently.
        let cancelling = Task.detached { flushing.cancel() }
        await fulfillment(of: [closed], timeout: 3)
        startGate.release()
        await fulfillment(of: [finalized], timeout: 3)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        releaseAccounting.signal()
        await cancelling.value
        await flushing.value
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1,
            "Clearing active must not erase accounting for a registered cancelled flush")
        XCTAssertEqual(resumed.withLock { $0 }, 0)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), retained)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        flushing.cancel() // Repeated cancellation cannot count this operation twice.
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        await telemetry.flush()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
    }

    func testPublicUnregisteredCancelledCallersDoNotCountOrCancelActiveFlush() async throws {
        let atStart = expectation(description: "registered owner's request stopped at Cut S")
        let gate = BlobTimingGate(entered: atStart)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(beforeRequestStart: { await gate.wait() }))
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await telemetry.flush()
        }
        await preCancelled.value
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [atStart], timeout: 3)
        let overlapping = Task {
            await telemetry.flush() // No registration while the original generation owns the slot.
            withUnsafeCurrentTask { $0?.cancel() }
            await telemetry.flush() // Pre-cancelled overlapping call also owns no generation.
        }
        await overlapping.value
        XCTAssertTrue(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 0)
        gate.release()
        await flushing.value
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 0)
        XCTAssertNil(telemetry.diagnostics.lastError)
        XCTAssertEqual(Set(try publicStoreBytes().keys), ["catalog.json", ".owner-lock"])
    }

    func testPublicDisableThenCallerCancellationCountsOneRegisteredOperation() async throws {
        let atStart = expectation(description: "registered generation before request creation")
        let gate = BlobTimingGate(entered: atStart)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(beforeRequestStart: { await gate.wait() }))
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [atStart], timeout: 3)
        let retained = try publicStoreBytes()
        telemetry.isEnabled = false
        flushing.cancel()
        gate.release()
        await flushing.value
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.lastError, .cancelled)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertEqual(try publicStoreBytes(), retained)
        XCTAssertTrue(http.requests.isEmpty)
        telemetry.isEnabled = true
        await telemetry.flush()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
    }

    func testPublicWorkerInvalidCatalogCauseSurvivesDisableBeforeErrorHandling() async throws {
        try await assertWorkerStoreFailureSurvivesDisable(corruptCatalog: true)
    }

    func testPublicWorkerPersistenceCauseSurvivesDisableBeforeErrorHandling() async throws {
        try await assertWorkerStoreFailureSurvivesDisable(corruptCatalog: false)
    }

    private func assertWorkerStoreFailureSurvivesDisable(corruptCatalog: Bool) async throws {
        let detected = expectation(description: "worker's real store validation failed before outer error handling")
        let gate = BlobTimingGate(entered: detected)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(beforeWorkerErrorHandling: { await gate.wait() }))
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        if corruptCatalog {
            try Data("synthetic-invalid-catalog".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        }
        let retained = try publicStoreBytes()
        if !corruptCatalog {
            // Named files remain accessible, but real epoch enumeration gets EACCES.
            try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [detected], timeout: 3)
        if !corruptCatalog { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let cause: AzureBlobTelemetryError = corruptCatalog ? .invalidStore : .persistenceFailure
        XCTAssertEqual(telemetry.diagnostics.lastError, cause, "The detecting operation must first record its real cause")
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertTrue(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        telemetry.isEnabled = false // Real public invalidation in the worker's two-lock gap.
        XCTAssertEqual(telemetry.diagnostics.lastError, cause, "Generic cancellation cannot replace established integrity failure")
        gate.release()
        await flushing.value
        XCTAssertEqual(telemetry.diagnostics.lastError, cause)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(try publicStoreBytes(), retained)
        XCTAssertTrue(http.requests.isEmpty)
        telemetry.isEnabled = true
        await telemetry.flush()
        XCTAssertEqual(telemetry.diagnostics.lastError, cause)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testPublicCallerCancellationDuringGenerationRegistrationRefusesActualStart() async throws {
        let registered = expectation(description: "public caller paused after generation publication")
        let atStart = expectation(description: "worker at Cut S before task creation")
        let attempted = expectation(description: "real start arbitration finished")
        let registrationGate = BlobTimingGate(entered: registered)
        let startGate = BlobTimingGate(entered: atStart)
        defer { registrationGate.release(); startGate.release() }
        let observations = Mutex((resumed: 0, finished: 0))
        let synchronization = BlobRequestSynchronization(
            afterGenerationRegistered: { await registrationGate.wait() },
            beforeRequestStart: { await startGate.wait() }, observeStart: { event in
                let firstFinish = observations.withLock { value -> Bool in
                    switch event {
                    case .didInvokeResume: value.resumed += 1; return false
                    case .didFinishStartAttempt: value.finished += 1; return value.finished == 1
                    }
                }
                if firstFinish { attempted.fulfill() }
            })
        let telemetry = try publicService(synchronization: synchronization)
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [registered, atStart], timeout: 3)
        let before = try publicStoreBytes()
        flushing.cancel()
        startGate.release()
        await fulfillment(of: [attempted], timeout: 3)
        registrationGate.release()
        await flushing.value
        XCTAssertEqual(observations.withLock { $0.resumed }, 0)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), before)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        await telemetry.flush()
        XCTAssertEqual(http.requests.count, 1, "A later uncancelled caller can flush the retained work")
    }

    func testPublicDisableAtCutSRefusesActualResumeBeforeTaskCreation() async throws {
        let entered = expectation(description: "Cut S before Foundation task exists")
        let finished = expectation(description: "actual start attempt returned")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let observations = Mutex((resumed: 0, finished: 0))
        let synchronization = BlobRequestSynchronization(beforeRequestStart: { await gate.wait() }, observeStart: { event in
            let firstFinish = observations.withLock { value -> Bool in
                switch event {
                case .didInvokeResume: value.resumed += 1; return false
                case .didFinishStartAttempt: value.finished += 1; return value.finished == 1
                }
            }
            if firstFinish { finished.fulfill() }
        })
        let telemetry = try publicService(synchronization: synchronization)
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        let before = try publicStoreBytes()
        telemetry.isEnabled = false
        telemetry.track(name: "synthetic.first", properties: ["count": "2"])
        gate.release()
        await fulfillment(of: [finished], timeout: 3)
        await flushing.value
        XCTAssertEqual(observations.withLock { $0.resumed }, 0, "No actual resume may follow disable winning at Cut S")
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), before)
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.disabledEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        telemetry.isEnabled = true
        await telemetry.flush()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(observations.withLock { $0.resumed }, 1)
    }

    func testPublicReceiptWinsAtCutTButDisabledGenerationCannotSendNextBatch() async throws {
        let entered = expectation(description: "real terminal receipt claimed before handoff")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(afterReceiptCommitted: { await gate.wait() }))
        for index in 0..<65 { telemetry.track(name: "synthetic.first", properties: ["count": String(index)]) }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try publicStoreBytes().keys.filter { $0.hasSuffix(".json") && $0 != "catalog.json" }.count, 2)
        telemetry.isEnabled = false
        XCTAssertTrue(telemetry.diagnostics.isFlushActive)
        XCTAssertThrowsError(try publicService(synchronization: nil)) { XCTAssertEqual($0 as? AzureBlobTelemetryError, .storeInUse) }
        telemetry.isEnabled = true
        await telemetry.flush() // Old generation still owns the lease/active slot; no overlap.
        XCTAssertEqual(http.requests.count, 1)
        telemetry.isEnabled = false
        gate.release()
        await flushing.value
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(http.requests.count, 1)
        let remaining = try publicStoreBytes().filter { $0.key.hasSuffix(".json") && $0.key != "catalog.json" }
        XCTAssertEqual(remaining.count, 1, "Winning receipt cleans its source even after later cancellation")
        XCTAssertTrue(String(decoding: try XCTUnwrap(remaining.values.first), as: UTF8.self).contains("\"64\""))
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        telemetry.isEnabled = true
        await telemetry.flush()
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(try gunzip(requestBody(XCTUnwrap(http.requests.last))).filter { $0 == 0x0a }.count, 1)
    }

    func testPublicImmutableOverwriteWinsRealTerminalCutAndRetainsLeaseThroughHandoff() async throws {
        let entered = expectation(description: "exact overwrite receipt won terminal arbitration")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        var telemetry: AzureBlobTelemetryService? = try publicService(
            synchronization: BlobRequestSynchronization(afterReceiptCommitted: { await gate.wait() }))
        telemetry?.track(name: "synthetic.first", properties: ["count": "1"])
        http.state.withLock { $0.error = URLError(.timedOut) }
        await telemetry?.flush()
        let first = try XCTUnwrap(http.requests.first)
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        var flushing: Task<Void, Never>? = Task { [owner = try XCTUnwrap(telemetry)] in await owner.flush() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.last?.url, first.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), try requestBody(first))
        telemetry?.isEnabled = false
        telemetry = nil
        XCTAssertThrowsError(try publicService(synchronization: nil)) { XCTAssertEqual($0 as? AzureBlobTelemetryError, .storeInUse) }
        gate.release()
        await flushing?.value
        flushing = nil
        let restored = try publicService(synchronization: nil)
        await restored.flush()
        XCTAssertEqual(http.requests.count, 2, "No retransmission after already-won receipt cleanup")
        XCTAssertEqual(try publicStoreBytes().keys.filter { $0.hasSuffix(".json") && $0 != "catalog.json" }.count, 0)
    }

    func testPublicResetAdoptsExactReplacementWhenAtomicWriteReportsFailure() async throws {
        let identities = Mutex([UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!])
        let telemetry = try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", privacy: Self.fixturePrivacy, storeDirectory: directory,
            isEnabled: true, identityProvider: { identities.withLock { $0.removeFirst() } },
            configuration: http.session.configuration, synchronization: nil, atomicWriteFault: .reportFailureAfterReplacement)
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let prior = try Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        telemetry.resetIdentifier()
        XCTAssertNotEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.json")), prior)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        XCTAssertEqual(telemetry.diagnostics.lastError, .persistenceFailure)
        XCTAssertTrue(telemetry.diagnostics.isAdmissionReady)
        telemetry.track(name: "synthetic.first", properties: ["count": "2"])
        await telemetry.flush()
        XCTAssertEqual(http.requests.compactMap { $0.url?.pathComponents[5] }, [
            "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
        ])
    }

    func testPublicResetBlocksWhenReconciliationReadFailsThenRecreationUsesActualCatalog() async throws {
        let identities = Mutex([UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!])
        var telemetry: AzureBlobTelemetryService? = try AzureBlobTelemetryService(
            containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only", app: "sample", build: "test build+1",
            privacy: Self.fixturePrivacy, storeDirectory: directory, isEnabled: true,
            identityProvider: { identities.withLock { $0.removeFirst() } }, configuration: http.session.configuration,
            synchronization: nil, atomicWriteFault: .unavailableReconciliationRead)
        telemetry?.track(name: "synthetic.first", properties: ["count": "1"])
        telemetry?.resetIdentifier()
        XCTAssertFalse(try XCTUnwrap(telemetry?.diagnostics.isAdmissionReady))
        XCTAssertEqual(telemetry?.diagnostics.persistenceFailureCount, 2, "Failed write result and failed readback are distinct operations")
        XCTAssertEqual(telemetry?.diagnostics.lastError, .invalidStore)
        let retained = try publicStoreBytes()
        telemetry?.track(name: "synthetic.first", properties: ["count": "99"])
        await telemetry?.flush()
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), retained)
        telemetry = nil
        let restored = try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", privacy: Self.fixturePrivacy, storeDirectory: directory,
            isEnabled: true, identityProvider: { throw AzureBlobTelemetryError.identityUnavailable }, configuration: http.session.configuration)
        restored.track(name: "synthetic.first", properties: ["count": "2"])
        await restored.flush()
        XCTAssertEqual(http.requests.compactMap { $0.url?.pathComponents[5] }, [
            "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
        ])
        XCTAssertEqual(restored.diagnostics.acceptedEventCount, 1)
    }

    func testPublicInvalidResetAtCutSClosesActiveGenerationAndPreservesIntegrityError() async throws {
        let entered = expectation(description: "request stopped before real task creation")
        let finished = expectation(description: "start refusal observed")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let observations = Mutex((resumed: 0, finished: 0))
        let ids = Mutex([UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!])
        let telemetry = try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", privacy: Self.fixturePrivacy, storeDirectory: directory,
            isEnabled: true, identityProvider: { ids.withLock { $0.removeFirst() } },
            configuration: http.session.configuration, synchronization: BlobRequestSynchronization(
                beforeRequestStart: { await gate.wait() }, observeStart: { event in
                    let firstFinish = observations.withLock { value -> Bool in
                        switch event {
                        case .didInvokeResume: value.resumed += 1; return false
                        case .didFinishStartAttempt: value.finished += 1; return value.finished == 1
                        }
                    }
                    if firstFinish { finished.fulfill() }
                }), atomicWriteFault: .unavailableReconciliationRead)
        for index in 0..<65 { telemetry.track(name: "synthetic.first", properties: ["count": String(index)]) }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        telemetry.resetIdentifier()
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 2)
        let retained = try publicStoreBytes()
        gate.release()
        await fulfillment(of: [finished], timeout: 3)
        await flushing.value
        XCTAssertEqual(observations.withLock { $0.resumed }, 0)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), retained)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore, "Cancellation must not hide the integrity failure")
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        await telemetry.flush()
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testPublicTrackDetectsInvalidCatalogAtCutSAndRefusesActualStart() async throws {
        let entered = expectation(description: "Cut S before catalog corruption")
        let finished = expectation(description: "actual start decision observed")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let observations = Mutex((resumed: 0, finished: 0))
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(
            beforeRequestStart: { await gate.wait() }, observeStart: { event in
                let firstFinish = observations.withLock { value -> Bool in
                    switch event {
                    case .didInvokeResume: value.resumed += 1; return false
                    case .didFinishStartAttempt: value.finished += 1; return value.finished == 1
                    }
                }
                if firstFinish { finished.fulfill() }
            }))
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        try Data("synthetic-invalid-catalog".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        let retained = try publicStoreBytes()
        telemetry.track(name: "synthetic.first", properties: ["count": "99"])
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        gate.release()
        await fulfillment(of: [finished], timeout: 3)
        await flushing.value
        XCTAssertEqual(observations.withLock { $0.resumed }, 0)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try publicStoreBytes(), retained)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
    }

    func testPublicTrackInvalidationAtCutTPreservesWonCleanupButRefusesNextBatch() async throws {
        let entered = expectation(description: "real receipt won before invalid store detection")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(afterReceiptCommitted: { await gate.wait() }))
        for index in 0..<65 { telemetry.track(name: "synthetic.first", properties: ["count": String(index)]) }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(http.requests.count, 1)
        try Data("synthetic-invalid-catalog".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        telemetry.track(name: "synthetic.first", properties: ["count": "99"])
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertTrue(telemetry.diagnostics.isFlushActive)
        gate.release()
        await flushing.value
        XCTAssertEqual(http.requests.count, 1, "Invalidation must close the remaining captured batch snapshot")
        let remaining = try publicStoreBytes().filter { $0.key.hasSuffix(".json") && $0.key != "catalog.json" }
        XCTAssertEqual(remaining.count, 1, "Only the already-won receipt permits cleanup")
        XCTAssertTrue(String(decoding: try XCTUnwrap(remaining.values.first), as: UTF8.self).contains("\"64\""))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.json")), Data("synthetic-invalid-catalog".utf8))
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
    }

    func testPublicCallerCancellationAtCutTKeepsWonCleanupAndClosesNextStart() async throws {
        let entered = expectation(description: "receipt won before caller cancellation")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(afterReceiptCommitted: { await gate.wait() }))
        for index in 0..<65 { telemetry.track(name: "synthetic.first", properties: ["count": String(index)]) }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        flushing.cancel()
        XCTAssertTrue(telemetry.diagnostics.isFlushActive)
        XCTAssertThrowsError(try publicService(synchronization: nil)) { XCTAssertEqual($0 as? AzureBlobTelemetryError, .storeInUse) }
        gate.release()
        await flushing.value
        XCTAssertEqual(http.requests.count, 1)
        let remaining = try publicStoreBytes().filter { $0.key.hasSuffix(".json") && $0.key != "catalog.json" }
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(remaining.values.first), as: UTF8.self).contains("\"64\""))
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        await telemetry.flush()
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(try gunzip(requestBody(XCTUnwrap(http.requests.last))).filter { $0 == 0x0a }.count, 1)
    }

    func testPublicDuplicateResetAtCutSDoesNotCancelSoundActiveBacklog() async throws {
        let entered = expectation(description: "sound backlog paused at Cut S")
        let gate = BlobTimingGate(entered: entered)
        defer { gate.release() }
        let telemetry = try publicService(synchronization: BlobRequestSynchronization(beforeRequestStart: { await gate.wait() }))
        telemetry.track(name: "synthetic.first", properties: ["count": "1"])
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        let retained = try publicStoreBytes()
        telemetry.resetIdentifier() // Provider returns the original UUID; catalog remains sound.
        XCTAssertEqual(telemetry.diagnostics.lastError, .duplicateIdentity)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(try publicStoreBytes(), retained)
        gate.release()
        await flushing.value
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url?.pathComponents[5], "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 0)
        XCTAssertEqual(telemetry.diagnostics.lastError, .duplicateIdentity)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        XCTAssertEqual(Set(try publicStoreBytes().keys), ["catalog.json", ".owner-lock"])
    }

    private func publicService(synchronization: BlobRequestSynchronization?) throws -> AzureBlobTelemetryService {
        try AzureBlobTelemetryService(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", privacy: Self.fixturePrivacy, storeDirectory: directory,
            isEnabled: true, identityProvider: { UUID(uuidString: "11111111-1111-4111-8111-111111111111")! },
            configuration: http.session.configuration, synchronization: synchronization)
    }

    private func publicStoreBytes() throws -> [String: Data] {
        let enumeration = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path))
        var files: [String: Data] = [:]
        for case let relative as String in enumeration {
            let file = directory.appendingPathComponent(relative)
            if try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular {
                files[relative] = try Data(contentsOf: file)
            }
        }
        return files
    }

    private var directory: URL!
    private var http: BlobHTTPFixture!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlobTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        http = BlobHTTPFixture()
    }

    override func tearDownWithError() throws {
        http.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func transport(build: String = "test build+1", now: Date = Date(timeIntervalSince1970: 1_700_000_000),
                           privacy: AzureBlobPrivacyPolicy = fixturePrivacy) throws -> AzureBlobTransport {
        try AzureBlobTransport(containerURL: http.container, sasQuery: "sv=2023-11-03&sr=c&si=synthetic&sig=fake%2Bonly%2F%3D",
            app: "sample", build: build, installID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            privacy: privacy, configuration: http.session.configuration, now: { now })
    }

    // Fixed synthetic code catalogue, never inferred from queued/request data.
    private static var fixturePrivacy: AzureBlobPrivacyPolicy {
        let names = ["synthetic.\"second\n", "synthetic.collision", "synthetic.server-error", "synthetic.errors",
            "synthetic.destination", "synthetic.prefix", "synthetic.suffix", "synthetic.in-flight", "synthetic.later",
            "synthetic.remove", "synthetic.original", "synthetic.different", "synthetic.redirect", "synthetic.marker",
            "synthetic.checksum", "synthetic.history", "synthetic.process"] + (0..<65).map { "synthetic.\($0)" }
        var events = Dictionary(uniqueKeysWithValues: names.map { ($0, [String: AzureBlobPrivacyPolicy.ValueRule]()) })
        events["synthetic.first"] = ["count": .finiteNumber]
        events["synthetic.retry"] = ["count": .finiteNumber]
        events["synthetic.large"] = Dictionary(uniqueKeysWithValues: (0..<12_000).map { ("metric.\($0)", .finiteNumber) })
        return AzureBlobPrivacyPolicy(events: events, apps: ["sample", "new-app"],
            builds: ["test build+1", "next-build", "2", "路径 #+?%", "new-build", "before-kill", "after-kill"])
    }

    func testDefaultPolicyCannotExportCanaryInBodyOrCreateBlobJournal() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let canary = "synthetic-transcript-CANARY\nnot-telemetry"
        queue.enqueue(TelemetryEvent(name: canary, properties: ["error": canary]))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let sourceFile = directory.appendingPathComponent("\(id).json")
        let sourceBefore = try Data(contentsOf: sourceFile)
        let sender = try AzureBlobTransport(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", installID: UUID(), configuration: http.session.configuration)
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await sender.flush(queue); XCTFail("Default export must be rejected") }
        catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
        // On the vulnerable baseline these assertions inspect the ACTUAL gzip sent
        // through URLSession and the durable body, not only an encoder helper.
        for request in http.requests {
            XCTAssertFalse(String(decoding: try gunzip(requestBody(request)), as: UTF8.self).contains("CANARY"))
        }
        let journal = directory.appendingPathComponent("\(id).azure-blob")
        if FileManager.default.fileExists(atPath: journal.path) {
            let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
            let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(outer["payload"] as? String)))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let body = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(record["body"] as? String)))
            XCTAssertFalse(String(decoding: try gunzip(body), as: UTF8.self).contains("CANARY"))
        }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try Data(contentsOf: sourceFile), sourceBefore)
    }

    private var privacyPolicy: AzureBlobPrivacyPolicy {
        AzureBlobPrivacyPolicy(events: ["synthetic.safe": ["duration": .finiteNumber, "phase": .label(["done", "retry"])]],
            apps: ["sample"], builds: ["test build+1"])
    }

    private func storedBytes() throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

#if os(macOS)
    func testResponseChunksDoNotAccumulateBeforeTerminalNetworkFailure() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
        let entered = expectation(description: "bounded synthetic response delivered")
        let sampled = Mutex<MeasuredBlobResponse.Sample?>(nil)
        let response = MeasuredBlobResponse { measurement in
            sampled.withLock { $0 = measurement }
            entered.fulfill()
        }
        http.state.withLock { state in
            state.response = { response.start($0) }
            state.onStop = { response.stop() }
        }
        let sender = try transport()
        let sending = Task { try await sender.flush(queue, responseBytesObserved: { response.observe($0) }) }
        defer { response.stop(); sending.cancel() }
        await fulfillment(of: [entered], timeout: 8)
        if sampled.withLock({ $0 == nil }) {
            response.stop()
            sending.cancel() // A failed watchdog must not leave the real flush suspended.
        }
        do { try await sending.value; XCTFail("201 headers cannot hide a terminal network error") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let measurement = try XCTUnwrap(sampled.withLock { $0 })
        XCTAssertEqual(measurement.sent, 32 * 1_024 * 1_024)
        XCTAssertEqual(measurement.observed, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(measurement.maxOutstanding, 64 * 1_024)
        print("RESPONSE_BODY_HEAP growth=\(measurement.growth) sent=\(measurement.sent) observed=\(measurement.observed) maxOutstanding=\(measurement.maxOutstanding)")
        XCTAssertLessThan(measurement.growth, measurement.sent / 2,
                          "Response bytes must not be retained as an aggregate while awaiting completion")
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        let finished = await response.resumeAfterPause()
        XCTAssertEqual(finished.sent, measurement.sent)
        XCTAssertEqual(finished.samples, 1)
        XCTAssertFalse(finished.holdsResponse)
    }

    func testResponseConsumptionCancellationFencesNextChunkAndFinalSample() async throws {
        for pauseAt in [64 * 1_024, 32 * 1_024 * 1_024] {
            let folder = directory.appendingPathComponent("cancel-\(pauseAt)")
            let queue = TelemetryQueue(storeDirectory: folder)
            queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
            let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
            let source = folder.appendingPathComponent("\(id).json")
            let journal = folder.appendingPathComponent("\(id).azure-blob")
            let paused = expectation(description: "real delegate consumed \(pauseAt) bytes")
            let stopped = expectation(description: "real cancelled protocol stopped")
            let response = MeasuredBlobResponse(pauseAfterObservedBytes: pauseAt, onPause: { paused.fulfill() }) { _ in
                XCTFail("Cancelled response must not sample or submit a terminal fixture error")
            }
            http.state.withLock {
                $0.response = { response.start($0) }
                $0.onStop = { response.stop(); stopped.fulfill() }
            }
            let sender = try transport()
            let sending = Task { try await sender.flush(queue, responseBytesObserved: { response.observe($0) }) }
            defer { response.stop(); sending.cancel() }
            await fulfillment(of: [paused], timeout: 8)
            let frozenSource = try Data(contentsOf: source)
            let frozenJournal = try Data(contentsOf: journal)
            sending.cancel()
            do { try await sending.value; XCTFail("Cancellation cannot acknowledge a response") }
            catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
            await fulfillment(of: [stopped], timeout: 3)
            let cancelled = await response.resumeAfterPause()
            XCTAssertEqual(cancelled.sent, pauseAt, "Stopped fixture cannot release the next queued chunk")
            XCTAssertEqual(cancelled.observed, pauseAt)
            XCTAssertEqual(cancelled.samples, 0, "Stopped fixture cannot run a queued heap sample")
            XCTAssertFalse(cancelled.holdsResponse, "Stop releases protocol and completion references")
            XCTAssertEqual(try Data(contentsOf: source), frozenSource)
            XCTAssertEqual(try Data(contentsOf: journal), frozenJournal)
            XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
            http.state.withLock { $0.onStop = nil; $0.response = { $0.sendResponseChunks(status: 201) } }
            try await sender.flush(queue) // Default-nil observer, new owned session; retry remains usable.
            XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        }
    }
#endif

    func testStreamedResponseBodiesPreserve201AndExactOverwriteClassification() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
        let sender = try transport()
        http.state.withLock { $0.response = { $0.sendResponseChunks(status: 201) } }
        try await sender.flush(queue)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)

        queue.enqueue(TelemetryEvent(name: "synthetic.retry", properties: ["count": "2"]))
        http.state.withLock { $0.response = nil; $0.error = URLError(.timedOut) }
        do { try await sender.flush(queue); XCTFail("Unconfirmed upload") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let original = try XCTUnwrap(http.requests.last)
        let frozen = try storedBytes()
        let refusals: [(Int, String?)] = [(403, nil), (403, "AuthenticationFailed"), (403, "synthetic-unknown-CANARY"),
            (409, "UnauthorizedBlobOverwrite"), (200, nil), (503, nil)]
        for (status, code) in refusals {
            http.state.withLock { $0.error = nil; $0.response = { $0.sendResponseChunks(status: status, code: code) } }
            do { try await sender.flush(queue); XCTFail("Unconfirmed HTTP response") }
            catch {
                XCTAssertEqual(error as? AzureBlobError, .httpFailure(status))
                XCTAssertFalse(String(describing: error).contains("CANARY"))
            }
            XCTAssertEqual(try storedBytes(), frozen, "Response bodies must not enter source/journal files")
        }
        http.state.withLock { $0.response = { $0.sendResponseChunks(status: 403, code: "UnauthorizedBlobOverwrite") } }
        try await sender.flush(queue)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertEqual(http.requests.last?.url, original.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), try requestBody(original))
    }

    func testTerminalResponseErrorsWinOver201AndOverwriteHeaders() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
        http.state.withLock { $0.error = URLError(.timedOut) }
        let sender = try transport()
        do { try await sender.flush(queue) } catch {}
        let frozen = try storedBytes()
        for status in [201, 403] {
            http.state.withLock { value in
                value.error = nil
                value.response = {
                    $0.sendResponseChunks(status: status, code: "UnauthorizedBlobOverwrite",
                        error: URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey:
                            URL(string: "https://example.invalid/?sig=synthetic-CANARY")!]))
                }
            }
            do { try await sender.flush(queue); XCTFail("Headers alone cannot acknowledge a failed response") }
            catch { XCTAssertEqual(String(describing: error), "networkFailure") }
            XCTAssertEqual(try storedBytes(), frozen)
            XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        }
    }

    func testInvalidResponseAfterStreamCompletionIsNotAcknowledged() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
        let sender = try transport()
        for foreignURL in [false, true] {
            http.state.withLock { $0.response = { protocolInstance in
                let response: URLResponse = foreignURL
                    ? HTTPURLResponse(url: URL(string: "https://other.example.invalid/container")!,
                                      statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
                    : URLResponse(url: protocolInstance.request.url!, mimeType: "text/plain", expectedContentLength: 32, textEncodingName: nil)
                protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("synthetic-response-CANARY".utf8))
                protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
            } }
            do { try await sender.flush(queue); XCTFail("Invalid response must be retained") }
            catch { XCTAssertEqual(error as? AzureBlobError, .invalidResponse) }
            XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        }
    }

    func testAlreadyCancelledFlushDoesNotStartRequestAndNextFlushWorks() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
        let sender = try transport()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await sender.flush(queue); XCTFail("Pre-start cancellation cannot deliver") }
            catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        }
        await cancelled.value
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        try await sender.flush(queue)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testCancellationAfterResponseHeadersAndBodyRetainsFrozenBatch() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
        let sender = try transport()
        let headers = expectation(description: "headers/body offered, no terminal completion")
        let stopped = expectation(description: "cancelled protocol stopped")
        http.state.withLock { value in
            value.onStop = { stopped.fulfill() }
            value.response = { protocolInstance in
                let response = HTTPURLResponse(url: protocolInstance.request.url!, statusCode: 201,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
                protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("synthetic-response-CANARY".utf8))
                headers.fulfill()
            }
        }
        let sending = Task { try await sender.flush(queue) }
        await fulfillment(of: [headers], timeout: 3)
        let frozen = try storedBytes()
        sending.cancel()
        do { try await sending.value; XCTFail("Cancel is not an intentional successful discard") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(try storedBytes(), frozen)
        http.state.withLock { $0.onStop = nil; $0.response = { $0.sendResponseChunks(status: 403, code: "UnauthorizedBlobOverwrite") } }
        try await sender.flush(queue)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testCompletionCancellationRaceResumesOnceAndNeverAcknowledgesAnError() async throws {
        let sender = try transport()
        for index in 0..<20 {
            let queue = TelemetryQueue(storeDirectory: directory.appendingPathComponent("race-\(index)"))
            queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"]))
            let ready = expectation(description: "response headers ready \(index)")
            let failResponse = Mutex<(@Sendable () -> Void)?>(nil)
            http.state.withLock { $0.response = { protocolInstance in
                let response = HTTPURLResponse(url: protocolInstance.request.url!, statusCode: 201,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
                protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                let fail: @Sendable () -> Void = { protocolInstance.failResponse() }
                failResponse.withLock { $0 = fail }
                ready.fulfill()
            } }
            let sending = Task { try await sender.flush(queue) }
            await fulfillment(of: [ready], timeout: 3)
            let fail = try XCTUnwrap(failResponse.withLock { $0 })
            await withTaskGroup(of: Void.self) { group in
                group.addTask { sending.cancel() }
                group.addTask { fail() }
            }
            do { try await sending.value; XCTFail("Both racing outcomes are failures, even after 201") }
            catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
            XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
            http.state.withLock { $0.response = { $0.sendResponseChunks(status: 201) } }
            try await sender.flush(queue)
            XCTAssertTrue(try queue.batchesForFlush().isEmpty, "The queue/session must remain usable after the race")
        }
    }

    func testClosedLabelsAndFiniteMetricsSurviveWireAndJournalUnchanged() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let values = ["0", "-0", "1.25", "-2", "1e3", "1E-3"]
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        for value in values {
            queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": value, "phase": "done"], timestamp: instant))
        }
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue); XCTFail("Unconfirmed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let body = try requestBody(XCTUnwrap(http.requests.first))
        let lines = try gunzip(body).split(separator: 0x0a)
        let properties = try lines.map { try XCTUnwrap((JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["properties"] as? [String: String]) }
        XCTAssertEqual(properties, values.map { ["duration": $0, "phase": "done"] })
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let journal = try XCTUnwrap(AzureBlobBatch.load(id: id, queue: queue))
        XCTAssertEqual(journal.body, body)
        XCTAssertFalse(String(decoding: try gunzip(journal.body), as: UTF8.self).contains("CANARY"))
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), body)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).batchesForFlush().isEmpty)
    }

    func testUnknownNamesKeysAndUnsafePermittedKeyValuesBlockWholeBatchBeforeBlobWrites() async throws {
        let canary = "synthetic-transcript-prompt-error-CANARY\n用户文本"
        let invalid = [
            TelemetryEvent(name: canary), TelemetryEvent(name: "synthetic.unknown"),
            TelemetryEvent(name: "synthetic.safe", properties: [canary: "1"]),
            TelemetryEvent(name: "synthetic.safe", properties: ["error": canary]),
            TelemetryEvent(name: "synthetic.safe", properties: ["transcript": canary]),
            TelemetryEvent(name: "synthetic.safe", properties: ["phase": canary]),
            TelemetryEvent(name: "synthetic.safe", properties: ["phase": "unknown"])
        ] + ["NaN", "nan", "Infinity", "inf", "-inf", "1e999", "1.0\n", " 1", "0x10", "01", "+1", canary].map {
            TelemetryEvent(name: "synthetic.safe", properties: ["duration": $0])
        }
        for (index, event) in invalid.enumerated() {
            let store = directory.appendingPathComponent("case-\(index)")
            let queue = TelemetryQueue(storeDirectory: store)
            queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1", "phase": "done"]))
            queue.enqueue(event)
            let files = try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)
            let before = try files.map { try Data(contentsOf: $0) }
            for candidate in [queue, TelemetryQueue(storeDirectory: store)] {
                do { try await transport(privacy: privacyPolicy).flush(candidate); XCTFail("Unsafe batch must be blocked") }
                catch {
                    XCTAssertEqual(error as? AzureBlobError, .privacyRejected)
                    XCTAssertEqual(String(describing: error), "privacyRejected", "Fixed content-free rejection")
                }
                XCTAssertTrue(http.requests.isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil), files)
                XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
                XCTAssertEqual(candidate.persistenceFailureCount, 0, "Privacy rejection is not a storage failure or delivery")
            }
        }
    }

    func testUnsafeDirtyMemorySuffixCannotRewriteDurablePrefixBeforeValidation() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1"]))
        let before = try storedBytes()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["phase": "synthetic-user-text-CANARY"]))
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        do { try await transport(privacy: privacyPolicy).flush(queue); XCTFail("Do not persist rejected suffix") }
        catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try queue.batchesForFlush(retryingWrites: false).flatMap(\.events).count, 2, "Keep both memory events")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCapacityFailureCannotRewriteLaterUnsafeDirtyBatchBeforeValidation() async throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 512)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1"], timestamp: instant))
        let first = try XCTUnwrap(queue.batchesForFlush(retryingWrites: false).first)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "2"], timestamp: instant))
        let later = try XCTUnwrap(queue.loadPersistedBatches().first { $0.id != first.id })
        let laterFile = directory.appendingPathComponent("\(later.id).json")
        let safePrefix = try Data(contentsOf: laterFile)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(TelemetryEvent(name: "synthetic.safe",
            properties: ["phase": "synthetic-user-text-CANARY"], timestamp: instant))
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: laterFile), safePrefix)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // The first batch's sidecar cannot fit. The later batch has not yet
        // reached privacy validation when that capacity failure ends the flush.
        do { try await transport(privacy: privacyPolicy).flush(queue); XCTFail("Sidecar must exceed capacity") }
        catch { XCTAssertEqual(error as? AzureBlobError, .persistenceFailure) }
        XCTAssertEqual(try Data(contentsOf: laterFile), safePrefix, "Cleanup must not persist an unvalidated suffix")
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(queue.droppedEventCount, 1, "Only the first batch is evicted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(first.id).json").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension == "azure-blob" })
        XCTAssertEqual(try queue.batchesForFlush(retryingWrites: false).flatMap(\.events).count, 2)

        do { try await transport(privacy: privacyPolicy).flush(queue); XCTFail("The retained suffix still needs validation") }
        catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
        XCTAssertEqual(try Data(contentsOf: laterFile), safePrefix)
        XCTAssertTrue(http.requests.isEmpty)
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 512)
        XCTAssertEqual(restarted.droppedEventCount, 1)
        XCTAssertEqual(try restarted.loadPersistedBatches().flatMap(\.events).map(\.properties), [["duration": "2"]])
    }

    func testDeferredDirtySourceCapacityEvictsOldestBatchAndNextBlobFlushProgresses() async throws {
        let queue = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2_048)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1"], timestamp: instant)
        for _ in 0..<10 { queue.enqueue(oldest) }
        let oldestID = try XCTUnwrap(queue.loadPersistedBatches().first?.id)
        let oldestFile = directory.appendingPathComponent("\(oldestID).json")
        let prefix = try Data(contentsOf: oldestFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        for _ in 0..<10 { queue.enqueue(oldest) }
        XCTAssertEqual(queue.persistenceFailureCount, 10)
        _ = try queue.batchesForFlush(retryingWrites: false) // Seal A without persisting its suffix.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for _ in 0..<4 {
            queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "2"], timestamp: instant))
        }
        XCTAssertEqual(try Data(contentsOf: oldestFile), prefix)
        XCTAssertEqual(try queue.loadPersistedBatches().flatMap(\.events).count, 14)
        XCTAssertEqual(queue.droppedEventCount, 0, "A's prefix plus B fits, but full A plus B does not")

        let sender = try transport(privacy: privacyPolicy)
        do { try await sender.flush(queue); XCTFail("The full-source write must need quota reconciliation") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertTrue(http.requests.isEmpty, "No upload before complete source persistence")
        XCTAssertEqual(queue.droppedEventCount, 20, "Evict all of A, including its dirty suffix, once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestFile.path))
        XCTAssertEqual(try queue.loadPersistedBatches().flatMap(\.events).map(\.properties),
                       Array(repeating: ["duration": "2"], count: 4))

        do { try await sender.flush(queue) }
        catch { XCTFail("The next flush must progress past the evicted source: \(error)") }
        XCTAssertEqual(http.requests.count, 1)
        if let request = http.requests.first {
            let lines = try gunzip(requestBody(request)).split(separator: 0x0a)
            let properties = try lines.map {
                try XCTUnwrap((JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["properties"] as? [String: String])
            }
            XCTAssertEqual(properties, Array(repeating: ["duration": "2"], count: 4))
        }
        XCTAssertTrue(try queue.batchesForFlush(retryingWrites: false).isEmpty)
        XCTAssertEqual(queue.droppedEventCount, 20)
        XCTAssertEqual(queue.persistenceFailureCount, 10, "Quota deferral does not add a filesystem failure")
        let restarted = TelemetryQueue(storeDirectory: directory, maxDiskBytes: 2_048)
        XCTAssertTrue(try restarted.loadPersistedBatches().isEmpty)
        XCTAssertEqual(restarted.droppedEventCount, 20)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension == "azure-blob" })
    }

    func testStricterPolicyBlocksFrozenJournalWithoutChangingBytesOrAcknowledgingOverwrite() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1.25", "phase": "done"]))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue) } catch {}
        XCTAssertEqual(http.requests.count, 1)
        let before = try storedBytes()
        let stricter = [
            AzureBlobPrivacyPolicy(),
            AzureBlobPrivacyPolicy(events: ["synthetic.safe": ["duration": .finiteNumber, "phase": .label(["retry"])]], apps: ["sample"], builds: ["test build+1"]),
            AzureBlobPrivacyPolicy(events: privacyPolicy.events, apps: ["different-app"], builds: ["test build+1"]),
            AzureBlobPrivacyPolicy(events: privacyPolicy.events, apps: ["sample"], builds: ["new-build"])
        ]
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        for policy in stricter {
            do { try await transport(privacy: policy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Stricter policy must block") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try storedBytes(), before)
        }
        try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).batchesForFlush().isEmpty)
    }

    func testUnsafeLegacyJournalBodyCannotHideBehindApprovedSourceDigest() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1", "phase": "done"], timestamp: Date(timeIntervalSince1970: 1_700_000_000)))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue) } catch {}
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let valid = try XCTUnwrap(AzureBlobBatch.load(id: id, queue: queue))
        let unsafe = Data("{\"name\":\"synthetic.safe\",\"properties\":{\"duration\":\"1\",\"phase\":\"done\"},\"timestamp\":\"2023-11-14T22:13:20Z\",\"transcript\":\"synthetic-CANARY\"}\n".utf8)
        let unsafeGzip = try gzipFixture(unsafe)
        XCTAssertTrue(String(decoding: try gunzip(unsafeGzip), as: UTF8.self).contains("CANARY"))
        // Optional gzip filename/comment metadata is sent too, even if inflation
        // yields approved NDJSON. The exporter has never generated these fields.
        var hiddenFilename = Data(valid.body.prefix(10))
        hiddenFilename[3] = 0x08
        hiddenFilename.append(Data("synthetic-CANARY\0".utf8))
        hiddenFilename.append(valid.body.dropFirst(10))
        XCTAssertEqual(try gunzip(hiddenFilename), try gunzip(valid.body))
        for body in [unsafeGzip, valid.body + unsafeGzip, valid.body + Data("CANARY".utf8), hiddenFilename] {
            let old = AzureBlobBatch(version: valid.version, queueID: valid.queueID, containerURL: valid.containerURL,
                path: valid.path, sourceDigest: valid.sourceDigest, body: body, mayHaveBeenSent: true)
            try old.save(queue: queue)
            let before = try storedBytes()
            http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
            do { try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Validate actual journal bytes") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try storedBytes(), before)
        }
    }

    func testUnsafeLegacySourceAndMatchingJournalStayBlockedWithoutMigration() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let id = UUID()
        let canary = "synthetic-error-transcript-CANARY"
        let event = TelemetryEvent(name: "synthetic.safe", properties: ["phase": canary], timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try queue.persistBatch(id: id, events: [event])
        let encoded = Data("{\"name\":\"synthetic.safe\",\"properties\":{\"phase\":\"synthetic-error-transcript-CANARY\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}\n".utf8)
        let legacy = AzureBlobBatch(version: 1, queueID: id, containerURL: http.container,
            path: ["sample", "test build+1", "2023-11-14", UUID().uuidString.lowercased(), "\(UUID().uuidString.lowercased()).ndjson.gz"],
            sourceDigest: AzureBlobBatch.digest(encoded), body: try gzipFixture(encoded), mayHaveBeenSent: true)
        try legacy.save(queue: queue)
        let before = try storedBytes()
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        do { try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Old journal is not policy approval") }
        catch { XCTAssertEqual(String(describing: error), "privacyRejected") }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try storedBytes(), before, "No disposal, rewritten receipt, or migration")
        XCTAssertTrue(String(decoding: try gunzip(legacy.body), as: UTF8.self).contains("CANARY"), "Unsafe legacy bytes remain blocked, not erased")
    }

    func testApprovedLegacyGzipIsValidatedButNeverRecompressedOnRetry() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let id = UUID()
        try queue.persistBatch(id: id, events: [TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1.25", "phase": "done"],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000))])
        let approved = Data("{\"name\":\"synthetic.safe\",\"properties\":{\"duration\":\"1.25\",\"phase\":\"done\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}\n".utf8)
        // A legacy stream with an explicit mtime and uncompressed DEFLATE encoding,
        // different from the current compressor, is still an immutable valid request.
        var body = try gzipFixture(approved)
        body[4] = 17
        let legacy = AzureBlobBatch(version: 1, queueID: id, containerURL: http.container,
            path: ["sample", "test build+1", "2023-11-14", UUID().uuidString.lowercased(), "\(UUID().uuidString.lowercased()).ndjson.gz"],
            sourceDigest: AzureBlobBatch.digest(approved), body: body, mayHaveBeenSent: true)
        try legacy.save(queue: queue)
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), body)
        XCTAssertEqual(try gunzip(body), approved)
        XCTAssertEqual(http.requests.first?.url?.path, "/container/" + legacy.path.joined(separator: "/"))
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testUnknownPathMetadataIsRejectedForNewAndExistingBatches() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe"))
        let original = try storedBytes()
        for (app, build) in [("synthetic-CANARY", "test build+1"), ("sample", "synthetic-CANARY")] {
            let sender = try AzureBlobTransport(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
                app: app, build: build, installID: UUID(), privacy: privacyPolicy, configuration: http.session.configuration)
            do { try await sender.flush(queue); XCTFail("Syntax is not provenance") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(try storedBytes(), original)
        }
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue) } catch {}
        let valid = try XCTUnwrap(AzureBlobBatch.load(id: XCTUnwrap(queue.batchesForFlush().first?.id), queue: queue))
        for index in 0..<5 {
            var path = valid.path
            path[index] = "synthetic-CANARY"
            try AzureBlobBatch(version: valid.version, queueID: valid.queueID, containerURL: valid.containerURL,
                path: path, sourceDigest: valid.sourceDigest, body: valid.body, mayHaveBeenSent: true).save(queue: queue)
            let before = try storedBytes()
            do { try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Restored metadata must be validated") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try storedBytes(), before)
        }
    }

    func testPutBlockBlobHasEncodedPathHeadersAndGzipNDJSONThenAcknowledges201() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"],
                                    timestamp: Date(timeIntervalSince1970: 1_700_000_000.125)))
        queue.enqueue(TelemetryEvent(name: "synthetic.\"second\n", timestamp: Date(timeIntervalSince1970: 1_700_000_001)))
        try await transport().flush(queue)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-version"), "2023-11-03")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try requestBody(request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertEqual(Array(body.prefix(3)), [0x1f, 0x8b, 0x08])
        XCTAssertEqual(try gunzip(body), Data((
            "{\"name\":\"synthetic.first\",\"properties\":{\"count\":\"1\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}\n" +
            "{\"name\":\"synthetic.\\\"second\\n\",\"properties\":{},\"timestamp\":\"2023-11-14T22:13:21Z\"}\n").utf8))
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.contains("/container/sample/test%20build%2B1/2023-11-14/00000000-0000-4000-8000-000000000001/"))
        XCTAssertNotNil(UUID(uuidString: url.lastPathComponent.replacingOccurrences(of: ".ndjson.gz", with: "")))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "sv=2023-11-03&sr=c&si=synthetic&sig=fake%2Bonly%2F%3D")
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testAmbiguousUploadThenRestartReplaysExactBytesAndPathBeforeAcknowledgingOverwrite() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.retry", properties: ["count": "2"],
                                    timestamp: Date(timeIntervalSince1970: 1_700_000_000.987)))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue); XCTFail("Timeout must retain work") } catch {}
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        let first = try XCTUnwrap(http.requests.first)
        let firstBody = try requestBody(first)
        let restarted = TelemetryQueue(storeDirectory: directory)
        http.state.withLock {
            $0.error = nil
            $0.status = 403
            $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"]
        }
        // Recovered JSON has only whole-second timestamps; build and wall clock changed.
        try await transport(build: "next-build", now: Date(timeIntervalSince1970: 1_800_000_000)).flush(restarted)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.last?.url, first.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), firstBody)
        XCTAssertTrue(try restarted.batchesForFlush().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testInvalidConfigurationFailsBeforeAnyRequestIncludingMalformedSAS() throws {
        for endpoint in ["http://example.invalid/container", "https://u:p@example.invalid/container",
                         "https://example.invalid/container?sig=fake", "https://example.invalid/container#fragment",
                         "https://example.invalid/container/extra", "https://example.invalid/%63ontainer"] {
            XCTAssertThrowsError(try AzureBlobTransport(containerURL: XCTUnwrap(URL(string: endpoint)),
                sasQuery: "sr=c&sig=fake", app: "sample", build: "1", installID: UUID(), configuration: http.session.configuration))
        }
        for query in ["sig=fake%ZZ&sr=c", "sr=c&sig=fake value", "sr=c&sig=fake#fragment", "sr=c&sig=fake\n",
                      "sr=c&sig=", "sr=c&sig=fake&sig=other", "sr=c&sig=fake&comp=block", "sr=c&sp=w&sig=fake"] {
            XCTAssertThrowsError(try AzureBlobTransport(containerURL: http.container,
                sasQuery: query, app: "sample", build: "1", installID: UUID(), configuration: http.session.configuration))
        }
        for segment in ["", ".", "..", "a/b", "a\\b", "line\nbreak"] {
            XCTAssertThrowsError(try AzureBlobTransport(containerURL: http.container,
                sasQuery: "sr=c&sig=fake", app: segment, build: "1", installID: UUID(), configuration: http.session.configuration))
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testFirstOverwriteAndRepeatedDefinitiveRejectionsNeverProveDelivery() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.collision"))
        http.state.withLock {
            $0.status = 403
            $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"]
        }
        for _ in 0..<3 {
            let restarted = TelemetryQueue(storeDirectory: directory)
            do { try await transport().flush(restarted); XCTFail("No unresolved earlier upload") } catch {}
            XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.collision"])
        }
        XCTAssertEqual(Set(http.requests.compactMap(\.url)).count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testFirstServerErrorRemainsAmbiguousUntilExactOverwriteReceiptOnRestart() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.server-error"))
        http.state.withLock { $0.status = 503 }
        do { try await transport().flush(queue); XCTFail("Server error is not success") } catch {}
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        let restarted = TelemetryQueue(storeDirectory: directory)
        try await transport().flush(restarted)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try restarted.batchesForFlush().isEmpty)
    }

    func testAllOtherHTTPFailuresRetainAmbiguousBatchUntil201() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.errors"))
        http.state.withLock { $0.error = URLError(.networkConnectionLost) }
        do { try await transport().flush(queue); XCTFail("Network outcome is unconfirmed") } catch {}
        let original = try requestBody(XCTUnwrap(http.requests.first))
        let cases: [(Int, String?)] = [
            (200, nil), (202, nil), (204, nil), (403, nil), (403, "AuthenticationFailed"),
            (403, "AuthorizationPermissionMismatch"), (403, "Unknown"), (403, "unauthorizedbloboverwrite"),
            (409, nil), (409, "BlobAlreadyExists"), (409, "UnauthorizedBlobOverwrite"),
            (412, "ConditionNotMet"), (429, nil), (503, nil)
        ]
        for (status, code) in cases {
            http.state.withLock {
                $0.error = nil
                $0.status = status
                $0.headers = code.map { ["x-ms-error-code": $0] } ?? [:]
            }
            do { try await transport().flush(queue); XCTFail("Unconfirmed HTTP \(status)") } catch {}
            XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).batchesForFlush().flatMap(\.events).count, 1)
            XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), original)
        }
        http.state.withLock { $0.status = 201; $0.headers = [:] }
        try await transport().flush(queue)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertEqual(Set(http.requests.compactMap(\.url)).count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testChangedDestinationDoesNotReceiveOldPayloadOrNewSAS() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.destination"))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        let other = BlobHTTPFixture()
        defer { other.close() }
        let changed = try AzureBlobTransport(containerURL: other.container, sasQuery: "sr=c&sig=other-fake",
            app: "new-app", build: "2", installID: UUID(), privacy: Self.fixturePrivacy, configuration: other.session.configuration)
        do { try await changed.flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Destination changed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .destinationChanged) }
        XCTAssertTrue(other.requests.isEmpty)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
    }

    func testDirtyDurablePrefixAndMemorySuffixCannotUploadUntilFullSourceIsDurable() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.prefix"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(TelemetryEvent(name: "synthetic.suffix"))
        do { try await transport().flush(queue); XCTFail("Do not upload a non-durable suffix") } catch {}
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(queue.persistenceFailureCount, 2, "Enqueue and validated pre-upload write; Blob snapshot must not retry before privacy validation")
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).batchesForFlush().flatMap(\.events).map(\.name),
                       ["synthetic.prefix"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).batchesForFlush().flatMap(\.events).map(\.name),
                       ["synthetic.prefix", "synthetic.suffix"])
        let bytes = try gunzip(requestBody(XCTUnwrap(http.requests.first)))
        XCTAssertEqual(bytes.filter { $0 == 0x0a }.count, 2)
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport().flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).batchesForFlush().isEmpty)
    }

    func testConcurrentFlushFreezesInFlightBatchAndPreservesNewEnqueues() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.in-flight"))
        let entered = expectation(description: "request in flight")
        let release = DispatchSemaphore(value: 0)
        http.state.withLock { $0.onRequest = { entered.fulfill(); _ = release.wait(timeout: .now() + 5) } }
        let sender = try transport()
        let sending = Task { try await sender.flush(queue) }
        await fulfillment(of: [entered], timeout: 3)
        queue.enqueue(TelemetryEvent(name: "synthetic.later"))
        try await sender.flush(queue)
        XCTAssertEqual(http.requests.count, 1)
        http.state.withLock { $0.onRequest = nil }
        release.signal()
        try await sending.value
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.later"])
        try await sender.flush(queue)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertNotEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testConfirmedDeliveryWithFailedRemovalReplaysSameBodyAfterRestart() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.remove"))
        let store = try XCTUnwrap(directory)
        http.state.withLock {
            $0.onRequest = {
                do { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path) }
                catch { XCTFail("Cannot block fixture removal") }
            }
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        do { try await transport().flush(queue); XCTFail("Removal must fail") } catch {}
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        http.state.withLock { $0.onRequest = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport().flush(TelemetryQueue(storeDirectory: store))
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: store).batchesForFlush().isEmpty)
    }

    func testCorruptOrMismatchedJournalCannotAcknowledgeOrOverwriteQueue() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.original"))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let journal = directory.appendingPathComponent("\(id).azure-blob")
        let saved = try Data(contentsOf: journal)
        try Data("corrupt".utf8).write(to: journal)
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        do { try await transport().flush(queue); XCTFail("Corrupt journal") } catch {}
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: journal), Data("corrupt".utf8))
        try saved.write(to: journal)
        try queue.persistBatch(id: id, events: [TelemetryEvent(name: "synthetic.different")])
        let restarted = TelemetryQueue(storeDirectory: directory)
        do { try await transport().flush(restarted); XCTFail("Same ID is not same content") }
        catch { XCTAssertEqual(error as? AzureBlobError, .invalidStoredBatch) }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.different"])
        XCTAssertEqual(try Data(contentsOf: journal), saved)
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(outer["payload"] as? String)))
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("sig="), "Never persist credentials")
    }

    func testRedirectDoesNotSendPayloadOrSASToAnotherHost() async throws {
        let other = BlobHTTPFixture()
        defer { other.close() }
        http.state.withLock {
            $0.status = 307
            $0.redirect = URL(string: other.container.absoluteString + "?sig=fake-redirect")
        }
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.redirect"))
        do { try await transport().flush(queue); XCTFail("Redirect is not delivery") }
        catch { XCTAssertEqual(error as? AzureBlobError, .httpFailure(307)) }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertTrue(other.requests.isEmpty)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
    }

    func testFailedWriteAheadMarkerPreventsNetworkAndCountsStorageFailure() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.marker"))
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "AuthenticationFailed"] }
        do { try await transport().flush(queue) } catch {}
        XCTAssertEqual(http.requests.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        http.state.withLock { $0.status = 201; $0.headers = [:] }
        do { try await transport().flush(queue); XCTFail("Cannot persist attempt marker") }
        catch { XCTAssertEqual(error as? AzureBlobError, .persistenceFailure) }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await transport().flush(queue)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testJournalChecksumMismatchAndUnavailableJournalPreserveSource() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.checksum"))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let journal = directory.appendingPathComponent("\(id).azure-blob")
        let saved = try Data(contentsOf: journal)
        var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(outer["payload"] as? String)))
        payload[payload.startIndex] ^= 1
        outer["payload"] = payload.base64EncodedString()
        try JSONSerialization.data(withJSONObject: outer).write(to: journal)
        do { try await transport().flush(queue); XCTFail("Checksum mismatch") }
        catch { XCTAssertEqual(error as? AzureBlobError, .invalidStoredBatch) }
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        try saved.write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journal.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path) }
        do { try await transport().flush(queue); XCTFail("Unreadable is not absent") }
        catch { XCTAssertEqual(error as? AzureBlobError, .persistenceFailure) }
        XCTAssertEqual(queue.persistenceFailureCount, 2)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
    }

    func testLegacyHistoryAndRotatedLiveBatchesRetainSendOrder() async throws {
        let historyID = UUID()
        let legacy = "[{\"name\":\"synthetic.history\",\"properties\":{},\"timestamp\":\"2023-11-14T22:13:20Z\"}]"
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("\(historyID).json"))
        let queue = TelemetryQueue(storeDirectory: directory)
        for index in 0..<65 { queue.enqueue(TelemetryEvent(name: "synthetic.\(index)")) }
        try await transport().flush(queue)
        let lines = try http.requests.map { try gunzip(requestBody($0)).split(separator: 0x0a) }
        let names = try lines.map { try $0.map { line in
            try XCTUnwrap((JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])?["name"] as? String)
        } }
        XCTAssertEqual(names, [["synthetic.history"], (0..<64).map { "synthetic.\($0)" }, ["synthetic.64"]])
        XCTAssertEqual(Set(http.requests.compactMap(\.url)).count, 3)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testCredentialRotationRetainsOriginalAppInstallBuildPathAndLargeGzipBody() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let largeSynthetic = Dictionary(uniqueKeysWithValues: (0..<12_000).map { ("metric.\($0)", String($0)) })
        queue.enqueue(TelemetryEvent(name: "synthetic.large", properties: largeSynthetic))
        http.state.withLock { $0.error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/?sig=fake-sensitive")!]) }
        do { try await transport(build: "路径 #+?%").flush(queue); XCTFail("Unconfirmed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let first = try XCTUnwrap(http.requests.first)
        let body = try requestBody(first)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: gunzip(body)) as? [String: Any])
        XCTAssertEqual(event["properties"] as? [String: String], largeSynthetic)
        XCTAssertTrue(first.url!.absoluteString.contains("%E8%B7%AF%E5%BE%84%20%23%2B%3F%25"))
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        let changed = try AzureBlobTransport(containerURL: http.container, sasQuery: "?sr=c&sp=c&sig=rotated-fake",
            app: "new-app", build: "new-build", installID: UUID(), privacy: Self.fixturePrivacy, configuration: http.session.configuration)
        try await changed.flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(http.requests.last?.url?.path, first.url?.path)
        XCTAssertEqual(http.requests.last?.url?.query, "sr=c&sp=c&sig=rotated-fake")
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), body)
    }

#if os(macOS)
    func testProcessKillDuringUploadThenRestartRetransmitsExactDurableRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.environment = [:]
        child.arguments = ["-i", "HOME=\(try XCTUnwrap(environment["HOME"]))", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        if let tmp = environment["TMPDIR"] { child.arguments!.append("TMPDIR=\(tmp)") }
        child.arguments! += ["LOKIKIT_BLOB_CRASH_DIRECTORY=\(directory.path)",
                             "LOKIKIT_BLOB_CRASH_CONTAINER=\(http.container.absoluteString)",
                             CommandLine.arguments[0], "-XCTest",
                             "LokiKitTests.AzureBlobTransportTests/testUploadProcessFixture", Bundle(for: Self.self).bundleURL.path]
        let exited = expectation(description: "isolated upload process killed")
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        await fulfillment(of: [exited], timeout: 15)
        guard !child.isRunning else { return }
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        let captured = try JSONDecoder().decode(CapturedBlobRequest.self,
            from: Data(contentsOf: directory.appendingPathComponent("request.capture")))
        let queue = TelemetryQueue(storeDirectory: directory)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.process"])
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport(build: "after-kill").flush(queue)
        XCTAssertEqual(http.requests.first?.url, captured.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), captured.body)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testUploadProcessFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOKIKIT_BLOB_CRASH_DIRECTORY"],
              let endpoint = environment["LOKIKIT_BLOB_CRASH_CONTAINER"] else { return }
        XCTAssertEqual(Set(environment.keys).subtracting(["HOME", "PATH", "TMPDIR",
            "LOKIKIT_BLOB_CRASH_DIRECTORY", "LOKIKIT_BLOB_CRASH_CONTAINER"]), [])
        let fixture = BlobHTTPFixture(container: try XCTUnwrap(URL(string: endpoint)))
        defer { fixture.close() }
        let store = URL(fileURLWithPath: path)
        let queue = TelemetryQueue(storeDirectory: store)
        queue.enqueue(TelemetryEvent(name: "synthetic.process", timestamp: Date(timeIntervalSince1970: 1_700_000_000.321)))
        fixture.state.withLock {
            $0.onRequest = {
                do {
                    let request = try XCTUnwrap(fixture.requests.first)
                    let capture = CapturedBlobRequest(url: try XCTUnwrap(request.url), body: try requestBody(request))
                    try JSONEncoder().encode(capture).write(to: store.appendingPathComponent("request.capture"), options: .atomic)
                    kill(getpid(), SIGKILL)
                } catch { XCTFail("Could not capture synthetic request before kill") }
            }
        }
        let sender = try AzureBlobTransport(containerURL: fixture.container,
            sasQuery: "sv=2023-11-03&sr=c&si=synthetic&sig=fake%2Bonly%2F%3D", app: "sample", build: "before-kill",
            installID: UUID(), privacy: Self.fixturePrivacy, configuration: fixture.session.configuration)
        try await sender.flush(queue)
        XCTFail("Process should have been killed in mocked upload")
    }
#endif
}

private struct CapturedBlobRequest: Codable {
    let url: URL
    let body: Data
}

private final class BlobTimingGate: Sendable {
    private struct State {
        var entered = false
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let entered: XCTestExpectation
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation in
            let result = state.withLock { value -> (notify: Bool, resume: Bool) in
                let notify = !value.entered
                value.entered = true
                if value.released { return (notify, true) }
                precondition(value.continuation == nil)
                value.continuation = continuation
                return (notify, false)
            }
            if result.notify { entered.fulfill() }
            if result.resume { continuation.resume() }
        }
    }
    func release() {
        let continuation = state.withLock { value in
            value.released = true
            let continuation = value.continuation
            value.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

// Only routing is shared; each fixture owns its session, requests and response behavior.
// Unregistered requests fail closed instead of touching DNS or any live receiver.
private final class BlobHTTPFixture: @unchecked Sendable {
    struct State {
        var requests: [URLRequest] = []
        var status = 201
        var headers: [String: String] = [:]
        var error: URLError?
        var redirect: URL?
        var onRequest: (@Sendable () -> Void)?
        var response: (@Sendable (BlobURLProtocol) -> Void)?
        var onStop: (@Sendable () -> Void)?
    }
    let state = Mutex(State())
    let container: URL
    let session: URLSession
    var requests: [URLRequest] { state.withLock { $0.requests } }

    init(container: URL? = nil) {
        self.container = container ?? URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/container")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlobURLProtocol.self]
        session = URLSession(configuration: configuration)
        BlobURLProtocol.fixtures.withLock { $0[self.container.host!] = self }
    }

    func close() {
        session.invalidateAndCancel()
        _ = BlobURLProtocol.fixtures.withLock { $0.removeValue(forKey: container.host!) }
    }
}

private final class BlobURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Mutex<[String: BlobHTTPFixture]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixtures.withLock({ $0[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = fixture.state.withLock { value in
            value.requests.append(request)
            return (value.status, value.headers, value.error, value.onRequest, value.redirect, value.response)
        }
        reply.3?()
        if let respond = reply.5 { respond(self); return }
        if let error = reply.2 {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: reply.1)!
            if let redirect = reply.4 {
                var redirected = request
                redirected.url = redirect
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        let fixture = Self.fixtures.withLock { $0[request.url?.host ?? ""] }
        fixture?.state.withLock { $0.onStop }?()
    }

    func sendResponseChunks(status: Int, code: String? = nil, error: URLError? = nil) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: code.map { ["x-ms-error-code": $0] })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Fixed, bounded fixture; the body is deliberately irrelevant to receipts.
        for _ in 0..<32 { client?.urlProtocol(self, didLoad: Data(repeating: 0x43, count: 8 * 1_024)) }
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }

    func failResponse() {
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }

}

#if os(macOS)
// The real data delegate acknowledges byte counts, not URLProtocol submissions.
// One unacknowledged chunk, with at most a preceding callback still returning.
private final class MeasuredBlobResponse: @unchecked Sendable {
    struct Sample: Sendable {
        let growth: Int
        let sent: Int
        let observed: Int
        let maxOutstanding: Int
    }
    struct Progress: Sendable {
        let sent: Int
        let observed: Int
        let samples: Int
        let holdsResponse: Bool
    }

    private let coordination = DispatchQueue(label: "BlobTests.response-consumption")
    private let stopped = Mutex(false)
    // Everything below is owned by coordination; no external callback runs in a lock.
    private var protocolInstance: BlobURLProtocol?
    private var completion: (@Sendable (Sample) -> Void)?
    private var onPause: (@Sendable () -> Void)?
    private let pauseAfterObservedBytes: Int?
    private var paused = false
    private var samples = 0
    private var baseline = 0
    private var submitted = 0
    private var observed = 0
    private var maxOutstanding = 0
    private let total = 512 * 64 * 1_024

    init(pauseAfterObservedBytes: Int? = nil, onPause: (@Sendable () -> Void)? = nil,
         completion: @escaping @Sendable (Sample) -> Void) {
        self.pauseAfterObservedBytes = pauseAfterObservedBytes
        self.onPause = onPause
        self.completion = completion
    }

    func start(_ instance: BlobURLProtocol) {
        coordination.async {
            guard !self.stopped.withLock({ $0 }) else { return }
            self.protocolInstance = instance
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 201,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.baseline = responseHeapBytes()
            self.coordination.async { self.pump() }
        }
    }

    func observe(_ count: Int) {
        guard count > 0 else { return }
        coordination.async {
            guard !self.stopped.withLock({ $0 }) else { return }
            self.observed += count
            XCTAssertLessThanOrEqual(self.observed, self.submitted)
            if self.observed == self.submitted {
                self.coordination.async { self.pump() }
            }
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        coordination.async {
            self.protocolInstance = nil
            self.completion = nil
            self.onPause = nil
        }
    }

    // A nonblocking fixture pause lets real cancellation win before an already
    // planned next emission/sample. Releasing it still traverses the real fence.
    func resumeAfterPause() async -> Progress {
        await withCheckedContinuation { continuation in
            coordination.async {
                self.paused = false
                self.pump()
                continuation.resume(returning: Progress(sent: self.submitted, observed: self.observed,
                    samples: self.samples, holdsResponse: self.protocolInstance != nil || self.completion != nil || self.onPause != nil))
            }
        }
    }

    private func pump() {
        guard !stopped.withLock({ $0 }), let instance = protocolInstance,
              observed == submitted else { return }
        if observed == pauseAfterObservedBytes, let notify = onPause {
            onPause = nil
            paused = true
            notify()
        }
        guard !paused else { return }
        guard submitted < total else {
            let maySample = stopped.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard maySample else { return }
            let complete = completion
            completion = nil
            protocolInstance = nil
            samples += 1
            let sample = Sample(growth: max(0, responseHeapBytes() - baseline), sent: submitted,
                                observed: observed, maxOutstanding: maxOutstanding)
            complete?(sample)
            instance.failResponse() // Sample before the deliberate real terminal error.
            return
        }
        submitted += 64 * 1_024
        maxOutstanding = max(maxOutstanding, submitted - observed)
        autoreleasepool {
            let bytes = Data(repeating: UInt8((submitted / (64 * 1_024)) % 251), count: 64 * 1_024)
            instance.client?.urlProtocol(instance, didLoad: bytes)
        }
    }
}

private func responseHeapBytes() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics) // In-use allocations across all zones, not RSS/cache size.
    return Int(statistics.size_in_use)
}
#endif

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private func gunzip(_ input: Data) throws -> Data {
    var stream = z_stream()
    XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
    defer { inflateEnd(&stream) }
    return try input.withUnsafeBytes { source in
        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        var output = Data()
        var status: Int32 = Z_OK
        repeat {
            var buffer = [UInt8](repeating: 0, count: 4096)
            status = buffer.withUnsafeMutableBytes { target in
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            guard status == Z_OK || status == Z_STREAM_END else { throw URLError(.cannotDecodeRawData) }
            output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
        } while status != Z_STREAM_END
        XCTAssertEqual(stream.avail_in, 0)
        return output
    }
}

// Construct legacy/malformed synthetic wire fixtures independently of the exporter.
// RFC1952 header + one uncompressed DEFLATE block + CRC32/ISIZE trailer.
private func gzipFixture(_ bytes: Data) throws -> Data {
    guard bytes.count < 65_536 else { throw AzureBlobError.encodingFailure }
    let count = UInt16(bytes.count)
    var result = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff, 0x01])
    result.append(contentsOf: [UInt8(truncatingIfNeeded: count), UInt8(count >> 8),
                              UInt8(truncatingIfNeeded: ~count), UInt8((~count) >> 8)])
    result.append(bytes)
    let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
    for value in [UInt32(checksum), UInt32(bytes.count)] {
        for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    return result
}
