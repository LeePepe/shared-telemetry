import LokiKit

public enum ConsumerHarness {
    public static func syntheticEvent() -> TelemetryEvent {
        TelemetryEvent(name: "synthetic.completed", properties: ["count": "1"])
    }
}
