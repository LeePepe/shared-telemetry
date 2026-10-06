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
properties. Unreleased source accepts an optional positive `maxDiskBytes`
(default 50 MiB) on `LokiTelemetryService`, limiting persisted source JSON plus
Blob sidecars independently of the log sink. Whole oldest batches are evicted;
single oversized events are rejected, with store-cumulative `droppedEventCount`
and restart-safe loss tombstones. These additions are not in tag `v0.1.0`.
Synchronous `track` attempts persistence; failed or in-flight quota-deferred
writes retain memory fallback. Storage failures increment read-only
`persistenceFailureCount`. Console/performance
logging may still expose caller content or error descriptions. Filter product
data before calling any API; no recordings, transcripts, prompts, personal
health/financial content or credentials belong in telemetry.

The Loki outer push shape is shared, but Swift event lines are plain/sorted
key=value text while the log sink uses JSON. No unified inner event schema is
implemented. Flush is not an end-to-end receipt; unreleased synchronous enqueue
blocks on storage and does not guarantee survival when persistence fails.
Internal batch rotation bounds rewrite growth; the separate quota bounds persisted
data, not memory fallback, ledger metadata or atomic-write transients. Directory-read
failure does not prevent attempts to send retained memory events. See the source-backed contract for
retry/persistence/loss limits and receiver-specific authentication cautions.
