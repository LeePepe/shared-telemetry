import Foundation
import XCTest
@testable import LokiKit

#if os(macOS)
import Darwin

final class LokiTelemetryDurabilityTests: XCTestCase {
    func testTrackSurvivesProcessKillBeforeFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LokiDurability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [
            "-XCTest", "LokiKitTests.LokiTelemetryDurabilityTests/testEnqueueProcessFixture",
            Bundle(for: Self.self).bundleURL.path
        ]
        // XCTest can dump its environment on invocation errors. Never inherit credentials.
        var environment = ProcessInfo.processInfo.environment.filter {
            ["DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "SDKROOT", "TMPDIR"].contains($0.key)
        }
        environment["LOKIKIT_KILL_TEST_DIRECTORY"] = directory.path
        child.environment = environment
        let exited = expectation(description: "isolated enqueue process exited")
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        await fulfillment(of: [exited], timeout: 10)
        guard !child.isRunning else { return }
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)

        let restarted = TelemetryQueue(storeDirectory: directory)
        let batches = try restarted.loadPersistedBatches()
        XCTAssertEqual(batches.flatMap(\.events).map(\.name), ["synthetic.before-flush", "synthetic.last-track"])
    }

    func testEnqueueProcessFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["LOKIKIT_KILL_TEST_DIRECTORY"] else {
            return // This helper only runs the crash scenario in its isolated child process.
        }
        let service = LokiTelemetryService(
            endpoint: URL(string: "https://telemetry.example.invalid/loki/api/v1/push")!,
            storeDirectory: URL(fileURLWithPath: path)
        )
        service.track(TelemetryEvent(name: "synthetic.before-flush"))
        service.track(TelemetryEvent(name: "synthetic.last-track"))
        kill(getpid(), SIGKILL)
    }
}
#endif
