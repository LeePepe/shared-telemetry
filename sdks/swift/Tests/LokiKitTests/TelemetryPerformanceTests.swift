import XCTest
import Synchronization
import LokiKit

// MARK: - Spy

private final class SpyTelemetryService: TelemetryService, Sendable {
    private struct State: Sendable {
        var isEnabled = true
        var trackedNames: [(name: String, properties: [String: String])] = []
    }

    private let state = Mutex(State())

    var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set { state.withLock { $0.isEnabled = newValue } }
    }

    var trackedNames: [(name: String, properties: [String: String])] {
        state.withLock { $0.trackedNames }
    }

    func track(_ event: TelemetryEvent) {
        track(name: event.name, properties: event.properties)
    }

    func track(name: String, properties: [String: String]) {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.trackedNames.append((name: name, properties: properties))
        }
    }

    func flush() async {}
    func resetIdentifier() {}
}

/// Entirely synthetic; reading its description is itself a regression.
private final class SensitiveError: LocalizedError, Sendable {
    static let sentinel = "SYNTHETIC_PRIVATE_TRANSCRIPT_TOKEN_DO_NOT_CAPTURE"
    private let descriptionReads = Mutex(0)

    var errorDescription: String? {
        descriptionReads.withLock { $0 += 1 }
        return Self.sentinel
    }

    var descriptionReadCount: Int {
        descriptionReads.withLock { $0 }
    }
}

// MARK: - Tests

final class TelemetryPerformanceTests: XCTestCase {

    // MARK: - measure sync

    func testMeasureSyncEmitsEventWithDurationMs() {
        let service = SpyTelemetryService()
        let result = service.measure("test.sync") { 42 }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(service.trackedNames.count, 1)
        XCTAssertEqual(service.trackedNames[0].name, "test.sync")
        XCTAssertNotNil(service.trackedNames[0].properties["duration_ms"])
    }

    func testMeasureSyncMergesExtraProperties() {
        let service = SpyTelemetryService()
        service.measure("op", properties: ["source": "test"]) {}
        XCTAssertEqual(service.trackedNames[0].properties["source"], "test")
        XCTAssertNotNil(service.trackedNames[0].properties["duration_ms"])
    }

    func testMeasureSyncOnErrorEmitsMetricsWithoutReadingError() throws {
        let service = SpyTelemetryService()
        let failure = SensitiveError()
        XCTAssertThrowsError(try service.measure("op", properties: ["source": "test"]) {
            throw failure
        }) { error in
            XCTAssertTrue((error as? SensitiveError) === failure)
        }
        XCTAssertEqual(failure.descriptionReadCount, 0)
        try assertFailureEvent(service, name: "op.failed", properties: ["source": "test"])
    }

    func testMeasureSyncDoesNotTrackWhenDisabled() {
        let service = SpyTelemetryService()
        service.isEnabled = false
        let result = service.measure("op") { 42 }
        XCTAssertEqual(result, 42)
        XCTAssertTrue(service.trackedNames.isEmpty)
    }

    func testMeasureSyncFailurePreservesSuppliedProperties() throws {
        let service = SpyTelemetryService()
        let failure = SensitiveError()
        let properties = ["error": "caller-code", "source": "test", "duration_ms": "caller-duration"]
        XCTAssertThrowsError(try service.measure("op", properties: properties) {
            throw failure
        }) { error in
            XCTAssertTrue((error as? SensitiveError) === failure)
        }
        XCTAssertEqual(failure.descriptionReadCount, 0)
        try assertFailureEvent(service, name: "op.failed", properties: properties)
    }

    func testMeasureSyncPreservesCancellation() throws {
        let service = SpyTelemetryService()
        XCTAssertThrowsError(try service.measure("cancel.op", properties: ["source": "test"]) {
            throw CancellationError()
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        try assertFailureEvent(service, name: "cancel.op.failed", properties: ["source": "test"])
    }

    func testMeasureSyncFailureWhenDisabledPreservesErrorWithoutReadingIt() {
        let service = SpyTelemetryService()
        service.isEnabled = false
        let failure = SensitiveError()
        XCTAssertThrowsError(try service.measure("disabled.op") { throw failure }) { error in
            XCTAssertTrue((error as? SensitiveError) === failure)
        }
        XCTAssertEqual(failure.descriptionReadCount, 0)
        XCTAssertTrue(service.trackedNames.isEmpty)
    }

    // MARK: - measure async

    func testMeasureAsyncEmitsEventWithDurationMs() async {
        let service = SpyTelemetryService()
        let result = await service.measure("test.async", properties: ["source": "test"]) { () async -> Int in
            99
        }
        XCTAssertEqual(result, 99)
        XCTAssertEqual(service.trackedNames.count, 1)
        XCTAssertEqual(service.trackedNames[0].name, "test.async")
        XCTAssertEqual(service.trackedNames[0].properties["source"], "test")
        XCTAssertNotNil(service.trackedNames[0].properties["duration_ms"])
    }

    func testMeasureAsyncOnErrorEmitsMetricsWithoutReadingError() async throws {
        let service = SpyTelemetryService()
        let failure = SensitiveError()
        do {
            try await service.measure("async.op", properties: ["source": "test"]) { () async throws -> Void in
                throw failure
            }
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue((error as? SensitiveError) === failure)
        }
        XCTAssertEqual(failure.descriptionReadCount, 0)
        try assertFailureEvent(service, name: "async.op.failed", properties: ["source": "test"])
    }

    func testMeasureAsyncFailurePreservesSuppliedProperties() async throws {
        let service = SpyTelemetryService()
        let failure = SensitiveError()
        let properties = ["error": "caller-code", "source": "test", "duration_ms": "caller-duration"]
        do {
            try await service.measure("async.op", properties: properties) { () async throws -> Void in
                throw failure
            }
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue((error as? SensitiveError) === failure)
        }
        XCTAssertEqual(failure.descriptionReadCount, 0)
        try assertFailureEvent(service, name: "async.op.failed", properties: properties)
    }

    func testMeasureAsyncPreservesTaskCancellationWhenEnabledOrDisabled() async throws {
        for isEnabled in [true, false] {
            let service = SpyTelemetryService()
            service.isEnabled = isEnabled
            // Cancel only this synthetic child task, never the XCTest task.
            let task = Task { () async throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.measure("async.cancel", properties: ["source": "test"]) { () async throws -> Void in
                    try Task.checkCancellation()
                }
            }
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(task.isCancelled)
            if isEnabled {
                try assertFailureEvent(service, name: "async.cancel.failed", properties: ["source": "test"])
            } else {
                XCTAssertTrue(service.trackedNames.isEmpty)
            }
        }
    }

    func testMeasureAsyncWhenDisabledPreservesResultAndErrorWithoutReadingIt() async {
        let service = SpyTelemetryService()
        service.isEnabled = false
        let result = await service.measure("disabled.success") { () async -> Int in 99 }
        XCTAssertEqual(result, 99)
        let failure = SensitiveError()
        do {
            try await service.measure("disabled.failure") { () async throws -> Void in
                throw failure
            }
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue((error as? SensitiveError) === failure)
        }
        XCTAssertEqual(failure.descriptionReadCount, 0)
        XCTAssertTrue(service.trackedNames.isEmpty)
    }

    // MARK: - measureStart / measureEnd

    func testManualStartEndEmitsEvent() {
        let service = SpyTelemetryService()
        let start = service.measureStart()
        service.measureEnd("manual.op", start: start)
        XCTAssertEqual(service.trackedNames.count, 1)
        XCTAssertEqual(service.trackedNames[0].name, "manual.op")
        XCTAssertNotNil(service.trackedNames[0].properties["duration_ms"])
    }

    func testManualStartEndWithErrorEmitsMetricsWithoutReadingError() throws {
        let service = SpyTelemetryService()
        let failure = SensitiveError()
        let start = service.measureStart()
        service.measureEnd("manual.op", start: start, error: failure, properties: ["env": "ci"])
        XCTAssertEqual(failure.descriptionReadCount, 0)
        try assertFailureEvent(service, name: "manual.op.failed", properties: ["env": "ci"])
    }

    func testManualEndMergesProperties() {
        let service = SpyTelemetryService()
        let start = service.measureStart()
        service.measureEnd("op", start: start, properties: ["env": "ci"])
        XCTAssertEqual(service.trackedNames[0].properties["env"], "ci")
        XCTAssertNotNil(service.trackedNames[0].properties["duration_ms"])
    }

    func testManualFailurePreservesSuppliedProperties() throws {
        let service = SpyTelemetryService()
        let failure = SensitiveError()
        let properties = ["error": "caller-code", "env": "ci", "duration_ms": "caller-duration"]
        service.measureEnd("manual.op", start: service.measureStart(), error: failure, properties: properties)
        XCTAssertEqual(failure.descriptionReadCount, 0)
        try assertFailureEvent(service, name: "manual.op.failed", properties: properties)
    }

    func testManualCancellationEmitsMetricsOnly() throws {
        let service = SpyTelemetryService()
        service.measureEnd("manual.cancel", start: service.measureStart(), error: CancellationError())
        try assertFailureEvent(service, name: "manual.cancel.failed")
    }

    func testManualEndWhenDisabledDoesNotTrackOrReadError() {
        let service = SpyTelemetryService()
        service.isEnabled = false
        let start = service.measureStart()
        let failure = SensitiveError()
        service.measureEnd("manual.success", start: start)
        service.measureEnd("manual.failure", start: start, error: failure)
        XCTAssertEqual(failure.descriptionReadCount, 0)
        XCTAssertTrue(service.trackedNames.isEmpty)
    }

    // MARK: - NoopTelemetryService passthrough

    func testMeasureOnNoopServiceDoesNotCrash() {
        let service = NoopTelemetryService()
        service.measure("noop.op") {}
    }

    func testMeasureAsyncOnNoopServiceDoesNotCrash() async {
        let service = NoopTelemetryService()
        await service.measure("noop.async.op") { () async -> Void in }
    }

    // MARK: - Failure payload contract

    private func assertFailureEvent(
        _ service: SpyTelemetryService,
        name: String,
        properties: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let events = service.trackedNames
        XCTAssertEqual(events.count, 1, file: file, line: line)
        let event = try XCTUnwrap(events.first, file: file, line: line)
        XCTAssertEqual(event.name, name, file: file, line: line)
        let duration = try XCTUnwrap(event.properties["duration_ms"], file: file, line: line)
        let milliseconds = try XCTUnwrap(Double(duration), file: file, line: line)
        XCTAssertTrue(milliseconds.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(milliseconds, 0, file: file, line: line)
        XCTAssertNotNil(duration.range(of: #"^\d+\.\d{2}$"#, options: .regularExpression), file: file, line: line)
        var expected = properties
        expected["duration_ms"] = duration
        XCTAssertEqual(event.properties, expected, file: file, line: line)
        XCTAssertFalse(event.properties.contains {
            $0.key.contains(SensitiveError.sentinel) || $0.value.contains(SensitiveError.sentinel)
        }, file: file, line: line)
    }
}
