import Foundation
import LokiKit
import XCTest

final class TelemetryQueueCapacityPublicTests: XCTestCase {
    func testHostCanOverrideDiskLimitAndObserveDurableDropsWithoutEnablingNetwork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PublicQueueCapacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "https://telemetry.example.invalid/push")!
        let service = LokiTelemetryService(endpoint: endpoint, isEnabled: false,
            storeDirectory: directory, maxDiskBytes: 1)
        service.track(name: "disabled", properties: [:])
        XCTAssertEqual(service.droppedEventCount, 0)
        service.isEnabled = true
        service.track(name: "oversized", properties: [:])
        XCTAssertEqual(service.droppedEventCount, 1)
        XCTAssertEqual(service.persistenceFailureCount, 0)
        let recreated = LokiTelemetryService(endpoint: endpoint, storeDirectory: directory, maxDiskBytes: 1)
        XCTAssertEqual(recreated.droppedEventCount, 1)
        recreated.track(name: "another", properties: [:])
        XCTAssertEqual(recreated.droppedEventCount, 2)
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["json", "azure-blob"].contains($0.pathExtension) }
        XCTAssertTrue(records.isEmpty, "Oversize rejection never persists event content")
    }
}
