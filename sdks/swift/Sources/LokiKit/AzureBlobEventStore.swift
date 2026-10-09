import CryptoKit
import Darwin
import Foundation

/// Serialized by the public adapter's state mutex. Epochs bind identity before enqueue.
final class AzureBlobEventStore: @unchecked Sendable {
    // A finite, instance-local syscall outcome seam, never a supplied callback.
    enum AtomicWriteFault: Sendable, Equatable { case reportFailureAfterReplacement, unavailableReconciliationRead }
    struct Epoch: Codable, Equatable, Sendable {
        let id: UUID
        let installID: UUID
        let build: String
    }
    private struct Catalog: Codable, Equatable {
        let version: Int
        let containerURL: String
        let app: String
        var epochs: [Epoch]
        var currentEpoch: UUID
    }
    private struct Stored: Codable { let payload: Data; let checksum: Data }

    let root: URL
    private let lease: Lease
    private var catalog: Catalog
    private var queues: [UUID: TelemetryQueue] = [:]
    private let capacityGroup = TelemetryQueue.CapacityGroup()
    private let maxDiskBytes: Int
    private var nextAtomicWriteFault: AtomicWriteFault?
    private(set) var persistenceFailures = 0
    private(set) var isValid = true

    var current: Epoch { catalog.epochs.first { $0.id == catalog.currentEpoch }! }
    var entries: [(Epoch, TelemetryQueue)] { catalog.epochs.map { ($0, queues[$0.id]!) } }
    var persistenceFailureCount: Int { persistenceFailures + queues.values.reduce(0) { $0 + $1.persistenceFailureCount } }
    var droppedEventCount: Int {
        queues.values.reduce(0) {
            let sum = $0.addingReportingOverflow($1.droppedEventCount)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
    func pendingBatchCount() throws -> Int { try queues.values.reduce(0) { try $0 + $1.pendingBatchCount() } }
    // The queue already counted this actual read failure; do not double-count it.
    func invalidateAfterReadFailure() { isValid = false }

    init(root: URL, containerURL: URL, app: String, build: String,
         identityProvider: @Sendable () throws -> UUID, atomicWriteFault: AtomicWriteFault? = nil,
         maxDiskBytes: Int = 50 * 1024 * 1024) throws {
        self.maxDiskBytes = maxDiskBytes
        guard root.isFileURL, [nil, "", "localhost"].contains(root.host), root.port == nil,
              root.user == nil, root.password == nil, root.query == nil, root.fragment == nil else {
            throw AzureBlobTelemetryError.invalidConfiguration
        }
        self.root = root.standardizedFileURL
        nextAtomicWriteFault = atomicWriteFault
        let type = try Self.type(self.root)
        guard type == nil || type == .typeDirectory else { throw AzureBlobTelemetryError.invalidStore }
        if type != nil {
            let names = try Self.names(self.root)
            guard names.contains("catalog.json") || names.isSubset(of: [".owner-lock"]) else {
                throw AzureBlobTelemetryError.invalidStore
            }
            if names.contains("catalog.json") {
                // Never create replacement ownership metadata in a nonempty unknown store.
                guard try Self.type(self.root.appendingPathComponent("catalog.json")) == .typeRegular,
                      try Self.type(self.root.appendingPathComponent(".owner-lock")) == .typeRegular else {
                    throw AzureBlobTelemetryError.invalidStore
                }
            }
        }
        lease = try Lease(root: self.root)
        let catalogURL = self.root.appendingPathComponent("catalog.json")
        if try Self.type(catalogURL) != nil {
            catalog = try Self.read(self.root)
            guard catalog.containerURL == containerURL.absoluteString, catalog.app == app else {
                throw AzureBlobTelemetryError.destinationChanged
            }
        } else {
            guard try Self.names(self.root).isSubset(of: [".owner-lock"]) else { throw AzureBlobTelemetryError.invalidStore }
            let identity: UUID
            do { identity = try identityProvider() }
            catch { throw AzureBlobTelemetryError.identityUnavailable }
            try lease.validate()
            let epoch = Epoch(id: UUID(), installID: identity, build: build)
            catalog = Catalog(version: 1, containerURL: containerURL.absoluteString, app: app,
                epochs: [epoch], currentEpoch: epoch.id)
            try Self.write(catalog, root: self.root)
        }
        try Self.validateEntries(root: self.root, catalog: catalog)
        for epoch in catalog.epochs { queues[epoch.id] = TelemetryQueue(storeDirectory: directory(epoch), maxDiskBytes: maxDiskBytes, strictReadErrors: true, capacityGroup: capacityGroup) }
        if current.build != build { try append(identity: current.installID, build: build, requireNewIdentity: false) }
    }

    func currentQueue() -> TelemetryQueue { queues[catalog.currentEpoch]! }

    func validate() throws {
        guard isValid else { throw AzureBlobTelemetryError.invalidStore }
        do {
            try lease.validate()
            guard try Self.read(root) == catalog else { throw AzureBlobTelemetryError.invalidStore }
            try Self.validateEntries(root: root, catalog: catalog)
        } catch {
            persistenceFailures += 1
            isValid = false
            throw error as? AzureBlobTelemetryError ?? .persistenceFailure
        }
    }

    func append(identity: UUID, build: String, requireNewIdentity: Bool = true) throws {
        try validate()
        if requireNewIdentity && catalog.epochs.contains(where: { $0.installID == identity }) {
            throw AzureBlobTelemetryError.duplicateIdentity
        }
        let prior = catalog
        let epoch = Epoch(id: UUID(), installID: identity, build: build)
        var proposed = prior
        proposed.epochs.append(epoch)
        proposed.currentEpoch = epoch.id
        let fault = nextAtomicWriteFault
        nextAtomicWriteFault = nil
        do { try Self.write(proposed, root: root, reportFailureAfterReplacement: fault != nil) }
        catch {
            persistenceFailures += 1
            // An atomic-write error is ambiguous. Adopt only an exact provable state.
            let observed: Catalog
            do { observed = try Self.read(root, unavailable: fault == .unavailableReconciliationRead) }
            catch {
                persistenceFailures += 1
                isValid = false
                throw AzureBlobTelemetryError.invalidStore
            }
            if observed == proposed {
                catalog = proposed
                queues[epoch.id] = TelemetryQueue(storeDirectory: directory(epoch), maxDiskBytes: maxDiskBytes, strictReadErrors: true, capacityGroup: capacityGroup)
            } else if observed != prior {
                persistenceFailures += 1
                isValid = false
                throw AzureBlobTelemetryError.invalidStore
            }
            throw AzureBlobTelemetryError.persistenceFailure
        }
        catalog = proposed
        queues[epoch.id] = TelemetryQueue(storeDirectory: directory(epoch), maxDiskBytes: maxDiskBytes, strictReadErrors: true, capacityGroup: capacityGroup)
    }

    private func directory(_ epoch: Epoch) -> URL { root.appendingPathComponent(epoch.id.uuidString, isDirectory: true) }

    private static func read(_ root: URL, unavailable: Bool = false) throws -> Catalog {
        if unavailable { throw POSIXError(.EIO) } // One injected read syscall failure, not a catalog decision.
        let url = root.appendingPathComponent("catalog.json")
        guard try type(url) == .typeRegular else { throw AzureBlobTelemetryError.invalidStore }
        do {
            let bytes = try Data(contentsOf: url)
            let stored = try JSONDecoder().decode(Stored.self, from: bytes)
            guard Data(SHA256.hash(data: stored.payload)) == stored.checksum else { throw AzureBlobTelemetryError.invalidStore }
            let value = try JSONDecoder().decode(Catalog.self, from: stored.payload)
            guard value.version == 1, !value.epochs.isEmpty,
                  Set(value.epochs.map(\.id)).count == value.epochs.count,
                  value.epochs.contains(where: { $0.id == value.currentEpoch }),
                  value.epochs.allSatisfy({ validSegment($0.build) }) else { throw AzureBlobTelemetryError.invalidStore }
            // The private v1 writer is canonical. Do not ignore unknown fields or
            // equate different bytes during exact prior/proposed reconciliation.
            guard try encoded(value) == bytes else { throw AzureBlobTelemetryError.invalidStore }
            return value
        } catch { throw AzureBlobTelemetryError.invalidStore }
    }

    private static func write(_ catalog: Catalog, root: URL, reportFailureAfterReplacement: Bool = false) throws {
        let url = root.appendingPathComponent("catalog.json")
        let existing = try type(url)
        guard existing == nil || existing == .typeRegular else { throw AzureBlobTelemetryError.invalidStore }
        do {
            try encoded(catalog).write(to: url, options: .atomic)
            // Synthetic syscall outcome only: bytes were really replaced. Public
            // construction never enables this one-shot internal fault input.
            if reportFailureAfterReplacement { throw POSIXError(.EIO) }
        } catch { throw AzureBlobTelemetryError.persistenceFailure }
    }

    private static func encoded(_ catalog: Catalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(catalog)
        return try encoder.encode(Stored(payload: payload, checksum: Data(SHA256.hash(data: payload))))
    }

    private static func validateEntries(root: URL, catalog: Catalog) throws {
        guard try type(root) == .typeDirectory else { throw AzureBlobTelemetryError.invalidStore }
        let epochs = Set(catalog.epochs.map { $0.id.uuidString })
        for name in try names(root) {
            let kind = try type(root.appendingPathComponent(name))
            if name == "catalog.json" || name == ".owner-lock" {
                guard kind == .typeRegular else { throw AzureBlobTelemetryError.invalidStore }
            } else {
                guard epochs.contains(name), kind == .typeDirectory else { throw AzureBlobTelemetryError.invalidStore }
            }
        }
        // A listed epoch need not be materialized until its first successful write.
    }

    private static func names(_ directory: URL) throws -> Set<String> {
        do { return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }
        catch { throw AzureBlobTelemetryError.persistenceFailure }
    }

    private static func type(_ url: URL) throws -> FileAttributeType? {
        var information = stat()
        if lstat(url.path, &information) != 0 {
            if errno == ENOENT { return nil }
            throw AzureBlobTelemetryError.persistenceFailure
        }
        switch information.st_mode & S_IFMT {
        case S_IFDIR: return .typeDirectory
        case S_IFREG: return .typeRegular
        default: return .typeUnknown // includes symlinks; never follow an entry to inspect its content
        }
    }

    private static func validSegment(_ value: String) -> Bool {
        !value.isEmpty && !value.hasSuffix(".") && !value.contains("/") && !value.contains("\\")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private final class Lease {
        private var descriptor: Int32
        private let path: String
        init(root: URL) throws {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            catch { throw AzureBlobTelemetryError.persistenceFailure }
            path = root.appendingPathComponent(".owner-lock").path
            descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw AzureBlobTelemetryError.invalidStore }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                descriptor = -1
                throw AzureBlobTelemetryError.storeInUse
            }
            do { try validate() }
            catch { close(descriptor); descriptor = -1; throw error }
        }
        func validate() throws {
            var opened = stat()
            var named = stat()
            guard fstat(descriptor, &opened) == 0, lstat(path, &named) == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
                  named.st_mode & S_IFMT == S_IFREG else { throw AzureBlobTelemetryError.invalidStore }
        }
        deinit { if descriptor >= 0 { close(descriptor) } }
    }
}
