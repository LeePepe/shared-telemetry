import Foundation
import Synchronization
import XCTest
@testable import LokiKit

final class LokiLogSinkTests: XCTestCase {
    private func sink(capacity: Int = 1_000, persistenceURL: URL? = nil) -> LokiLogSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogURLProtocol.self]
        return LokiLogSink(
            endpoint: URL(string: "http://localhost:3100/loki/api/v1/push")!,
            labels: ["app": "test"], allowedMessages: ["Recording started"],
            allowedContextKeys: ["char_count"], capacity: capacity, persistenceURL: persistenceURL,
            session: URLSession(configuration: config)
        )
    }

    private func record(_ sink: LokiLogSink, message: String = "Recording started", line: Int = 1) {
        sink.record(level: .info, subsystem: "Test", message: message,
                    context: ["char_count": 12, "text": "private transcript", "token": "secret"],
                    file: "/private/project/Test.swift", function: "test()", line: line)
    }

    override func setUp() {
        super.setUp()
        LogURLProtocol.state.withLock { $0 = .init() }
    }

    func testUploadsStructuredLogsWithoutSensitiveData() async throws {
        let sink = sink()
        record(sink)
        record(sink, message: "Local Whisper raw output: private transcript")
        await sink.flush()
        let data = try XCTUnwrap(LogURLProtocol.state.withLock { $0.bodies.first })
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.contains("Recording started"))
        XCTAssertTrue(string.contains("dynamic message redacted"))
        XCTAssertTrue(string.contains("char_count"))
        for secret in ["private transcript", "secret", "/private/project", "Local Whisper raw output"] {
            XCTAssertFalse(string.contains(secret))
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try XCTUnwrap(body["streams"] as? [[String: Any]])
        let labels = try XCTUnwrap(streams.first?["stream"] as? [String: String])
        XCTAssertEqual(labels["stream"], "log")
        XCTAssertEqual(labels["level"], "info")
    }

    func testFailureRetriesAndSuccessfulFlushClearsQueue() async throws {
        let sink = sink()
        record(sink)
        LogURLProtocol.state.withLock { $0.status = 503 }
        await sink.flush()
        LogURLProtocol.state.withLock { $0.status = 204 }
        await sink.flush()
        await sink.flush()
        XCTAssertEqual(LogURLProtocol.state.withLock { $0.bodies.count }, 2)
        let bodies = LogURLProtocol.state.withLock { $0.bodies }
        let first = try normalizedBody(XCTUnwrap(bodies.first))
        let retry = try normalizedBody(XCTUnwrap(bodies.last))
        XCTAssertEqual(first, retry)
    }

    func testQueueDropsOldestAtCapacity() async throws {
        let sink = sink(capacity: 2)
        for line in 1...3 { record(sink, line: line) }
        await sink.flush()
        let data = try XCTUnwrap(LogURLProtocol.state.withLock { $0.bodies.first })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try XCTUnwrap(body["streams"] as? [[String: Any]])
        let values = try XCTUnwrap(streams.first?["values"] as? [[String]])
        let records = try values.map { try JSONDecoder.logDecoder.decode(LokiLogSink.Record.self, from: Data($0[1].utf8)) }
        XCTAssertEqual(records.map(\.line), [2, 3])
    }

    func testOfflineQueueRestoresAcrossSinkInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pending.json")
        let first = sink(persistenceURL: path)
        record(first)
        LogURLProtocol.state.withLock { $0.status = 503 }
        await first.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let second = sink(persistenceURL: path)
        LogURLProtocol.state.withLock { $0.status = 204 }
        await second.flush()
        XCTAssertEqual(LogURLProtocol.state.withLock { $0.bodies.count }, 2)
        let remaining = try JSONDecoder().decode([LokiLogSink.Record].self, from: Data(contentsOf: path))
        XCTAssertTrue(remaining.isEmpty)
    }

    func testExistingPrintLoggerCanBeConnectedAndDisconnected() async {
        let logger = PrintLogger(subsystem: "BeforeConfiguration", minimumLevel: .info)
        let sink = sink()
        PrintLogger.configureRemoteSink(sink)
        logger.debug("Recording started")
        logger.info("Recording started")
        PrintLogger.configureRemoteSink(nil)
        logger.info("Recording started")
        await sink.flush()
        XCTAssertEqual(LogURLProtocol.state.withLock { $0.bodies.count }, 1)
    }

    // JSON 对象键无序；重试应保持日志语义，不要求编码后的字节顺序相同。
    private func normalizedBody(_ data: Data) throws -> NSDictionary {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try XCTUnwrap(body["streams"] as? [[String: Any]])
        let normalized = try streams.map { stream -> [String: Any] in
            let values = try XCTUnwrap(stream["values"] as? [[String]])
            return [
                "stream": try XCTUnwrap(stream["stream"]),
                "values": try values.map { value -> [Any] in
                    [value[0], try JSONSerialization.jsonObject(with: Data(value[1].utf8))]
                }
            ]
        }
        return ["streams": normalized] as NSDictionary
    }
}

private extension JSONDecoder {
    static var logDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class LogURLProtocol: URLProtocol, @unchecked Sendable {
    struct State { var bodies: [Data] = []; var status = 204 }
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
        let status = Self.state.withLock { value in value.bodies.append(data); return value.status }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
