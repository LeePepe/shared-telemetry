import Foundation
import XCTest
@testable import LokiKit

final class LokiLogLiveTests: XCTestCase {
    func testPrintLoggerReachesLocalLoki() async throws {
        guard ProcessInfo.processInfo.environment["LOKIKIT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Run with LOKIKIT_LIVE_TEST=1 against the local Compose stack")
        }
        let marker = "log-integration-" + UUID().uuidString
        let sink = LokiLogSink(
            endpoint: URL(string: "http://localhost:3100/loki/api/v1/push")!,
            labels: ["app": "LokiKitSmoke", "env": "verification"], allowedMessages: [marker]
        )
        PrintLogger.configureRemoteSink(sink)
        defer { PrintLogger.configureRemoteSink(nil) }
        PrintLogger(subsystem: "LiveVerification").info(marker)
        await sink.flush()

        var components = URLComponents(string: "http://localhost:3100/loki/api/v1/query_range")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "{app=\"LokiKitSmoke\",stream=\"log\"} |= \"\(marker)\""),
            URLQueryItem(name: "limit", value: "10")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(result["data"] as? [String: Any])
        let streams = try XCTUnwrap(payload["result"] as? [[String: Any]])
        XCTAssertFalse(streams.isEmpty, "Real Loki did not return the uploaded PrintLogger record")
        let values = try XCTUnwrap(streams.first?["values"] as? [[String]])
        XCTAssertTrue(values.contains { $0.count == 2 && $0[1].contains(marker) })
    }
}
