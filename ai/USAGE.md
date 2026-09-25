# Swift public API

The authoritative API/lifecycle explanation is the
[Swift SDK contract](../sdks/swift/README.md). It distinguishes the public
`Logger`, `LogLevel`, `PrintLogger`, `TelemetryEvent`, `TelemetryService`,
`NoopTelemetryService`, `LokiTelemetryService`, `LokiLogSink`,
`TelemetryDeckService` and legacy product-specific `TelemetryEventName`.
Swift `TelemetryQueue` and `LokiShipper` are internal; consumers must not import
them through `@testable` or copy them.

`TelemetryService` helpers keep caller-provided properties, measure duration
and append `.failed` on failure without extracting error descriptions.
`LokiLogSink` filters messages/finite numeric context and bounds its queue;
that is **not universal SDK redaction**. `LokiTelemetryService` forwards caller
properties and has an unbounded in-memory event queue. Console/performance
logging may still expose caller content or error descriptions. Filter product
data before calling any API; no recordings, transcripts, prompts, personal
health/financial content or credentials belong in telemetry.

The Loki outer push shape is shared, but Swift event lines are plain/sorted
key=value text while the log sink uses JSON. No unified inner event schema is
implemented. Flush is not an end-to-end receipt; asynchronous event enqueue is
not a demonstrated immediate-flush barrier. See the source-backed contract for
retry/persistence/loss limits and receiver-specific authentication cautions.
