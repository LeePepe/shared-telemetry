# LokiKit Swift SDK

Read this contract when wiring Swift telemetry, console logging or a remote log mirror. Implementation facts were originally source-reviewed at `eff9c1712cd648ed0717e41183ad8bd7bf39cbea` and are reconciled here with the integrated Swift changes at `45bb59282fa32e2c87849527b9253d928c6ac5ee`: an instance-owned internal TelemetryDeck client seam for tests, with public live-adapter behavior retained, and removal of automatic error extraction from `TelemetryService` performance helpers. This reconciliation is source-only, not verification of combined runtime behavior or delivery; all examples remain **illustrative/source-reviewed, not executed**. Accepted upgrade targets and proposed consumer validation are described in [architecture](../../docs/architecture.md) and [onboarding](../../docs/onboarding-checklist.md), not claimed as implemented here.

## Package and compatibility

The [root manifest](../../Package.swift) and [nested manifest](Package.swift) expose the same `LokiKit` library from [Sources/LokiKit](Sources/LokiKit/). Both declare Swift tools `6.2`, iOS `26`, macOS `26` and a TelemetryDeck SwiftSDK dependency from `2.0.0`. The repository name is `shared-telemetry`; the product and `import LokiKit` remain unchanged. Use one package entry, not two copies of the same module.

These are manifest requirements, not tested combinations or an assertion of release availability. No SDK build, example type-check or runtime verification was performed for this documentation reconciliation. See the [cross-SDK compatibility table](../README.md#compatibility-and-distribution).

## Choose a public interface

| Public API | Existing responsibility |
|---|---|
| [Logger](Sources/LokiKit/Logger.swift), [LogLevel](Sources/LokiKit/LogLevel.swift) | `minimumLevel`; `log` with optional context and call-site metadata; `debug`, `info`, `warning`, `error`, `critical` conveniences; synchronous/asynchronous `performance` and manual `performanceStart`/`performanceEnd` helpers |
| [PrintLogger](Sources/LokiKit/PrintLogger.swift) | Console output; `init(subsystem:minimumLevel:)` defaults to empty subsystem and `.debug`; `configureRemoteSink(_:)` controls an optional process-wide mirror for all instances |
| [TelemetryEvent and TelemetryService](Sources/LokiKit/TelemetryService.swift) | Event name, string properties, timestamp; `isEnabled`, `track(_:)`, `track(name:properties:)`, no-properties convenience, `flush() async`, `resetIdentifier()` |
| `NoopTelemetryService` | No-op implementation, initially disabled |
| [LokiTelemetryService](Sources/LokiKit/LokiTelemetryService.swift) | Loki event transport, synchronous enqueue persistence and read-only `persistenceFailureCount`; `resetIdentifier()` is a no-op |
| [LokiLogSink](Sources/LokiKit/LokiLogSink.swift) | Separate, bounded, filtered log mirror; `record`, `start(flushInterval:)`, `flush() async` |
| [TelemetryDeckService](Sources/LokiKit/TelemetryDeckService.swift) | Adapter to TelemetryDeck, not Loki |
| [TelemetryService performance extensions](Sources/LokiKit/TelemetryService+Performance.swift) | Sync/async `measure`, `measureStart`, `measureEnd`; record `duration_ms` timing and append `.failed` to failure event names, without automatically extracting error descriptions |
| [TelemetryEventName](Sources/LokiKit/VoxPocketTelemetryEventNames.swift) | Existing product-specific enum; its presence is an exception to the product-local semantics target, not a relocation already completed |

`TelemetryQueue` and Swift `LokiShipper` are internal implementation details, unlike the Web exports of similar names.

## Loki event telemetry

`LokiTelemetryService(endpoint:appLabels:isEnabled:authToken:storeDirectory:)` requires a `URL`; labels default to `[:]`, enabled to `true`, token and store directory to `nil`. Supply a consumer-owned isolated store directory when planning a drill; the default uses Application Support's `telemetry/pending` (temporary-directory fallback), not a per-endpoint namespace.

Illustrative/source-reviewed, not executed: this construction and event call use synthetic values. The reserved domain is a placeholder, not a working receiver. Construction can create a directory; this is not a runnable validation recipe.

```swift
import Foundation
import LokiKit

func makeSyntheticTelemetry(storeDirectory: URL) -> LokiTelemetryService {
    LokiTelemetryService(
        endpoint: URL(string: "https://telemetry.example.invalid/loki/api/v1/push")!,
        appLabels: ["app": "sample-consumer", "env": "synthetic"],
        isEnabled: true,
        authToken: nil,
        storeDirectory: storeDirectory
    )
}

func recordSyntheticEvent(telemetry: LokiTelemetryService) {
    telemetry.track(name: "sample.completed", properties: ["count": "1"])
}

func attemptFlush(telemetry: LokiTelemetryService) async {
    await telemetry.flush()
}
```

In the unreleased source, enabled `track` synchronously attempts an atomic JSON write before returning. An immediately following `flush()` includes those events in its snapshot; it is still not a delivery receipt. File I/O blocks the calling thread. Internal batches rotate after 64 events, so enqueue rewrites at most that many events without scanning or rewriting the accumulated backlog. Full batches remain queued until delivery; rotation does not evict events or bound total storage or individual event size. Storage speed and event size still affect latency; no wall-clock bound is guaranteed. The caller owns flush scheduling. This slice does not choose a disk cap, oversized-event policy or overflow counters.

`flush()` retries pending writes, snapshots persisted batches in file-creation order plus memory-only fallback events, then sends them. If directory reading fails, that failure is counted and retained memory events can still be sent. A batch is removed only after HTTP success. A failed send or removal stops that flush and retains pending work. Concurrent flush calls on one instance do not duplicate in-flight work; events tracked during transport form a separate batch for a later flush. A store directory must have one live service owner; no cross-instance/process locking is provided.

`persistenceFailureCount` counts failed storage operations (write, directory/read/decode, removal) for the current service instance, not lost events or failed uploads. Each failed attempt counts once, retries may increase it, successful operations do not reset it, and reading it performs no I/O. It resets with a new instance. A genuinely absent store or already-absent removed file is benign; permission errors are not treated as absence. Failed enqueue writes retain the original in memory for retry, but those events can still be lost on process exit. Corrupt files remain on disk and each failed read attempt is counted; healthy batches can still load. Disabling `isEnabled` blocks new tracks and flush attempts without erasing pending data.

The disk format remains UUID-named JSON arrays using the existing ISO-8601 dates. Older batches can replay, and the previous SDK can decode new files on rollback. As before, disk replay has whole-second timestamp precision; live memory retains original timestamps. Successful atomic writes cover process termination after `track` returns, not power loss/fsync guarantees, failed storage, unlimited retention or exactly-once delivery. Ambiguous HTTP outcomes and failed removals can cause duplicates. Keep unsent files when rolling back; no cleanup or migration is performed automatically.

The shipper sets a ten-second request timeout and accepts HTTP 2xx. It groups streams by event name; lines contain the name when properties are empty, otherwise sorted `key=value` text. This is not the Web/Python JSON envelope.

## Console logging and remote log mirror

Illustrative/source-reviewed, not executed; local logging only unless a remote sink has already been configured elsewhere in the process:

```swift
import LokiKit

let logger = PrintLogger(subsystem: "sample-consumer")
logger.info("sample.started")
logger.debug("sample.completed", context: ["count": 1])
```

`LokiLogSink(endpoint:labels:allowedMessages:allowedContextKeys:capacity:persistenceURL:token:session:)` requires endpoint, labels and a fixed-message allowlist. Defaults are no context keys, capacity `1_000` (must be positive), no persistence, no token and `URLSession.shared`. Pass it to `PrintLogger.configureRemoteSink(_:)` to mirror eligible logs process-wide; passing `nil` disconnects the mirror, but does not cancel a separately started task or purge persisted data.

This path is distinct from event telemetry:

- `record` keeps at most `capacity` entries, dropping oldest overflow. Remote messages outside the allowlist become a fixed redaction marker; only allowlisted finite numeric context values survive.
- `start(flushInterval:)` returns a task, defaulting to two seconds; the caller retains and cancels that task. Construction alone does not start this scheduler.
- Each `flush()` takes at most 200 entries; concurrent flush calls can return without draining. Send failure requeues within the capacity limit; no lossless guarantee follows.
- Optional persistence is attempted during flush, not every record call. The first flush attempts a one-time restore, accepting files up to 8 MiB and rechecking message/context filters. File I/O errors are swallowed. Disk persistence is neither an independent backup nor an exactly-once mechanism.

## TelemetryDeck adapter

`TelemetryDeckService(appID:isEnabled:testMode:defaultUser:)` requires an app ID; defaults are enabled, `nil` test-mode override and `nil` default user. Construction calls `TelemetryDeck.initialize` even if this adapter starts disabled. The adapter forwards event names/properties to `TelemetryDeck.signal`; it does not forward `TelemetryEvent.timestamp`. `flush()` requests immediate sync without awaiting a delivery result; `resetIdentifier()` requests a new session. Dependency-internal scheduling, privacy guarantees and resolved-version compatibility were not verified here. This adapter does not use Loki queue files or Loki authentication.

## Privacy and authentication

The log sink's filtering is not universal SDK redaction. Labels, subsystem and function metadata still need review; the sink retains a file basename and line number. `PrintLogger` continues to print supplied messages and context locally, including content redacted from the remote mirror. `Logger` performance helpers still include `error.localizedDescription` in failure context. `TelemetryService` `measure`/`measureEnd` helpers do not automatically extract error descriptions or types: they write `duration_ms` and append `.failed` to failure event names. Their other caller-provided properties, including an explicitly supplied `error`, remain unchanged and are not sanitized; `duration_ms` is overwritten by the measured timing. Event telemetry also forwards caller-provided properties. `isEnabled` is a switch, not a consent UI or data-erasure mechanism.

Loki adapters optionally send `Authorization: Bearer …`. This neither authenticates the receiver by itself nor proves general Grafana Cloud compatibility. The old base64 credential recipe is unsupported by this source inspection. Receiver requirements, transport security and credential provisioning need separately verified consumer configuration; no credentials belong in examples. For asset-level recovery limits read [disaster recovery](../../docs/disaster-recovery.md).
