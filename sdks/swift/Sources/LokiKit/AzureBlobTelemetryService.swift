import Foundation
import Synchronization

/// Explicit-consent Blob telemetry, with direct configuration or host-bundle configuration.
public final class AzureBlobTelemetryService: TelemetryService, @unchecked Sendable {
    private struct Generation {
        let id: UInt64
        let control: BlobRequestControl
        let task: Task<Void, Never>
    }
    // Owned by one public flush invocation; accessed only under the service mutex.
    // Unlike the active slot, registration survives worker finalization until its
    // caller's cancellation handler has finished. No completed-ID registry is kept.
    private final class FlushRegistration: @unchecked Sendable {
        var registered = false
    }
    private struct State {
        var enabled: Bool
        var accepted = 0
        var rejected = 0
        var disabled = 0
        var identityBlocked = 0
        var identityFailures = 0
        var transportFailures = 0
        var ready = true
        var resetting = false
        var active: Generation?
        var nextGeneration: UInt64 = 0
        var cancellations = 0
        var lastError: AzureBlobTelemetryError?
        var lastHeartbeat: TelemetryEvent?
        var lastSuccessfulUpload: Date?
        var lastFlushFailed = false
    }
    private let state: Mutex<State>
    private let store: AzureBlobEventStore?
    private let privacy: AzureBlobPrivacyPolicy
    private let identityProvider: @Sendable () throws -> UUID
    private let containerURL: URL?
    private let sasQuery: String?
    private let app: String
    private let build: String
    private let protocolClasses: [AnyClass]?
    private let synchronization: BlobRequestSynchronization?
    private let heartbeatVersion: String?
    private let heartbeatClock: BlobHeartbeatClock
    private var cancelHeartbeat: (@Sendable () -> Void)?

    public convenience init(containerURL: URL, sasQuery: String, app: String, build: String,
                privacy: AzureBlobPrivacyPolicy, storeDirectory: URL, isEnabled: Bool,
                identityProvider: @escaping @Sendable () throws -> UUID,
                configuration: URLSessionConfiguration = .ephemeral, maxDiskBytes: Int = 50 * 1024 * 1024,
                heartbeatVersion: String? = nil) throws {
        try self.init(containerURL: containerURL, sasQuery: sasQuery, app: app, build: build,
            privacy: privacy, storeDirectory: storeDirectory, isEnabled: isEnabled,
            identityProvider: identityProvider, configuration: configuration, synchronization: nil,
            maxDiskBytes: maxDiskBytes, heartbeatVersion: heartbeatVersion)
    }

    /// Build settings reach the SDK through expanded host Info.plist strings.
    /// Missing settings are observable and disabled; they never select a fallback destination.
    public convenience init(bundle: Bundle = .main, app: String, build: String, version: String,
                privacy: AzureBlobPrivacyPolicy, storeDirectory: URL, isEnabled: Bool,
                identityProvider: @escaping @Sendable () throws -> UUID,
                configuration: URLSessionConfiguration = .ephemeral, maxDiskBytes: Int = 50 * 1024 * 1024) throws {
        func setting(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.contains("$(") else { return nil }
            return value
        }
        let endpoint: URL?
        let sas: String?
        if let endpointString = setting("LokiKitBlobEndpoint"), let query = setting("LokiKitBlobSAS") {
            guard let url = URL(string: endpointString) else { throw AzureBlobTelemetryError.invalidConfiguration }
            endpoint = url
            sas = query
        } else { endpoint = nil; sas = nil }
        try self.init(containerURL: endpoint, sasQuery: sas, app: app, build: build, privacy: privacy,
            storeDirectory: storeDirectory, isEnabled: isEnabled, identityProvider: identityProvider,
            configuration: configuration, synchronization: nil, maxDiskBytes: maxDiskBytes, heartbeatVersion: version)
    }

    internal init(containerURL: URL?, sasQuery: String?, app: String, build: String,
                  privacy: AzureBlobPrivacyPolicy, storeDirectory: URL, isEnabled: Bool,
                  identityProvider: @escaping @Sendable () throws -> UUID,
                  configuration: URLSessionConfiguration, synchronization: BlobRequestSynchronization?,
                  atomicWriteFault: AzureBlobEventStore.AtomicWriteFault? = nil, maxDiskBytes: Int = 50 * 1024 * 1024,
                  heartbeatVersion: String? = nil, heartbeatClock: BlobHeartbeatClock = .live) throws {
        guard maxDiskBytes > 0 else { throw AzureBlobTelemetryError.invalidConfiguration }
        let privacy = try heartbeatVersion.map { try privacy.includingHeartbeat(version: $0) } ?? privacy
        do {
            try privacy.validateMetadata(app: app, build: build)
            if let containerURL, let sasQuery {
                _ = try AzureBlobTransport(containerURL: containerURL, sasQuery: sasQuery, app: app, build: build,
                    installID: UUID(), privacy: privacy, configuration: configuration)
            } else if containerURL != nil || sasQuery != nil { throw AzureBlobTelemetryError.invalidConfiguration }
        } catch { throw AzureBlobTelemetryError.invalidConfiguration }
        if let containerURL {
            store = try AzureBlobEventStore(root: storeDirectory, containerURL: containerURL, app: app,
                build: build, identityProvider: identityProvider, atomicWriteFault: atomicWriteFault, maxDiskBytes: maxDiskBytes)
        } else { store = nil }
        self.privacy = privacy
        self.identityProvider = identityProvider
        self.containerURL = containerURL
        self.sasQuery = sasQuery
        self.app = app
        self.build = build
        protocolClasses = configuration.protocolClasses
        self.synchronization = synchronization
        self.heartbeatVersion = heartbeatVersion
        self.heartbeatClock = heartbeatClock
        state = Mutex(State(enabled: isEnabled && store != nil, lastError: store == nil ? .invalidConfiguration : nil))
        if store == nil { NSLog("LokiKit: Blob transport disabled; configuration is missing.") }
        if heartbeatVersion != nil {
            recordHeartbeat()
            cancelHeartbeat = heartbeatClock.scheduleDaily { [weak self] in self?.recordHeartbeat() }
        }
    }

    deinit { cancelHeartbeat?() }

    private func recordHeartbeat() {
        guard let version = heartbeatVersion else { return }
        let now = heartbeatClock.now() // Caller/time seams never execute under a state lock.
        guard now.timeIntervalSince1970.isFinite else { return }
        let effects = state.withLock { value -> (Task<Void, Never>, BlobRequestControl.Cancellation)? in
            let pending: Int
            do {
                if store?.isValid == false {
                    pending = -1 // Preserve the originating permanent failure, not a later generic refusal.
                } else {
                    try store?.validate()
                    pending = try store?.pendingBatchCount() ?? 0
                }
            } catch {
                pending = -1
                store?.invalidateAfterReadFailure()
                value.lastError = Self.publicError(error)
            }
            let transport = !value.enabled ? "disabled" :
                (store?.isValid != true || value.lastFlushFailed ? "failed" : (value.active == nil ? "enabled" : "uploading"))
            let event = TelemetryEvent(name: "telemetry.heartbeat", properties: [
                "app": app, "build": build, "version": version, "pending_batches": String(pending),
                "dropped_events": String(store?.droppedEventCount ?? 0),
                "last_successful_upload": value.lastSuccessfulUpload.map { String($0.timeIntervalSince1970) } ?? "0",
                "transport": transport
            ], timestamp: now)
            value.lastHeartbeat = event // Local observability remains available without consent.
            if store?.isValid == false, let active = value.active {
                return Self.invalidate(active, state: &value, error: value.lastError ?? .invalidStore)
            }
            guard value.enabled, value.ready, let store, store.isValid, pending >= 0 else { return nil }
            do { try privacy.validate([event]) }
            catch {
                let mapped = Self.publicError(error)
                value.lastError = mapped
                if !store.isValid, let active = value.active { return Self.invalidate(active, state: &value, error: mapped) }
                return nil
            }
            let queue = store.currentQueue()
            let before = queue.persistenceFailureCount
            queue.enqueue(event)
            value.accepted += 1
            if queue.persistenceFailureCount != before { value.lastError = .persistenceFailure }
            return nil
        }
        effects?.1.perform()
        effects?.0.cancel()
    }

    public var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            let effects = state.withLock { value -> (Task<Void, Never>, BlobRequestControl.Cancellation)? in
                // Worker validation may already have made the store permanently
                // invalid. Disable must preserve that cause even if it closes the
                // control before the worker reaches its outer error handling.
                let cause: AzureBlobTelemetryError = store?.isValid == true ? .cancelled : (value.lastError ?? .invalidStore)
                let effects = !newValue ? value.active.map { Self.invalidate($0, state: &value, error: cause) } : nil
                value.enabled = newValue && store != nil
                return effects
            }
            effects?.1.perform()
            effects?.0.cancel()
        }
    }

    public var diagnostics: AzureBlobTelemetryDiagnostics {
        state.withLock { AzureBlobTelemetryDiagnostics(droppedEventCount: store?.droppedEventCount ?? 0, acceptedEventCount: $0.accepted,
            rejectedEventCount: $0.rejected, disabledEventCount: $0.disabled,
            identityBlockedEventCount: $0.identityBlocked, identityFailureCount: $0.identityFailures,
            persistenceFailureCount: store?.persistenceFailureCount ?? 0, transportFailureCount: $0.transportFailures,
            cancellationCount: $0.cancellations, isAdmissionReady: $0.ready && store?.isValid == true,
            isFlushActive: $0.active != nil, lastError: $0.lastError,
            lastHeartbeat: $0.lastHeartbeat, lastSuccessfulUpload: $0.lastSuccessfulUpload) }
    }

    public func track(_ event: TelemetryEvent) {
        let effects = state.withLock { value -> (Task<Void, Never>, BlobRequestControl.Cancellation)? in
            guard value.enabled else { value.disabled += 1; return nil }
            guard let store else { value.disabled += 1; return nil }
            guard value.ready && store.isValid else { value.identityBlocked += 1; return nil }
            do {
                guard event.name != "telemetry.heartbeat" else { throw AzureBlobError.privacyRejected }
                try privacy.validate([event])
            }
            catch { value.rejected += 1; value.lastError = .privacyRejected; return nil }
            do { try store.validate() }
            catch {
                let mapped = Self.publicError(error)
                value.lastError = mapped
                if !store.isValid, let active = value.active {
                    return Self.invalidate(active, state: &value, error: mapped)
                }
                return nil
            }
            let queue = store.currentQueue()
            let before = queue.persistenceFailureCount
            queue.enqueue(event)
            value.accepted += 1
            if queue.persistenceFailureCount != before { value.lastError = .persistenceFailure }
            return nil
        }
        effects?.1.perform()
        effects?.0.cancel()
    }

    public func track(name: String, properties: [String: String]) {
        track(TelemetryEvent(name: name, properties: properties))
    }

    public func flush() async {
        // The caller owns cancellation before any unstructured worker can run.
        // This control also latches cancellation while generation setup is in progress.
        let control = BlobRequestControl(synchronization: synchronization)
        let registration = FlushRegistration()
        await withTaskCancellationHandler {
            let generation = state.withLock { value -> Generation? in
                guard !Task.isCancelled, value.enabled, value.active == nil, let store, store.isValid else { return nil }
                value.nextGeneration += 1
                let id = value.nextGeneration
                let entries = store.entries
                let task = Task { await self.runFlush(id: id, control: control, entries: entries) }
                let generation = Generation(id: id, control: control, task: task)
                value.active = generation
                registration.registered = true
                return generation
            }
            guard let generation else { return }
            await synchronization?.afterGenerationRegistered?() // No state/request lock held.
            await generation.task.value
        } onCancel: { self.cancel(control, registration: registration) }
    }

    private func runFlush(id: UInt64, control: BlobRequestControl,
                          entries: [(AzureBlobEventStore.Epoch, TelemetryQueue)]) async {
        guard let store, let containerURL, let sasQuery else { return }
        // Worker cannot pass the state mutex before its generation has been registered.
        guard state.withLock({ $0.active?.id == id }) else { return }
        defer {
            state.withLock { if $0.active?.id == id { $0.active = nil } }
            synchronization?.afterGenerationFinished?()
        }
        for (epoch, queue) in entries {
            do {
                if Task.isCancelled { throw AzureBlobError.cancelled }
                try state.withLock { value in
                    guard store.isValid else { throw AzureBlobTelemetryError.invalidStore }
                    do { try store.validate() }
                    catch { value.lastError = Self.publicError(error); throw error }
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = protocolClasses
                let transport = try AzureBlobTransport(containerURL: containerURL, sasQuery: sasQuery,
                    app: app, build: epoch.build, installID: epoch.installID, privacy: privacy, configuration: configuration)
                try await transport.flush(queue, control: control, deliveryObserved: {
                    let now = self.heartbeatClock.now()
                    guard now.timeIntervalSince1970.isFinite else { return }
                    self.state.withLock { $0.lastSuccessfulUpload = now; $0.lastFlushFailed = false }
                })
            } catch {
                await synchronization?.beforeWorkerErrorHandling?() // Detecting lock has already been released.
                let effects = state.withLock { value -> (Task<Void, Never>, BlobRequestControl.Cancellation)? in
                    let mapped = Self.publicError(error)
                    if mapped != .cancelled { value.lastFlushFailed = true }
                    // The detecting operation records the store failure under this
                    // mutex. Incidental worker cancellation/network errors cannot hide it.
                    if store.isValid { value.lastError = mapped }
                    if mapped != .persistenceFailure && mapped != .invalidStore && mapped != .cancelled { value.transportFailures += 1 }
                    if !store.isValid, let active = value.active {
                        return Self.invalidate(active, state: &value, error: value.lastError ?? .invalidStore)
                    }
                    return nil
                }
                effects?.1.perform()
                effects?.0.cancel()
                return
            }
        }
    }

    private static func invalidate(_ generation: Generation, state value: inout State,
                                   error: AzureBlobTelemetryError = .cancelled) -> (Task<Void, Never>, BlobRequestControl.Cancellation) {
        let effects = generation.control.cancel()
        if effects.first { value.cancellations += 1; value.lastError = error }
        return (generation.task, effects)
    }

    private func cancel(_ control: BlobRequestControl, registration: FlushRegistration) {
        // Close the start authority even while setup holds the service mutex.
        // cancel() releases its request lock before we acquire service state;
        // no request→service nested lock or callback is introduced.
        let cancellation = control.cancel()
        synchronization?.afterCallerControlCancelled?() // Outside both locks; no decision/result input.
        let task = state.withLock { value -> Task<Void, Never>? in
            if registration.registered && cancellation.first { value.cancellations += 1 }
            guard let active = value.active, active.control === control else { return nil }
            if cancellation.first && store?.isValid == true { value.lastError = .cancelled }
            return active.task
        }
        cancellation.perform()
        task?.cancel()
    }

    public func resetIdentifier() {
        guard let store else { return }
        let reserved = state.withLock { value -> Bool in
            guard !value.resetting else {
                value.identityFailures += 1; value.lastError = .resetInProgress; return false
            }
            guard store.isValid else { value.lastError = .invalidStore; return false }
            value.resetting = true
            return true
        }
        guard reserved else { return }
        let supplied: Result<UUID, any Error>
        do { supplied = .success(try identityProvider()) }
        catch { supplied = .failure(AzureBlobTelemetryError.identityUnavailable) }
        let effects = state.withLock { value -> (Task<Void, Never>, BlobRequestControl.Cancellation)? in
            defer { value.resetting = false }
            switch supplied {
            case .failure:
                value.identityFailures += 1; value.ready = false; value.lastError = .identityUnavailable
            case .success(let identity):
                do {
                    try store.append(identity: identity, build: build)
                    value.ready = true
                } catch {
                    let mapped = Self.publicError(error)
                    value.lastError = mapped
                    value.ready = mapped == .persistenceFailure && store.isValid && store.current.installID == identity
                    if mapped == .duplicateIdentity { value.identityFailures += 1 }
                    if !store.isValid, let active = value.active {
                        return Self.invalidate(active, state: &value, error: mapped)
                    }
                }
            }
            return nil
        }
        effects?.1.perform()
        effects?.0.cancel()
    }

    private static func publicError(_ error: any Error) -> AzureBlobTelemetryError {
        if let error = error as? AzureBlobTelemetryError { return error }
        switch error as? AzureBlobError {
        case .invalidConfiguration: return .invalidConfiguration
        case .encodingFailure: return .encodingFailure
        case .networkFailure: return .networkFailure
        case .invalidResponse: return .invalidResponse
        case .persistenceFailure: return .persistenceFailure
        case .invalidStoredBatch: return .invalidStore
        case .destinationChanged: return .destinationChanged
        case .privacyRejected: return .privacyRejected
        case .cancelled: return .cancelled
        case .httpFailure(let status): return .httpFailure(status)
        case nil: return .persistenceFailure
        }
    }
}

public struct AzureBlobTelemetryDiagnostics: Sendable {
    public let droppedEventCount: Int
    public let acceptedEventCount: Int
    public let rejectedEventCount: Int
    public let disabledEventCount: Int
    public let identityBlockedEventCount: Int
    public let identityFailureCount: Int
    public let persistenceFailureCount: Int
    public let transportFailureCount: Int
    public let cancellationCount: Int
    public let isAdmissionReady: Bool
    public let isFlushActive: Bool
    public let lastError: AzureBlobTelemetryError?
    public let lastHeartbeat: TelemetryEvent?
    public let lastSuccessfulUpload: Date?
}

/// Time is the only replaceable heartbeat seam. Scheduling cannot supply an event or receipt.
internal struct BlobHeartbeatClock: Sendable {
    let now: @Sendable () -> Date
    let scheduleDaily: @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)

    static let live = BlobHeartbeatClock(now: { Date() }, scheduleDaily: { tick in
        let task = Task.detached {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(86_400)) }
                catch { return }
                guard !Task.isCancelled else { return }
                tick()
            }
        }
        return { task.cancel() }
    })
}

/// Fixed, content-free outcomes. HTTP status is the only external associated detail.
public enum AzureBlobTelemetryError: Error, Equatable, Sendable {
    case invalidConfiguration, privacyRejected, persistenceFailure, invalidStore, storeInUse
    case identityUnavailable, duplicateIdentity, resetInProgress, disabled, cancelled
    case encodingFailure, networkFailure, invalidResponse, destinationChanged
    case httpFailure(Int)
}
