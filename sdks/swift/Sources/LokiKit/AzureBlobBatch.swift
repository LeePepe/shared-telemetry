import CryptoKit
import Foundation

/// A durable request, not just an ID. Credentials never enter this record.
/// The checksum detects corrupt records; it is not authentication against local tampering.
struct AzureBlobBatch: Codable {
    let version: Int
    let queueID: UUID
    let containerURL: URL
    let path: [String]
    let sourceDigest: Data
    let body: Data
    var mayHaveBeenSent: Bool

    private struct Stored: Codable {
        let payload: Data
        let checksum: Data
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func load(id: UUID, queue: TelemetryQueue) throws -> Self? {
        let data: Data
        do { data = try Data(contentsOf: file(id, queue: queue)) }
        catch {
            if isAbsent(error) { return nil }
            queue.recordPersistenceFailure()
            throw AzureBlobError.persistenceFailure
        }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            guard digest(stored.payload) == stored.checksum else { throw AzureBlobError.invalidStoredBatch }
            let batch = try JSONDecoder().decode(Self.self, from: stored.payload)
            guard batch.version == 1, batch.queueID == id else { throw AzureBlobError.invalidStoredBatch }
            return batch
        } catch {
            queue.recordPersistenceFailure()
            throw AzureBlobError.invalidStoredBatch
        }
    }

    func save(queue: TelemetryQueue) throws {
        do {
            let payload = try JSONEncoder().encode(self)
            let data = try JSONEncoder().encode(Stored(payload: payload, checksum: Self.digest(payload)))
            try queue.persistBlobSidecar(id: queueID, data: data)
        } catch {
            queue.recordPersistenceFailure()
            throw AzureBlobError.persistenceFailure
        }
    }

    func remove(queue: TelemetryQueue) throws {
        do { try queue.removeBlobSidecar(id: queueID) }
        catch {
            if Self.isAbsent(error) { return }
            queue.recordPersistenceFailure()
            throw AzureBlobError.persistenceFailure
        }
    }

    private static func file(_ id: UUID, queue: TelemetryQueue) -> URL {
        queue.storeDirectory.appendingPathComponent("\(id.uuidString).azure-blob")
    }

    private static func isAbsent(_ error: Error) -> Bool {
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isAbsent(underlying) }
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(POSIXErrorCode.ENOENT.rawValue) }
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
}
