import Foundation
import ConsumerHarness
import LokiKit
import Synchronization
import XCTest

final class ConsumerTests: XCTestCase, @unchecked Sendable {
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
