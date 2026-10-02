import Foundation
import Synchronization

/// A single-owner store. Synchronous enqueue closes the track-to-flush crash window.
/// Files retain the legacy UUID + JSON event-array format for rollback compatibility.
final class TelemetryQueue: Sendable {
    typealias Batch = (id: UUID, events: [TelemetryEvent])

    private struct State {
        // Keep originals (including timestamp precision) and failed writes until delivery.
        var pending: [Batch] = []
        var activeID: UUID?
        var dirty: Set<UUID> = []
        var persistenceFailures = 0
        var flushing = false
    }

    private let state = Mutex(State())
    // Bound rewrite work, not retention: full batches stay queued until acknowledged.
    private static let eventsPerBatch = 64
    let storeDirectory: URL

    init(storeDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storeDirectory = storeDirectory ?? appSupport
            .appendingPathComponent("telemetry/pending", isDirectory: true)
    }

    var persistenceFailureCount: Int { state.withLock { $0.persistenceFailures } }

    func enqueue(_ event: TelemetryEvent) {
        state.withLock { value in
            if value.activeID == nil {
                let id = UUID()
                value.activeID = id
                value.pending.append((id, []))
            }
            // The active batch is always last; enqueue does not scan the backlog.
            let index = value.pending.count - 1
            let id = value.pending[index].id
            value.pending[index].events.append(event)
            if value.pending[index].events.count == Self.eventsPerBatch {
                value.activeID = nil
            }
            value.dirty.insert(id)
            let batch = value.pending[index]
            do {
                try writeBatch(id: batch.id, events: batch.events)
                value.dirty.remove(id)
            } catch {
                value.persistenceFailures += 1
            }
        }
    }

    func beginFlush() -> Bool {
        state.withLock { value in
            guard !value.flushing else { return false }
            value.flushing = true
            return true
        }
    }

    func endFlush() { state.withLock { $0.flushing = false } }

    /// A snapshot, never a destructive take. Enqueues during transport belong to a later flush.
    func batchesForFlush() throws -> [Batch] {
        state.withLock { value in
            // Freeze file contents before transport; concurrent tracks start a new batch.
            value.activeID = nil
            for batch in value.pending where value.dirty.contains(batch.id) {
                do {
                    try writeBatch(id: batch.id, events: batch.events)
                    value.dirty.remove(batch.id)
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
            // Replay recovered history first, then live batches in enqueue order.
            // Atomic retries can refresh file dates; they must not reorder known IDs
            // or replace originals with a persisted prefix after a failed rewrite.
            let pendingIDs = Set(value.pending.map(\.id))
            return stored.filter { !pendingIDs.contains($0.id) } + value.pending
        }
    }

    func persistBatch(id: UUID, events: [TelemetryEvent]) throws {
        try state.withLock { value in
            do {
                try writeBatch(id: id, events: events)
            } catch {
                value.persistenceFailures += 1
                throw error
            }
        }
    }

    func loadPersistedBatches() throws -> [Batch] {
        try state.withLock { try readBatches(state: &$0) }
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
        }
    }

    private func file(_ id: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeBatch(id: UUID, events: [TelemetryEvent]) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: file(id), options: .atomic)
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
        var batches: [Batch] = []
        for url in files.sorted(by: { creationDate(of: $0) < creationDate(of: $1) }) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
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
