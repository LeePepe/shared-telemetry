import Foundation
import LokiKit
import Synchronization
import XCTest
import zlib
#if os(macOS)
import Darwin
#endif

final class AzureBlobTelemetryServiceTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var receiver: PublicBlobReceiver!
    private static let identityA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let identityB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    override func setUpWithError() throws {
        if let childRoot = ProcessInfo.processInfo.environment["LOKIKIT_PUBLIC_CHILD_ROOT"] {
            directory = URL(fileURLWithPath: childRoot)
        } else {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PublicBlob-\(UUID())")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        receiver = PublicBlobReceiver(endpoint: ProcessInfo.processInfo.environment["LOKIKIT_PUBLIC_CHILD_ENDPOINT"].flatMap(URL.init(string:)))
    }

    override func tearDownWithError() throws {
        receiver.close()
        if ProcessInfo.processInfo.environment["LOKIKIT_PUBLIC_CHILD_ROOT"] == nil { try FileManager.default.removeItem(at: directory) }
    }

    private var policy: AzureBlobPrivacyPolicy {
        AzureBlobPrivacyPolicy(events: ["synthetic.metric": ["count": .finiteNumber, "phase": .label(["done", "retry"])]],
            apps: ["synthetic"], builds: ["one", "two"])
    }

    private func service(enabled: Bool = true, build: String = "one",
                         provider: @escaping @Sendable () throws -> UUID = { identityA }) throws -> AzureBlobTelemetryService {
        try AzureBlobTelemetryService(containerURL: receiver.endpoint, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "synthetic", build: build, privacy: policy, storeDirectory: directory, isEnabled: enabled,
            identityProvider: provider, configuration: receiver.configuration)
    }

    func testPublicAllowedMetricAndNameOnlyEventReachActualCompressedRequest() async throws {
        let telemetry = try service()
        XCTAssertTrue(receiver.requests.isEmpty, "Construction is not upload")
        telemetry.track(name: "synthetic.metric", properties: ["count": "1.25", "phase": "done"])
        telemetry.track(name: "synthetic.metric")
        await telemetry.flush()
        let request = try XCTUnwrap(receiver.requests.first)
        XCTAssertEqual(receiver.requests.count, 1)
        XCTAssertEqual(request.url.pathComponents[2], "synthetic")
        XCTAssertEqual(request.url.pathComponents[3], "one")
        XCTAssertEqual(request.url.pathComponents[5], "11111111-1111-4111-8111-111111111111")
        let events = try decodedEvents(request.body)
        XCTAssertEqual(events.map(\.name), ["synthetic.metric", "synthetic.metric"])
        XCTAssertEqual(events[0].properties, ["count": "1.25", "phase": "done"])
        XCTAssertEqual(events[1].properties, [:])
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 2)
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.count, 1, "Confirmed work is drained")
    }

    func testCapacityAndPersistentLossCountAreSharedAcrossIdentityEpochs() throws {
        let identities = Mutex([Self.identityA, Self.identityB, UUID(uuidString: "33333333-3333-4333-8333-333333333333")!])
        var telemetry: AzureBlobTelemetryService? = try AzureBlobTelemetryService(
            containerURL: receiver.endpoint, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "synthetic", build: "one", privacy: policy, storeDirectory: directory, isEnabled: true,
            identityProvider: { identities.withLock { $0.removeFirst() } },
            configuration: receiver.configuration, maxDiskBytes: 250)
        telemetry?.track(name: "synthetic.metric", properties: ["count": "1"])
        telemetry?.resetIdentifier()
        telemetry?.track(name: "synthetic.metric", properties: ["count": "2"])
        telemetry?.resetIdentifier()
        telemetry?.track(name: "synthetic.metric", properties: ["count": "3"])
        XCTAssertEqual(telemetry?.diagnostics.droppedEventCount, 1)
        let records = try persistedFiles().filter { $0.key.hasSuffix(".json") && !$0.key.hasSuffix("catalog.json") }
        XCTAssertLessThanOrEqual(records.values.reduce(0) { $0 + $1.count }, 250)
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records.values.contains { String(decoding: $0, as: UTF8.self).contains("\"count\":\"1\"") })
        telemetry = nil
        let restored = try AzureBlobTelemetryService(
            containerURL: receiver.endpoint, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "synthetic", build: "one", privacy: policy, storeDirectory: directory, isEnabled: true,
            identityProvider: { throw PublicBlobFixtureError.providerCalledOnRestore },
            configuration: receiver.configuration, maxDiskBytes: 250)
        XCTAssertEqual(restored.diagnostics.droppedEventCount, 1)
    }

    func testInvalidCapacityFailBeforeIdentityOrStorage() throws {
        let calls = Mutex(0)
        for capacity in [0, -1] {
            XCTAssertThrowsError(try AzureBlobTelemetryService(
                containerURL: receiver.endpoint, sasQuery: "sr=c&sp=c&sig=synthetic-only",
                app: "synthetic", build: "one",
                privacy: AzureBlobPrivacyPolicy(apps: ["synthetic"], builds: ["one"]),
                storeDirectory: directory, isEnabled: true,
                identityProvider: { calls.withLock { $0 += 1 }; return Self.identityA },
                configuration: receiver.configuration, maxDiskBytes: capacity)) {
                XCTAssertEqual($0 as? AzureBlobTelemetryError, .invalidConfiguration)
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertTrue(try persistedFiles().isEmpty)
        XCTAssertTrue(receiver.requests.isEmpty)
    }

    func testUnsafeWholeEventNeverEntersAcceptedStorageOrWire() async throws {
        let telemetry = try service()
        let canary = "synthetic-transcript-CANARY"
        telemetry.track(name: "synthetic.metric", properties: ["count": "1", "phase": canary])
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 0)
        XCTAssertEqual(telemetry.diagnostics.rejectedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.lastError, .privacyRejected)
        for bytes in try persistedFiles().values {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(canary))
        }
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        await telemetry.flush()
        XCTAssertEqual(try decodedEvents(XCTUnwrap(receiver.requests.first).body).map(\.properties), [["count": "2"]])
    }

    private func persistedFiles() throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path))
        var result: [String: Data] = [:]
        for case let relative as String in enumerator {
            let url = directory.appendingPathComponent(relative)
            if try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular {
                result[relative] = try Data(contentsOf: url)
            }
        }
        return result
    }

    func testResetBeforeFirstFlushAndRecreationKeepAdmissionIdentity() async throws {
        let identities = Mutex([Self.identityA, Self.identityB])
        var first: AzureBlobTelemetryService? = try service(provider: { identities.withLock { $0.removeFirst() } })
        first?.track(name: "synthetic.metric", properties: ["count": "1"])
        first?.resetIdentifier()
        first?.track(name: "synthetic.metric", properties: ["count": "2"])
        first = nil
        let restored = try service(provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        await restored.flush()
        XCTAssertEqual(receiver.requests.count, 2)
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[5] }, [
            "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
        ])
        XCTAssertEqual(try receiver.requests.flatMap { try decodedEvents($0.body).map(\.properties) }, [["count": "1"], ["count": "2"]])
        XCTAssertTrue(identities.withLock { $0.isEmpty })
    }

    func testMalformedSourceBlocksFlushWithoutRepairingFromMemory() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let source = try XCTUnwrap(try persistedFiles().keys.first { $0.hasSuffix(".json") && !$0.hasSuffix("catalog.json") })
        try Data("synthetic-corrupt-source".utf8).write(to: directory.appendingPathComponent(source))
        let before = try persistedFiles()
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(try persistedFiles(), before)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
    }

    func testDisableCancelsUnconfirmedFlightAndRetainsWorkForExplicitRetry() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let entered = expectation(description: "real protocol received headers without completion")
        let stopped = expectation(description: "owned task stopped")
        let finish = Mutex<(@Sendable () -> Void)?>(nil)
        let stopCount = Mutex(0)
        receiver.state.withLock { state in
            state.respond = { transport in
                let fail: @Sendable () -> Void = { transport.fail() }
                finish.withLock { $0 = fail }
                transport.headers(status: 201)
                entered.fulfill()
            }
            state.onStop = { stopCount.withLock { $0 += 1 }; stopped.fulfill() }
        }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        let frozen = try persistedFiles()
        telemetry.isEnabled = false
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        await fulfillment(of: [stopped], timeout: 2)
        if stopCount.withLock({ $0 }) == 0 { finish.withLock { $0 }?() } // Drain only a failed implementation.
        await flushing.value
        XCTAssertEqual(try persistedFiles(), frozen)
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.disabledEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        receiver.state.withLock { $0.respond = nil; $0.onStop = nil }
        telemetry.isEnabled = true
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.count, 2)
        XCTAssertEqual(receiver.requests[0].url, receiver.requests[1].url)
        XCTAssertEqual(receiver.requests[0].body, receiver.requests[1].body)
    }

    func testCatalogReadFailureCancelsUnconfirmedFlightWithoutHidingPersistenceError() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let entered = expectation(description: "actual request has only response headers")
        let stopped = expectation(description: "invalid store cancels owned request")
        let fallback = Mutex<(@Sendable () -> Void)?>(nil)
        let stopCount = Mutex(0)
        receiver.state.withLock { state in
            state.respond = { transport in
                let fail: @Sendable () -> Void = { transport.fail() }
                fallback.withLock { $0 = fail }
                transport.headers(status: 201)
                entered.fulfill()
            }
            state.onStop = { stopCount.withLock { $0 += 1 }; stopped.fulfill() }
        }
        let flushing = Task { await telemetry.flush() }
        await fulfillment(of: [entered], timeout: 3)
        let retained = try persistedFiles()
        // Catalog remains readable by name, but its owned directory cannot be enumerated.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        telemetry.track(name: "synthetic.metric", properties: ["count": "99"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        await fulfillment(of: [stopped], timeout: 2)
        if stopCount.withLock({ $0 }) == 0 { fallback.withLock { $0 }?() }
        await flushing.value
        XCTAssertEqual(try persistedFiles(), retained)
        XCTAssertEqual(telemetry.diagnostics.lastError, .persistenceFailure)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 1)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.count, 1, "Restoring access alone cannot reopen an invalid generation/store")
    }

    func testAlreadyCancelledPublicFlushCannotStartAndLaterCallerCanRetry() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let before = try persistedFiles()
        let flushing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await telemetry.flush()
        }
        await flushing.value
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(try persistedFiles(), before)
        XCTAssertFalse(telemetry.diagnostics.isFlushActive)
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.count, 1)
        XCTAssertEqual(try decodedEvents(XCTUnwrap(receiver.requests.first).body).map(\.properties), [["count": "1"]])
    }

    func testFailedResetPauseIsInstanceLocalAndRecreationRequiresExplicitConsent() async throws {
        let calls = Mutex(0)
        var telemetry: AzureBlobTelemetryService? = try service(provider: {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { return Self.identityA }
            throw PublicBlobFixtureError.providerCalledOnRestore
        })
        telemetry?.track(name: "synthetic.metric", properties: ["count": "1"])
        let before = try persistedFiles()
        telemetry?.resetIdentifier()
        telemetry?.isEnabled = false
        telemetry?.isEnabled = true
        telemetry?.track(name: "synthetic.metric", properties: ["count": "99"])
        XCTAssertEqual(telemetry?.diagnostics.identityFailureCount, 1)
        XCTAssertEqual(telemetry?.diagnostics.identityBlockedEventCount, 1)
        XCTAssertEqual(telemetry?.diagnostics.isAdmissionReady, false)
        XCTAssertEqual(telemetry?.diagnostics.lastError, .identityUnavailable)
        XCTAssertEqual(try persistedFiles(), before)
        telemetry = nil
        var disabled: AzureBlobTelemetryService? = try service(enabled: false, provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        disabled?.track(name: "synthetic.metric", properties: ["count": "88"])
        await disabled?.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(disabled?.diagnostics.disabledEventCount, 1)
        disabled = nil
        let restored = try service(provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        XCTAssertTrue(restored.diagnostics.isAdmissionReady)
        XCTAssertEqual(restored.diagnostics.identityFailureCount, 0)
        restored.track(name: "synthetic.metric", properties: ["count": "2"])
        await restored.flush()
        XCTAssertEqual(try receiver.requests.flatMap { try decodedEvents($0.body).map(\.properties) }, [["count": "1"], ["count": "2"]])
        XCTAssertTrue(receiver.requests.allSatisfy { $0.url.pathComponents[5] == "11111111-1111-4111-8111-111111111111" })
    }

    func testDuplicateResetPausesThenSuccessfulResetRestoresOnlyFutureAdmission() async throws {
        let ids = Mutex([Self.identityA, Self.identityA, Self.identityB])
        let telemetry = try service(provider: { ids.withLock { $0.removeFirst() } })
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        telemetry.resetIdentifier()
        XCTAssertEqual(telemetry.diagnostics.lastError, .duplicateIdentity)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        telemetry.track(name: "synthetic.metric", properties: ["count": "99"])
        telemetry.resetIdentifier()
        XCTAssertTrue(telemetry.diagnostics.isAdmissionReady)
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        await telemetry.flush()
        XCTAssertEqual(try receiver.requests.flatMap { try decodedEvents($0.body).map(\.properties) }, [["count": "1"], ["count": "2"]])
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[5] }, [Self.identityA.uuidString.lowercased(), Self.identityB.uuidString.lowercased()])
    }

    func testSupplierResetFailureLeavesPausedInstanceBacklogFlushable() async throws {
        try await assertPausedInstanceBacklogFlushes(duplicate: false)
    }

    func testDuplicateResetFailureLeavesPausedInstanceBacklogFlushable() async throws {
        try await assertPausedInstanceBacklogFlushes(duplicate: true)
    }

    private func assertPausedInstanceBacklogFlushes(duplicate: Bool) async throws {
        let calls = Mutex(0)
        let telemetry = try service(provider: {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 || duplicate { return Self.identityA }
            throw PublicBlobFixtureError.providerCalledOnRestore
        })
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let before = try persistedFiles()
        telemetry.resetIdentifier()
        telemetry.isEnabled = false
        telemetry.isEnabled = true
        telemetry.track(name: "synthetic.metric", properties: ["count": "99"])
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(try persistedFiles(), before)
        await telemetry.flush() // Same failed-reset instance, without a successful reset or reconstruction.
        XCTAssertEqual(receiver.requests.count, 1)
        let request = try XCTUnwrap(receiver.requests.first)
        XCTAssertEqual(request.url.pathComponents[5], Self.identityA.uuidString.lowercased())
        XCTAssertEqual(try decodedEvents(request.body).map(\.properties), [["count": "1"]])
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(telemetry.diagnostics.lastError, duplicate ? .duplicateIdentity : .identityUnavailable)
        XCTAssertEqual(telemetry.diagnostics.identityBlockedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.identityFailureCount, 1)
        XCTAssertEqual(telemetry.diagnostics.cancellationCount, 0)
        XCTAssertEqual(telemetry.diagnostics.transportFailureCount, 0)
        XCTAssertEqual(Set(try persistedFiles().keys), ["catalog.json", ".owner-lock"])
    }

    func testNewBuildRecreationKeepsOldUnjournaledBuildAndDoesNotCallProvider() async throws {
        var first: AzureBlobTelemetryService? = try service()
        first?.track(name: "synthetic.metric", properties: ["count": "1"])
        first = nil
        let second = try service(build: "two", provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        second.track(name: "synthetic.metric", properties: ["count": "2"])
        await second.flush()
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[3] }, ["one", "two"])
        XCTAssertTrue(receiver.requests.allSatisfy { $0.url.pathComponents[5] == Self.identityA.uuidString.lowercased() })
    }

    func testLazyEmptyEpochAndFailedFirstWriteCanRetryFullSource() async throws {
        let telemetry = try service()
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(Set(try persistedFiles().keys), ["catalog.json", ".owner-lock"])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        receiver.state.withLock { state in
            state.respond = { request in
                do {
                    let source = try XCTUnwrap(try self.persistedFiles().first { $0.key.hasSuffix(".json") && $0.key != "catalog.json" })
                    XCTAssertTrue(String(decoding: source.value, as: UTF8.self).contains("\"count\":\"1\""))
                } catch { XCTFail("Full source must exist before transport") }
                request.headers(status: 201)
                request.finish()
            }
        }
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.count, 1)
        XCTAssertEqual(try decodedEvents(XCTUnwrap(receiver.requests.first).body).first?.properties, ["count": "1"])
    }

    func testResetCatalogWriteFailureRetainsPriorStateUntilSuccessfulReset() async throws {
        let ids = Mutex([Self.identityA, Self.identityB, Self.identityB])
        let telemetry = try service(provider: { ids.withLock { $0.removeFirst() } })
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let before = try persistedFiles()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        telemetry.resetIdentifier()
        XCTAssertEqual(telemetry.diagnostics.lastError, .persistenceFailure)
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(try persistedFiles(), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        telemetry.resetIdentifier()
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[5] }, [Self.identityA.uuidString.lowercased(), Self.identityB.uuidString.lowercased()])
    }

    func testSupplierCanReenterWithoutLocksAndDisableDuringReset() async throws {
        let reference = Mutex<AzureBlobTelemetryService?>(nil)
        defer { reference.withLock { $0 = nil } }
        let calls = Mutex(0)
        let telemetry = try service(provider: {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { return Self.identityA }
            let owner = reference.withLock { $0 }
            owner?.resetIdentifier() // Must return resetInProgress, not invoke this callback recursively.
            owner?.isEnabled = false
            return Self.identityB
        })
        reference.withLock { $0 = telemetry }
        telemetry.resetIdentifier()
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(telemetry.diagnostics.lastError, .resetInProgress)
        XCTAssertFalse(telemetry.isEnabled)
        telemetry.track(name: "synthetic.metric")
        XCTAssertEqual(telemetry.diagnostics.disabledEventCount, 1)
        telemetry.isEnabled = true
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        await telemetry.flush()
        XCTAssertEqual(receiver.requests.first?.url.pathComponents[5], Self.identityB.uuidString.lowercased())
    }

    func testUnownedLegacyRootAndInvalidConfigurationDoNotCallProviderOrAlterBytes() throws {
        let legacy = directory.appendingPathComponent("legacy.json")
        try Data("synthetic-legacy-CANARY".utf8).write(to: legacy)
        let before = try persistedFiles()
        let calls = Mutex(0)
        XCTAssertThrowsError(try service(provider: { calls.withLock { $0 += 1 }; return Self.identityA })) {
            XCTAssertEqual($0 as? AzureBlobTelemetryError, .invalidStore)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(try persistedFiles(), before)
        XCTAssertThrowsError(try AzureBlobTelemetryService(containerURL: receiver.endpoint,
            sasQuery: "sr=c&sp=rw&sig=synthetic-only", app: "synthetic", build: "one", privacy: policy,
            storeDirectory: directory, isEnabled: true, identityProvider: { calls.withLock { $0 += 1 }; return Self.identityA })) {
            XCTAssertEqual($0 as? AzureBlobTelemetryError, .invalidConfiguration)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(try persistedFiles(), before)
    }

    func testAllUnsafePresentFieldsAndNonfiniteTimestampsAreRejectedWithoutFiles() throws {
        let telemetry = try service()
        let before = try persistedFiles()
        let events = [
            TelemetryEvent(name: "synthetic-transcript-CANARY"),
            TelemetryEvent(name: "synthetic.metric", properties: ["error": "synthetic-CANARY"]),
            TelemetryEvent(name: "synthetic.metric", properties: ["phase": "synthetic-CANARY"]),
            TelemetryEvent(name: "synthetic.metric", properties: ["count": "NaN"]),
            TelemetryEvent(name: "synthetic.metric", properties: ["count": "Infinity"]),
            TelemetryEvent(name: "synthetic.metric", properties: ["count": "1e999"]),
            TelemetryEvent(name: "synthetic.metric", properties: ["count": "1 trailing-text"]),
            TelemetryEvent(name: "synthetic.metric", timestamp: Date(timeIntervalSince1970: .infinity))
        ]
        for event in events { telemetry.track(event) }
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 0)
        XCTAssertEqual(telemetry.diagnostics.rejectedEventCount, 8)
        XCTAssertEqual(try persistedFiles(), before)
        XCTAssertEqual(String(describing: telemetry.diagnostics.lastError!), "privacyRejected")
    }

    func testCorruptCatalogBlocksReadinessAdmissionAndFlushWithoutReplacement() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        try Data("synthetic-bad-catalog".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        let before = try persistedFiles()
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 1)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(try persistedFiles(), before)
    }

    func testInvalidUnownedCatalogDoesNotCreateLeaseOrRepairStore() throws {
        try Data("synthetic-invalid-catalog".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        let before = try persistedFiles()
        XCTAssertThrowsError(try service()) { XCTAssertEqual($0 as? AzureBlobTelemetryError, .invalidStore) }
        XCTAssertEqual(try persistedFiles(), before)
    }

    func testDirtyPrefixAndMemorySuffixKeepOldIdentityAcrossReset() async throws {
        let ids = Mutex([Self.identityA, Self.identityB])
        let telemetry = try service(provider: { ids.withLock { $0.removeFirst() } })
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let source = try XCTUnwrap(try persistedFiles().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        let epoch = directory.appendingPathComponent(source).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: epoch.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: epoch.path) }
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: epoch.path)
        telemetry.resetIdentifier()
        telemetry.track(name: "synthetic.metric", properties: ["count": "3"])
        await telemetry.flush()
        XCTAssertEqual(try receiver.requests.map { try decodedEvents($0.body).map(\.properties) }, [[["count": "1"], ["count": "2"]], [["count": "3"]]])
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[5] }, [Self.identityA.uuidString.lowercased(), Self.identityB.uuidString.lowercased()])
    }

    func testSymlinkSourceIsRetainedWithoutFollowingOrUploadingIt() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let relative = try XCTUnwrap(try persistedFiles().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        let source = directory.appendingPathComponent(relative)
        let catalog = try Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: directory.appendingPathComponent("catalog.json"))
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.json")), catalog)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testKnownLiveMissingSourceBlocksWithoutInventingRestartInventory() async throws {
        var telemetry: AzureBlobTelemetryService? = try service()
        telemetry?.track(name: "synthetic.metric", properties: ["count": "1"])
        let relative = try XCTUnwrap(try persistedFiles().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        try FileManager.default.removeItem(at: directory.appendingPathComponent(relative)) // Owned deletion fault only.
        await telemetry?.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(telemetry?.diagnostics.lastError, .persistenceFailure)
        telemetry = nil
        let restored = try service(provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        await restored.flush()
        XCTAssertTrue(receiver.requests.isEmpty, "No catalog field can recover/detect an externally deleted unindexed record after exit")
    }

    func testInertSidecarAfterConfirmedSourceCleanupIsNotUploadedOrDeleted() async throws {
        let saved = Mutex<(String, Data)?>(nil)
        receiver.state.withLock { state in
            state.respond = { request in
                do {
                    let entry = try XCTUnwrap(try self.persistedFiles().first { $0.key.hasSuffix(".azure-blob") })
                    saved.withLock { $0 = (entry.key, entry.value) }
                } catch { XCTFail("Expected actual immutable sidecar before acknowledgement") }
                request.headers(status: 201)
                request.finish()
            }
        }
        var first: AzureBlobTelemetryService? = try service()
        first?.track(name: "synthetic.metric", properties: ["count": "1"])
        await first?.flush()
        first = nil
        let (relative, bytes) = try XCTUnwrap(saved.withLock { $0 })
        try bytes.write(to: directory.appendingPathComponent(relative)) // Recreate only the permitted post-cleanup sidecar artifact.
        let before = try persistedFiles()
        let restored = try service(provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        await restored.flush()
        XCTAssertEqual(receiver.requests.count, 1)
        XCTAssertEqual(try persistedFiles(), before)
    }

    func testNoncanonicalSourceAliasIsNotImportedOrRewritten() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let relative = try XCTUnwrap(try persistedFiles().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        let epoch = directory.appendingPathComponent(relative).deletingLastPathComponent()
        let alias = epoch.appendingPathComponent("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json")
        try Data(#"[{"name":"synthetic.metric","properties":{"count":"9"},"timestamp":"2023-11-14T22:13:20Z"}]"#.utf8).write(to: alias)
        let before = try persistedFiles()
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(try persistedFiles(), before)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
    }

    func testUnknownCatalogFieldsAreNotSilentlyIgnored() throws {
        let telemetry = try service()
        let url = directory.appendingPathComponent("catalog.json")
        var wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        wrapper["unexpected"] = "synthetic-CANARY"
        try JSONSerialization.data(withJSONObject: wrapper).write(to: url)
        let before = try persistedFiles()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        XCTAssertEqual(telemetry.diagnostics.acceptedEventCount, 0)
        XCTAssertFalse(telemetry.diagnostics.isAdmissionReady)
        XCTAssertEqual(try persistedFiles(), before)
    }

    func testUnknownSourceFieldsCannotBeSilentlyFilteredAndAcknowledged() async throws {
        let telemetry = try service()
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let relative = try XCTUnwrap(try persistedFiles().keys.first { $0.hasSuffix(".json") && $0 != "catalog.json" })
        let url = directory.appendingPathComponent(relative)
        var events = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        events[0]["unexpected"] = "synthetic-CANARY"
        try JSONSerialization.data(withJSONObject: events).write(to: url)
        let before = try persistedFiles()
        await telemetry.flush()
        XCTAssertTrue(receiver.requests.isEmpty)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidStore)
        XCTAssertEqual(try persistedFiles(), before)
    }

    func testConcurrentTrackDuringSupplierBelongsToOldEpochAndDisableStillWins() async throws {
        let entered = expectation(description: "provider outside state lock")
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let telemetry = try service(provider: {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { return Self.identityA }
            entered.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw PublicBlobFixtureError.childDidNotExit }
            return Self.identityB
        })
        telemetry.track(name: "synthetic.metric", properties: ["count": "1"])
        let resetting = Task.detached { telemetry.resetIdentifier() }
        await fulfillment(of: [entered], timeout: 2)
        telemetry.track(name: "synthetic.metric", properties: ["count": "2"])
        telemetry.resetIdentifier() // Busy: does not invoke another provider.
        telemetry.isEnabled = false
        release.signal()
        await resetting.value
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertFalse(telemetry.isEnabled)
        telemetry.track(name: "synthetic.metric", properties: ["count": "99"])
        telemetry.isEnabled = true
        telemetry.track(name: "synthetic.metric", properties: ["count": "3"])
        await telemetry.flush()
        XCTAssertEqual(try receiver.requests.map { try decodedEvents($0.body).map(\.properties) }, [[["count": "1"], ["count": "2"]], [["count": "3"]]])
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[5] }, [Self.identityA.uuidString.lowercased(), Self.identityB.uuidString.lowercased()])
    }

    func testNonlocalFileURLCannotInitializeOrProvisionIdentity() throws {
        var location = try XCTUnwrap(URLComponents(url: directory, resolvingAgainstBaseURL: false))
        location.host = "remote.example.invalid"
        let calls = Mutex(0)
        XCTAssertThrowsError(try AzureBlobTelemetryService(containerURL: receiver.endpoint,
            sasQuery: "sr=c&sp=c&sig=synthetic-only", app: "synthetic", build: "one", privacy: policy,
            storeDirectory: XCTUnwrap(location.url), isEnabled: true,
            identityProvider: { calls.withLock { $0 += 1 }; return Self.identityA }, configuration: receiver.configuration)) {
            XCTAssertEqual($0 as? AzureBlobTelemetryError, .invalidConfiguration)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertTrue(try persistedFiles().isEmpty)
    }

#if os(macOS)
    private func runStoreChild(_ mode: String) async throws -> Process {
        let environment = ProcessInfo.processInfo.environment
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // env -i must remove this synthetic negative control before XCTest starts.
        child.environment = ["LOKIKIT_PUBLIC_SYNTHETIC_SENTINEL": "must-not-reach-fixture"]
        child.arguments = ["-i", "HOME=\(try XCTUnwrap(environment["HOME"]))", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        if let tmp = environment["TMPDIR"] { child.arguments!.append("TMPDIR=\(tmp)") }
        child.arguments! += ["LOKIKIT_PUBLIC_CHILD_ROOT=\(directory.path)", "LOKIKIT_PUBLIC_CHILD_MODE=\(mode)",
            "LOKIKIT_PUBLIC_CHILD_ENDPOINT=\(receiver.endpoint.absoluteString)", CommandLine.arguments[0],
            "-XCTest", "LokiKitTests.AzureBlobTelemetryServiceTests/testPublicStoreProcessFixture", Bundle(for: Self.self).bundleURL.path]
        let exited = expectation(description: "owned synthetic child exited")
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        await fulfillment(of: [exited], timeout: 10)
        guard !child.isRunning else { throw PublicBlobFixtureError.childDidNotExit }
        return child
    }

    func testPublicAdmissionIdentitySurvivesSIGKILLBeforeAnyFlush() async throws {
        let child = try await runStoreChild("kill")
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        XCTAssertFalse(try persistedFiles().keys.contains { $0.hasSuffix(".azure-blob") })
        let restored = try service(provider: { throw PublicBlobFixtureError.providerCalledOnRestore })
        await restored.flush()
        XCTAssertEqual(receiver.requests.map { $0.url.pathComponents[5] }, [Self.identityA.uuidString.lowercased(), Self.identityB.uuidString.lowercased()])
        XCTAssertEqual(try receiver.requests.flatMap { try decodedEvents($0.body).map(\.properties) }, [["count": "41"], ["count": "42"]])
    }

    func testStoreLeaseRefusesSameAndOtherProcessOwner() async throws {
        let telemetry = try service()
        XCTAssertThrowsError(try service()) { XCTAssertEqual($0 as? AzureBlobTelemetryError, .storeInUse) }
        let child = try await runStoreChild("lease")
        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(telemetry.isEnabled) // Keep the first lease alive through both attempts.
    }

    func testPublicStoreProcessFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["LOKIKIT_PUBLIC_CHILD_MODE"] else { return }
        let allowed: Set<String> = ["HOME", "PATH", "TMPDIR", "LOKIKIT_PUBLIC_CHILD_ROOT",
            "LOKIKIT_PUBLIC_CHILD_ENDPOINT", "LOKIKIT_PUBLIC_CHILD_MODE", "__CF_USER_TEXT_ENCODING"]
        // CoreFoundation can add this noncredential encoding token during XCTest/setUp.
        // It is not passed by the launcher. Do not print it or the environment.
        let encodingIsValid = environment["__CF_USER_TEXT_ENCODING"].map {
            $0.range(of: #"^[0-9A-Fa-fx]+:[0-9A-Fa-fx]+:[0-9A-Fa-fx]+$"#, options: .regularExpression) != nil
        } ?? true
        guard Set(environment.keys).isSubset(of: allowed), encodingIsValid,
              environment["LOKIKIT_PUBLIC_SYNTHETIC_SENTINEL"] == nil else {
            XCTFail("Isolated fixture received non-allowlisted environment input")
            return
        }
        if mode == "lease" {
            XCTAssertThrowsError(try service(provider: { throw PublicBlobFixtureError.providerCalledOnRestore })) {
                XCTAssertEqual($0 as? AzureBlobTelemetryError, .storeInUse)
            }
            return
        }
        guard mode == "kill" else { XCTFail("Unknown synthetic child mode"); return }
        let identities = Mutex([Self.identityA, Self.identityB])
        let telemetry = try service(provider: { identities.withLock { $0.removeFirst() } })
        telemetry.track(name: "synthetic.metric", properties: ["count": "41"])
        telemetry.resetIdentifier()
        telemetry.track(name: "synthetic.metric", properties: ["count": "42"])
        XCTAssertEqual(telemetry.diagnostics.persistenceFailureCount, 0)
        kill(getpid(), SIGKILL)
    }
#endif
}

private enum PublicBlobFixtureError: Error { case providerCalledOnRestore, childDidNotExit }

private struct PublicBlobRequest: Sendable {
    let url: URL
    let body: Data
}

private final class PublicBlobReceiver: @unchecked Sendable {
    struct State {
        var requests: [PublicBlobRequest] = []
        var status = 201
        var respond: (@Sendable (PublicBlobProtocol) -> Void)?
        var onStop: (@Sendable () -> Void)?
    }
    let state = Mutex(State())
    let endpoint: URL
    var requests: [PublicBlobRequest] { state.withLock { $0.requests } }
    var configuration: URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.protocolClasses = [PublicBlobProtocol.self]
        return value
    }
    init(endpoint: URL? = nil) {
        self.endpoint = endpoint ?? URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/container")!
        PublicBlobProtocol.receivers.withLock { $0[self.endpoint.host!] = self }
    }
    func close() { _ = PublicBlobProtocol.receivers.withLock { $0.removeValue(forKey: endpoint.host!) } }
}

private final class PublicBlobProtocol: URLProtocol, @unchecked Sendable {
    static let receivers = Mutex<[String: PublicBlobReceiver]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let receiver = Self.receivers.withLock({ $0[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let captured = PublicBlobRequest(url: try XCTUnwrap(request.url), body: try publicRequestBody(request))
            let reply = receiver.state.withLock { $0.requests.append(captured); return ($0.status, $0.respond) }
            if let respond = reply.1 { respond(self); return }
            headers(status: reply.0)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData)) }
    }
    func headers(status: Int) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {
        let receiver = Self.receivers.withLock { $0[request.url?.host ?? ""] }
        receiver?.state.withLock { $0.onStop }?()
    }
}

private func publicRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private func decodedEvents(_ gzip: Data) throws -> [TelemetryEvent] {
    var stream = z_stream()
    XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
    defer { inflateEnd(&stream) }
    let data = try gzip.withUnsafeBytes { bytes -> Data in
        stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(bytes.count)
        var result = Data()
        var code: Int32 = Z_OK
        while code == Z_OK {
            var output = [UInt8](repeating: 0, count: 4096)
            code = output.withUnsafeMutableBytes {
                stream.next_out = $0.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt($0.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            result.append(contentsOf: output.prefix(output.count - Int(stream.avail_out)))
        }
        guard code == Z_STREAM_END, stream.avail_in == 0 else { throw URLError(.cannotDecodeContentData) }
        return result
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: 0x0a).map { try decoder.decode(TelemetryEvent.self, from: Data($0)) }
}
