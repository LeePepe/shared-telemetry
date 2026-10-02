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
            let id = value.activeID ?? UUID()
            value.activeID = id
            let index: Int
            if let existing = value.pending.firstIndex(where: { $0.id == id }) {
                index = existing
            } else {
                index = value.pending.count
                value.pending.append((id, []))
            }
            value.pending[index].events.append(event)
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
        try state.withLock { value in
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
            let stored = try readBatches(state: &value)
            let originals = Dictionary(uniqueKeysWithValues: value.pending.map { ($0.id, $0.events) })
            let storedIDs = Set(stored.map(\.id))
            return stored.map { ($0.id, originals[$0.id] ?? $0.events) }
                + value.pending.filter { !storedIDs.contains($0.id) }
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
                let url = file(id)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                value.pending.removeAll { $0.id == id }
                value.dirty.remove(id)
                if value.activeID == id { value.activeID = nil }
            } catch {
                value.persistenceFailures += 1
                throw error
            }
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
        guard FileManager.default.fileExists(atPath: storeDirectory.path) else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: storeDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "json" }
        } catch {
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
}
