import Foundation
import Synchronization

/// A single-owner store. Synchronous enqueue closes the track-to-flush crash window.
/// Files retain the legacy UUID + JSON event-array format for rollback compatibility.
final class TelemetryQueue: Sendable {
    typealias Batch = (id: UUID, events: [TelemetryEvent])

    private struct CapacityLedger: Codable {
        var droppedEvents = 0
        var removing: Set<UUID> = []
    }

    private struct Footprint {
        var source = 0
        var sidecar = 0
        var created = Date.distantPast
    }

    private enum CapacityError: Error { case flushInProgress, evicted }

    private struct State {
        // Keep originals (including timestamp precision) until delivery or quota eviction.
        var pending: [Batch] = []
        var activeID: UUID?
        var dirty: Set<UUID> = []
        var persistenceFailures = 0
        var capacity: CapacityLedger?
        var unrecordedDrops = 0
        var inventory: [UUID: Footprint]?
        var flushing = false
        var snapshotTaken = false
        var retryWritesAfterFlush = true
        var capacityDeferred = false
        var deferredSidecar: (id: UUID, bytes: Int)?
    }

    private let state = Mutex(State())
    // Bound rewrite work separately from the byte-based retention policy.
    private static let eventsPerBatch = 64
    let storeDirectory: URL
    let maxDiskBytes: Int

    init(storeDirectory: URL? = nil, maxDiskBytes: Int = 50 * 1024 * 1024) {
        precondition(maxDiskBytes > 0, "maxDiskBytes must be positive")
        self.maxDiskBytes = maxDiskBytes
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storeDirectory = storeDirectory ?? appSupport
            .appendingPathComponent("telemetry/pending", isDirectory: true)
        // A failed read is retried by the next storage operation, not treated as
        // permission to overwrite an unreadable loss record with a zero count.
        let capacity = try? readCapacity()
        state.withLock { $0.capacity = capacity }
    }

    var persistenceFailureCount: Int { state.withLock { $0.persistenceFailures } }
    var droppedEventCount: Int { state.withLock { Self.addDrops($0.capacity?.droppedEvents ?? 0, $0.unrecordedDrops) } }

    // Transport-owned durable receipt files participate in the same operation counter.
    func recordPersistenceFailure() { state.withLock { $0.persistenceFailures += 1 } }

    func enqueue(_ event: TelemetryEvent) {
        state.withLock { value in
            if let data = try? encode([event]), data.count > maxDiskBytes {
                value.unrecordedDrops = Self.addDrops(value.unrecordedDrops, 1)
                do { try synchronizeCapacity(state: &value) }
                catch { value.persistenceFailures += 1 }
                return
            }
            if value.activeID != nil, let active = value.pending.last,
               let data = try? encode(active.events + [event]), data.count > maxDiskBytes {
                value.activeID = nil
            }
            if value.activeID == nil {
                let id = UUID()
                value.activeID = id
                value.pending.append((id, []))
            }
            // The active batch is always last; only quota pressure scans the cached inventory.
            let index = value.pending.count - 1
            let id = value.pending[index].id
            value.pending[index].events.append(event)
            if value.pending[index].events.count == Self.eventsPerBatch {
                value.activeID = nil
            }
            value.dirty.insert(id)
            let batch = value.pending[index]
            do {
                try writeBatch(id: batch.id, events: batch.events, state: &value)
                value.dirty.remove(id)
            } catch is CapacityError {
                // Deferred writes stay in memory; quota-evicted batches are already accounted for.
            } catch {
                value.persistenceFailures += 1
            }
        }
    }

    func beginFlush() -> Bool {
        state.withLock { value in
            guard !value.flushing else { return false }
            value.flushing = true
            value.snapshotTaken = false
            value.retryWritesAfterFlush = true
            return true
        }
    }

    func endFlush() {
        state.withLock { value in
            value.flushing = false
            value.snapshotTaken = false
            guard value.capacityDeferred else { return }
            value.capacityDeferred = false
            if let reservation = value.deferredSidecar {
                value.deferredSidecar = nil
                do {
                    if (value.inventory?[reservation.id]?.source ?? 0) > 0 {
                        try makeRoom(id: reservation.id, bytes: reservation.bytes, sidecar: true, state: &value)
                    }
                } catch is CapacityError {
                    // The oldest batch (possibly this reservation) was evicted.
                } catch { value.persistenceFailures += 1 }
            }
            // A Blob flush may stop before validating later dirty batches. Keep
            // its no-rewrite snapshot policy through cleanup, including enqueues
            // after the snapshot; eviction itself does not persist payloads.
            guard value.retryWritesAfterFlush else { return }
            for batch in value.pending where value.dirty.contains(batch.id) {
                do {
                    try writeBatch(id: batch.id, events: batch.events, state: &value)
                    value.dirty.remove(batch.id)
                } catch is CapacityError {
                    // A retry may be the oldest batch selected for eviction.
                } catch { value.persistenceFailures += 1 }
            }
        }
    }

    /// Non-destructive after quota reconciliation. Concurrent enqueues belong to a later flush.
    func batchesForFlush(retryingWrites: Bool = true) throws -> [Batch] {
        state.withLock { value in
            defer { if value.flushing { value.snapshotTaken = true } }
            if value.flushing && !retryingWrites { value.retryWritesAfterFlush = false }
            // Freeze file contents before transport; concurrent tracks start a new batch.
            value.activeID = nil
            // Blob disables payload rewrites until privacy validation. The explicit
            // capacity policy may still evict backlog before the first snapshot.
            if retryingWrites && value.unrecordedDrops > 0 {
                do { try synchronizeCapacity(state: &value) }
                catch { value.persistenceFailures += 1 }
            }
            for batch in value.pending where retryingWrites && value.dirty.contains(batch.id) {
                do {
                    try writeBatch(id: batch.id, events: batch.events, state: &value)
                    value.dirty.remove(batch.id)
                } catch is CapacityError {
                    // The existing memory fallback remains available to Loki.
                } catch {
                    value.persistenceFailures += 1
                }
            }
            let stored: [Batch]
            do {
                stored = try readBatches(state: &value)
            } catch {
                // The read already counted its failure. Storage unavailability must not
                // prevent transport from delivering the retained memory originals.
                return value.pending
            }
            var evicted: Set<UUID> = []
            do {
                try loadInventory(state: &value)
                if !value.snapshotTaken {
                    try finishEvictions(state: &value)
                    while diskBytes(value) > maxDiskBytes, let oldest = evictionOrder(value).first {
                        // Even if physical deletion fails, the durable tombstone
                        // excludes this ID from the just-read snapshot below.
                        evicted.insert(oldest)
                        try evict(oldest, state: &value)
                    }
                }
            } catch {
                value.persistenceFailures += 1
                // A failure before the tombstone commit must retain the source.
                evicted = evicted.filter { value.capacity?.removing.contains($0) == true || value.inventory?[$0] == nil }
            }
            // Replay recovered history first, then live batches in enqueue order.
            // Atomic retries can refresh file dates; they must not reorder known IDs
            // or replace originals with a persisted prefix after a failed rewrite.
            let pendingIDs = Set(value.pending.map(\.id))
            return stored.filter { !pendingIDs.contains($0.id) && !evicted.contains($0.id) } + value.pending
        }
    }

    func persistBatch(id: UUID, events: [TelemetryEvent]) throws {
        try state.withLock { value in
            do {
                try writeBatch(id: id, events: events, state: &value)
            } catch let error as CapacityError {
                throw error
            } catch {
                value.persistenceFailures += 1
                throw error
            }
        }
    }

    func loadPersistedBatches() throws -> [Batch] {
        try state.withLock { try readBatches(state: &$0) }
    }

    // Blob's durable request participates in the same quota and lock as source
    // writes. The caller retains its existing error mapping/counter ownership.
    func persistBlobSidecar(id: UUID, data: Data) throws {
        try state.withLock { value in
            try loadInventory(state: &value)
            guard (value.inventory?[id]?.source ?? 0) > 0 else { throw CapacityError.evicted }
            try makeRoom(id: id, bytes: data.count, sidecar: true, state: &value)
            try data.write(to: storeDirectory.appendingPathComponent("\(id).azure-blob"), options: .atomic)
            value.inventory?[id]?.sidecar = data.count
        }
    }

    func removeBlobSidecar(id: UUID) throws {
        try state.withLock { value in
            do { try FileManager.default.removeItem(at: storeDirectory.appendingPathComponent("\(id).azure-blob")) }
            catch { if !isNotFound(error) { throw error } }
            value.inventory?[id]?.sidecar = 0
            if value.inventory?[id]?.source == 0 { value.inventory?.removeValue(forKey: id) }
        }
    }

    /// Only called after confirmed transport success. Failed removal remains retryable.
    func removeBatch(id: UUID) throws {
        try state.withLock { value in
            do {
                try FileManager.default.removeItem(at: file(id))
            } catch {
                if !isNotFound(error) {
                    value.persistenceFailures += 1
                    throw error
                }
            }
            value.pending.removeAll { $0.id == id }
            value.dirty.remove(id)
            if value.activeID == id { value.activeID = nil }
            value.inventory?[id]?.source = 0
            if value.inventory?[id]?.sidecar == 0 { value.inventory?.removeValue(forKey: id) }
        }
    }

    private func file(_ id: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeBatch(id: UUID, events: [TelemetryEvent], state value: inout State) throws {
        let data = try encode(events)
        guard data.count <= maxDiskBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try makeRoom(id: id, bytes: data.count, sidecar: false, state: &value)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try data.write(to: file(id), options: .atomic)
        var footprint = value.inventory?[id] ?? Footprint(created: Date())
        footprint.source = data.count
        value.inventory?[id] = footprint
    }

    private func makeRoom(id: UUID, bytes: Int, sidecar: Bool, state value: inout State) throws {
        try synchronizeCapacity(state: &value)
        try loadInventory(state: &value)
        try finishEvictions(state: &value)
        let previous = sidecar ? (value.inventory?[id]?.sidecar ?? 0) : (value.inventory?[id]?.source ?? 0)
        let ownFootprint = (value.inventory?[id]?.source ?? 0) + (sidecar ? bytes : 0)
        if value.flushing && value.snapshotTaken {
            let needsEviction = diskBytes(value) - previous > maxDiskBytes - bytes
            if needsEviction || ownFootprint > maxDiskBytes {
                value.capacityDeferred = true
                if sidecar { value.deferredSidecar = (id, bytes) }
                throw CapacityError.flushInProgress
            }
        }
        if ownFootprint > maxDiskBytes {
            try evict(id, state: &value)
            throw CapacityError.evicted
        }
        while diskBytes(value) - previous > maxDiskBytes - bytes {
            guard let oldest = evictionOrder(value).first else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try evict(oldest, state: &value)
            if oldest == id { throw CapacityError.evicted }
        }
    }

    private func encode(_ events: [TelemetryEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(events)
    }

    private var capacityFile: URL { storeDirectory.appendingPathComponent(".queue-capacity") }

    private func readCapacity() throws -> CapacityLedger {
        do {
            let capacity = try JSONDecoder().decode(CapacityLedger.self, from: Data(contentsOf: capacityFile))
            guard capacity.droppedEvents >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            return capacity
        }
        catch {
            if isNotFound(error) { return CapacityLedger() }
            throw error
        }
    }

    private func saveCapacity(_ capacity: CapacityLedger) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(capacity).write(to: capacityFile, options: .atomic)
    }

    private func synchronizeCapacity(state value: inout State) throws {
        if value.capacity == nil { value.capacity = try readCapacity() }
        guard value.unrecordedDrops > 0 else { return }
        var capacity = value.capacity!
        capacity.droppedEvents = Self.addDrops(capacity.droppedEvents, value.unrecordedDrops)
        try saveCapacity(capacity)
        value.capacity = capacity
        value.unrecordedDrops = 0
    }

    private func loadInventory(state value: inout State) throws {
        if value.capacity == nil { value.capacity = try readCapacity() }
        guard value.inventory == nil else { return }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: storeDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: .skipsHiddenFiles)
        } catch {
            if !isNotFound(error) { throw error }
            urls = []
        }
        var inventory: [UUID: Footprint] = [:]
        for url in urls where ["json", "azure-blob"].contains(url.pathExtension) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let bytes = attributes.fileSize, bytes >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var footprint = inventory[id] ?? Footprint()
            if url.pathExtension == "json" {
                footprint.source = bytes
                footprint.created = attributes.creationDate ?? .distantPast
            } else { footprint.sidecar = bytes }
            inventory[id] = footprint
        }
        value.inventory = inventory
    }

    private func diskBytes(_ value: State) -> Int {
        (value.inventory ?? [:]).values.reduce(0) { $0 + $1.source + $1.sidecar }
    }

    private func evictionOrder(_ value: State) -> [UUID] {
        let live = Set(value.pending.map(\.id))
        let recovered = (value.inventory ?? [:]).filter { !live.contains($0.key) && $0.value.source + $0.value.sidecar > 0 }
            .sorted {
                if $0.value.created == $1.value.created { return $0.key.uuidString < $1.key.uuidString }
                return $0.value.created < $1.value.created
            }.map(\.key)
        return recovered + value.pending.map(\.id)
    }

    private func evict(_ id: UUID, state value: inout State) throws {
        if value.capacity?.removing.contains(id) == true {
            try finishEvictions(state: &value)
            return
        }
        let count: Int
        if let batch = value.pending.first(where: { $0.id == id }) { count = batch.events.count }
        else if (value.inventory?[id]?.source ?? 0) > 0 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            count = try decoder.decode([TelemetryEvent].self, from: Data(contentsOf: file(id))).count
        } else { count = 0 }
        var capacity = value.capacity!
        capacity.droppedEvents = Self.addDrops(capacity.droppedEvents, count)
        capacity.removing.insert(id)
        // Commit the logical loss before touching either file. Restart filters
        // tombstones and retries cleanup without replaying or recounting them.
        try saveCapacity(capacity)
        value.capacity = capacity
        value.pending.removeAll { $0.id == id }
        value.dirty.remove(id)
        if value.activeID == id { value.activeID = nil }
        try finishEvictions(state: &value)
    }

    private func finishEvictions(state value: inout State) throws {
        guard var capacity = value.capacity, !capacity.removing.isEmpty else { return }
        for id in capacity.removing {
            // Sidecar first: a failed source removal leaves a journaled source,
            // not a credential-free but unowned Blob sidecar. Never rewrite it.
            for suffix in ["azure-blob", "json"] {
                let url = storeDirectory.appendingPathComponent("\(id).\(suffix)")
                do {
                    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try FileManager.default.removeItem(at: url)
                }
                catch { if !isNotFound(error) { throw error } }
                if suffix == "json" { value.inventory?[id]?.source = 0 }
                else { value.inventory?[id]?.sidecar = 0 }
            }
            value.inventory?.removeValue(forKey: id)
        }
        capacity.removing.removeAll()
        try saveCapacity(capacity)
        value.capacity = capacity
    }

    private func readBatches(state value: inout State) throws -> [Batch] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: storeDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "json" }
        } catch {
            if isNotFound(error) { return [] }
            value.persistenceFailures += 1
            throw error
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            if value.capacity == nil { value.capacity = try readCapacity() }
        } catch {
            value.persistenceFailures += 1
            throw error
        }
        var batches: [Batch] = []
        for url in files.sorted(by: { creationDate(of: $0) < creationDate(of: $1) }) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            guard value.capacity?.removing.contains(id) != true else { continue }
            do {
                batches.append((id, try decoder.decode([TelemetryEvent].self, from: Data(contentsOf: url))))
            } catch {
                // Preserve unreadable files; count each failed read attempt without leaking payloads.
                value.persistenceFailures += 1
            }
        }
        return batches
    }

    private func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    private static func addDrops(_ count: Int, _ increment: Int) -> Int {
        let result = count.addingReportingOverflow(increment)
        return result.overflow ? Int.max : result.partialValue
    }

    private func isNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        // Prefer the underlying errno: Cocoa can also wrap ENOTDIR as "no such file".
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isNotFound(underlying)
        }
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(POSIXErrorCode.ENOENT.rawValue)
        }
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
}
