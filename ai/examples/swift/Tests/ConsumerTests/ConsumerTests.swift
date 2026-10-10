import Foundation
import ConsumerHarness
import LokiKit
import Synchronization
import XCTest
import zlib

final class ConsumerTests: XCTestCase, @unchecked Sendable {
    func testCandidateBundleWithoutConfigurationHasDisabledLocalHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlobConfigConsumer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Synthetic.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "invalid.example.synthetic.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let store = root.appendingPathComponent("store")
        let telemetry = try AzureBlobTelemetryService(bundle: XCTUnwrap(Bundle(url: bundleURL)),
            app: "fixture", build: "one", version: "1.2.3",
            privacy: AzureBlobPrivacyPolicy(apps: ["fixture"], builds: ["one"], versions: ["1.2.3"]),
            storeDirectory: store, isEnabled: true,
            identityProvider: { throw ConsumerBlobError.unexpectedIdentityProvision })
        XCTAssertFalse(telemetry.isEnabled)
        XCTAssertEqual(telemetry.diagnostics.lastError, .invalidConfiguration)
        XCTAssertEqual(telemetry.diagnostics.lastHeartbeat?.name, "telemetry.heartbeat")
        XCTAssertEqual(telemetry.diagnostics.lastHeartbeat?.properties["transport"], "disabled")
        await telemetry.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testUnreleasedBlobRejectsWholeEventsAndRestoresAdmissionIdentity() async throws {
        ConsumerBlobReceiver.requests.withLock { $0 = [] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlobConsumer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsumerBlobReceiver.self]
        let policy = AzureBlobPrivacyPolicy(events: ["synthetic.completed": ["count": .finiteNumber]],
            apps: ["fixture"], builds: ["one"])
        let identities = Mutex([UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!])
        var first: AzureBlobTelemetryService? = try AzureBlobTelemetryService(
            containerURL: URL(string: "https://blob.example.invalid/container")!, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "fixture", build: "one", privacy: policy, storeDirectory: root, isEnabled: true,
            identityProvider: { identities.withLock { $0.removeFirst() } }, configuration: configuration)
        first?.track(name: "synthetic.completed", properties: ["count": "1", "text": "synthetic-private-CANARY"])
        XCTAssertEqual(first?.diagnostics.rejectedEventCount, 1)
        XCTAssertEqual(first?.diagnostics.acceptedEventCount, 0)
        first?.track(name: "synthetic.completed", properties: ["count": "1"])
        first?.resetIdentifier()
        first?.track(name: "synthetic.completed", properties: ["count": "2"])
        first = nil
        let restored = try AzureBlobTelemetryService(
            containerURL: URL(string: "https://blob.example.invalid/container")!, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "fixture", build: "one", privacy: policy, storeDirectory: root, isEnabled: false,
            identityProvider: { throw ConsumerBlobError.unexpectedIdentityProvision }, configuration: configuration)
        restored.track(name: "synthetic.completed", properties: ["count": "3"])
        await restored.flush()
        XCTAssertEqual(restored.diagnostics.disabledEventCount, 1)
        XCTAssertTrue(ConsumerBlobReceiver.requests.withLock { $0.isEmpty })
        restored.isEnabled = true
        await restored.flush()
        let requests = ConsumerBlobReceiver.requests.withLock { $0 }
        XCTAssertEqual(requests.map { $0.0.pathComponents[5] }, [
            "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
        ])
        let bodies = try requests.map { try consumerGunzip($0.1) }
        XCTAssertFalse(bodies.contains { String(decoding: $0, as: UTF8.self).contains("CANARY") })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try bodies.flatMap { try $0.split(separator: 0x0a).map { try decoder.decode(TelemetryEvent.self, from: Data($0)) } }
        XCTAssertEqual(events.map(\.properties), [["count": "1"], ["count": "2"]])
        await restored.flush()
        XCTAssertEqual(ConsumerBlobReceiver.requests.withLock { $0.count }, 2)
    }

    func testUnreleasedBlobFailedResetPauseAndExplicitRecreation() async throws {
        ConsumerBlobReceiver.requests.withLock { $0 = [] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlobResetConsumer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsumerBlobReceiver.self]
        let policy = AzureBlobPrivacyPolicy(events: ["synthetic.completed": ["count": .finiteNumber]],
            apps: ["fixture"], builds: ["one"])
        let calls = Mutex(0)
        var first: AzureBlobTelemetryService? = try AzureBlobTelemetryService(
            containerURL: URL(string: "https://blob.example.invalid/container")!, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "fixture", build: "one", privacy: policy, storeDirectory: root, isEnabled: true,
            identityProvider: {
                guard calls.withLock({ $0 += 1; return $0 }) == 1 else { throw ConsumerBlobError.unexpectedIdentityProvision }
                return UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            }, configuration: configuration)
        first?.track(name: "synthetic.completed", properties: ["count": "1"])
        first?.resetIdentifier()
        first?.track(name: "synthetic.completed", properties: ["count": "99"])
        XCTAssertEqual(first?.diagnostics.lastError, .identityUnavailable)
        XCTAssertEqual(first?.diagnostics.identityBlockedEventCount, 1)
        await first?.flush()
        XCTAssertEqual(first?.diagnostics.isAdmissionReady, false)
        XCTAssertEqual(ConsumerBlobReceiver.requests.withLock { $0.count }, 1)
        first = nil
        let restored = try AzureBlobTelemetryService(
            containerURL: URL(string: "https://blob.example.invalid/container")!, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "fixture", build: "one", privacy: policy, storeDirectory: root, isEnabled: true,
            identityProvider: {
                calls.withLock { $0 += 1 }
                throw ConsumerBlobError.unexpectedIdentityProvision
            }, configuration: configuration)
        XCTAssertEqual(calls.withLock { $0 }, 2, "Valid reconstruction must not call the provider")
        XCTAssertTrue(restored.diagnostics.isAdmissionReady)
        restored.track(name: "synthetic.completed", properties: ["count": "2"])
        await restored.flush()
        XCTAssertEqual(restored.diagnostics.acceptedEventCount, 1)
        let requests = ConsumerBlobReceiver.requests.withLock { $0 }
        XCTAssertEqual(requests.map { $0.0.pathComponents[5] }, Array(repeating: "11111111-1111-4111-8111-111111111111", count: 2))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try requests.flatMap { request in
            try consumerGunzip(request.1).split(separator: 0x0a).map { try decoder.decode(TelemetryEvent.self, from: Data($0)) }
        }
        XCTAssertEqual(events.map(\.properties), [["count": "1"], ["count": "2"]])
    }

    func testEventAndNoopPublicAPI() async {
        let event = ConsumerHarness.syntheticEvent()
        XCTAssertEqual(event.name, "synthetic.completed")
        let service = NoopTelemetryService()
        XCTAssertFalse(service.isEnabled)
        service.track(event)
        await service.flush()
    }

    func testPublicLogSinkFiltersBoundsAndRetries() async throws {
        Receiver.state.withLock { $0 = .init() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Receiver.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let sink = LokiLogSink(endpoint: URL(string: "https://synthetic.invalid/loki/api/v1/push")!,
            labels: ["app": "synthetic"], allowedMessages: ["synthetic.completed"],
            allowedContextKeys: ["duration_ms"], capacity: 2, token: "synthetic-only", session: session)
        for index in 1...3 {
            sink.record(level: .info, subsystem: "synthetic",
                message: index == 3 ? "synthetic-disallowed-content" : "synthetic.completed",
                context: ["duration_ms": 1, "not_allowed": "synthetic-private-field"],
                file: "Fixture.swift", function: "synthetic", line: index)
        }
        await sink.flush() // 503: retain bounded filtered records
        Receiver.state.withLock { $0.status = 204 }
        await sink.flush()
        await sink.flush() // success drained the queue
        let bodies = Receiver.state.withLock { $0.bodies }
        XCTAssertEqual(bodies.count, 2)
        for data in bodies {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("synthetic-disallowed-content"))
            XCTAssertFalse(text.contains("synthetic-private-field"))
            XCTAssertTrue(text.contains("dynamic message redacted"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let streams = try XCTUnwrap(body["streams"] as? [[String: Any]])
            let values = try XCTUnwrap(streams.first?["values"] as? [[String]])
            XCTAssertEqual(values.count, 2)
            let records = try values.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0[1].utf8)) as? [String: Any]) }
            XCTAssertEqual(records.compactMap { $0["line"] as? Int }, [2, 3])
        }
        XCTAssertTrue(Receiver.state.withLock { $0.authOK })
    }
}

private enum ConsumerBlobError: Error { case unexpectedIdentityProvision, invalidGzip }

private final class ConsumerBlobReceiver: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[(URL, Data)]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let url = request.url, url.host == "blob.example.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.requests.withLock { $0.append((url, body)) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 201,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func consumerGunzip(_ data: Data) throws -> Data {
    var stream = z_stream()
    guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw ConsumerBlobError.invalidGzip
    }
    defer { inflateEnd(&stream) }
    return try data.withUnsafeBytes { input in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        var bytes = Data()
        var result: Int32 = Z_OK
        while result == Z_OK {
            var buffer = [UInt8](repeating: 0, count: 4096)
            result = buffer.withUnsafeMutableBytes { output in
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            bytes.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
        }
        guard result == Z_STREAM_END, stream.avail_in == 0 else { throw ConsumerBlobError.invalidGzip }
        return bytes
    }
}

private final class Receiver: URLProtocol, @unchecked Sendable {
    struct State { var bodies: [Data] = []; var status = 503; var authOK = true }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let status = Self.state.withLock { value in
            value.bodies.append(data)
            value.authOK = value.authOK && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only"
            return value.status
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
