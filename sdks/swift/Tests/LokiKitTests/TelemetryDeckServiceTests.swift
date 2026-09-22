import XCTest
@testable import LokiKit

final class TelemetryDeckServiceTests: XCTestCase {
    func testDefaultConfigurationAndEnabledState() {
        let client = RecordingTelemetryDeckClient()
        let service = TelemetryDeckService(appID: "synthetic.default", client: client)

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(client.calls, [
            .initialize(appID: "synthetic.default", testMode: nil, defaultUser: nil),
        ])
    }

    func testConfigurationForwardsOptionalValuesUnchangedEvenWhenDisabled() {
        for testMode: Bool? in [nil, false, true] {
            for defaultUser: String? in [nil, "", "synthetic.user"] {
                let client = RecordingTelemetryDeckClient()
                let service = TelemetryDeckService(
                    appID: "synthetic.config", isEnabled: false,
                    testMode: testMode, defaultUser: defaultUser, client: client
                )

                XCTAssertFalse(service.isEnabled)
                XCTAssertEqual(client.calls, [
                    .initialize(appID: "synthetic.config", testMode: testMode, defaultUser: defaultUser),
                ])
            }
        }
    }

    func testBothTrackOverloadsForwardExactPayloadsOnceWhenEnabled() {
        let client = RecordingTelemetryDeckClient()
        let service = TelemetryDeckService(appID: "synthetic.track", client: client)

        service.track(TelemetryEvent(name: "synthetic.event", properties: ["key": "value", "empty": ""]))
        service.track(name: "synthetic.named", properties: ["platform": "synthetic", "version": "1.0"])

        XCTAssertEqual(client.calls, [
            .initialize(appID: "synthetic.track", testMode: nil, defaultUser: nil),
            .signal(name: "synthetic.event", parameters: ["key": "value", "empty": ""]),
            .signal(name: "synthetic.named", parameters: ["platform": "synthetic", "version": "1.0"]),
        ])
    }

    func testBothTrackOverloadsAreSuppressedWhenInitiallyDisabled() {
        let client = RecordingTelemetryDeckClient()
        let service = TelemetryDeckService(appID: "synthetic.disabled", isEnabled: false, client: client)

        service.track(TelemetryEvent(name: "synthetic.event", properties: ["key": "value"]))
        service.track(name: "synthetic.named", properties: ["key": "value"])
        service.track(name: "synthetic.empty")

        XCTAssertEqual(client.calls, [
            .initialize(appID: "synthetic.disabled", testMode: nil, defaultUser: nil),
        ])
    }

    func testEnabledMutationGatesBothOverloadsWithoutReinitialization() {
        let client = RecordingTelemetryDeckClient()
        let service = TelemetryDeckService(appID: "synthetic.toggle", client: client)
        let event = TelemetryEvent(name: "synthetic.event", properties: ["key": "value"])

        service.isEnabled = false
        XCTAssertFalse(service.isEnabled)
        service.track(event)
        service.track(name: "synthetic.named", properties: ["other": "value"])

        service.isEnabled = true
        XCTAssertTrue(service.isEnabled)
        service.track(event)
        service.track(name: "synthetic.named", properties: ["other": "value"])

        service.isEnabled = false
        service.track(event)
        service.track(name: "synthetic.named", properties: ["other": "value"])

        XCTAssertEqual(client.calls, [
            .initialize(appID: "synthetic.toggle", testMode: nil, defaultUser: nil),
            .signal(name: "synthetic.event", parameters: ["key": "value"]),
            .signal(name: "synthetic.named", parameters: ["other": "value"]),
        ])
    }

    func testProtocolConvenienceForwardsEmptyProperties() {
        let client = RecordingTelemetryDeckClient()
        let service: any TelemetryService = TelemetryDeckService(appID: "synthetic.protocol", client: client)

        XCTAssertTrue(service.isEnabled)
        service.track(name: "synthetic.empty")

        XCTAssertEqual(client.calls, [
            .initialize(appID: "synthetic.protocol", testMode: nil, defaultUser: nil),
            .signal(name: "synthetic.empty", parameters: [:]),
        ])
    }

    func testFlushForwardsImmediateSyncOnceRegardlessOfEnabledState() async {
        for isEnabled in [true, false] {
            let client = RecordingTelemetryDeckClient()
            let service = TelemetryDeckService(appID: "synthetic.flush", isEnabled: isEnabled, client: client)

            await service.flush()

            XCTAssertEqual(client.calls, [
                .initialize(appID: "synthetic.flush", testMode: nil, defaultUser: nil),
                .requestImmediateSync,
            ])
        }
    }

    func testResetForwardsSessionGenerationOnceRegardlessOfEnabledState() {
        for isEnabled in [true, false] {
            let client = RecordingTelemetryDeckClient()
            let service = TelemetryDeckService(appID: "synthetic.reset", isEnabled: isEnabled, client: client)

            service.resetIdentifier()

            XCTAssertEqual(client.calls, [
                .initialize(appID: "synthetic.reset", testMode: nil, defaultUser: nil),
                .generateNewSession,
            ])
        }
    }

    func testFakeBackedInstancesKeepConfigurationCallsAndEnabledStateSeparate() async {
        let firstClient = RecordingTelemetryDeckClient()
        let first = TelemetryDeckService(
            appID: "synthetic.first", testMode: true, defaultUser: "synthetic.user", client: firstClient
        )
        first.track(TelemetryEvent(name: "synthetic.before.second"))

        let secondClient = RecordingTelemetryDeckClient()
        let second = TelemetryDeckService(
            appID: "synthetic.second", isEnabled: false, testMode: false, client: secondClient
        )
        first.track(name: "synthetic.after.second", properties: ["owner": "first"])
        second.track(TelemetryEvent(name: "synthetic.suppressed"))
        await first.flush()
        first.resetIdentifier()
        first.isEnabled = false
        second.isEnabled = true
        XCTAssertFalse(first.isEnabled)
        XCTAssertTrue(second.isEnabled)
        first.track(name: "synthetic.suppressed", properties: [:])
        second.track(name: "synthetic.second.event", properties: ["owner": "second"])
        await second.flush()
        second.resetIdentifier()

        XCTAssertEqual(firstClient.calls, [
            .initialize(appID: "synthetic.first", testMode: true, defaultUser: "synthetic.user"),
            .signal(name: "synthetic.before.second", parameters: [:]),
            .signal(name: "synthetic.after.second", parameters: ["owner": "first"]),
            .requestImmediateSync,
            .generateNewSession,
        ])
        XCTAssertEqual(secondClient.calls, [
            .initialize(appID: "synthetic.second", testMode: false, defaultUser: nil),
            .signal(name: "synthetic.second.event", parameters: ["owner": "second"]),
            .requestImmediateSync,
            .generateNewSession,
        ])
    }
}

/// Only records synthetic values in instance memory; no SDK, storage, timers, or transport.
private final class RecordingTelemetryDeckClient: TelemetryDeckClient {
    enum Call: Equatable {
        case initialize(appID: String, testMode: Bool?, defaultUser: String?)
        case signal(name: String, parameters: [String: String])
        case requestImmediateSync
        case generateNewSession
    }

    private(set) var calls: [Call] = []

    func initialize(appID: String, testMode: Bool?, defaultUser: String?) {
        calls.append(.initialize(appID: appID, testMode: testMode, defaultUser: defaultUser))
    }

    func signal(_ name: String, parameters: [String: String]) {
        calls.append(.signal(name: name, parameters: parameters))
    }

    func requestImmediateSync() {
        calls.append(.requestImmediateSync)
    }

    func generateNewSession() {
        calls.append(.generateNewSession)
    }
}
