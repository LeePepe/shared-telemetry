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
| [LokiTelemetryService](Sources/LokiKit/LokiTelemetryService.swift) | Loki event transport, synchronous enqueue persistence, configurable `maxDiskBytes`, read-only `persistenceFailureCount` and `droppedEventCount`; `resetIdentifier()` is a no-op |
| [LokiLogSink](Sources/LokiKit/LokiLogSink.swift) | Separate, bounded, filtered log mirror; `record`, `start(flushInterval:)`, `flush() async` |
| [TelemetryDeckService](Sources/LokiKit/TelemetryDeckService.swift) | Adapter to TelemetryDeck, not Loki |
| [TelemetryService performance extensions](Sources/LokiKit/TelemetryService+Performance.swift) | Sync/async `measure`, `measureStart`, `measureEnd`; record `duration_ms` timing and append `.failed` to failure event names, without automatically extracting error descriptions |
| [TelemetryEventName](Sources/LokiKit/VoxPocketTelemetryEventNames.swift) | Existing product-specific enum; its presence is an exception to the product-local semantics target, not a relocation already completed |

`TelemetryQueue` and Swift `LokiShipper` are internal implementation details, unlike the Web exports of similar names.

## Loki event telemetry

`LokiTelemetryService(endpoint:appLabels:isEnabled:authToken:storeDirectory:maxDiskBytes:)` requires a `URL`; labels default to `[:]`, enabled to `true`, token and store directory to `nil`. The optional positive `maxDiskBytes` defaults to **50 MiB (52,428,800 bytes)**, independently of `LokiLogSink`; a host can override it in the initializer. Supply a consumer-owned isolated store directory when planning a drill; the default uses Application Support's `telemetry/pending` (temporary-directory fallback), not a per-endpoint namespace. These additions are unreleased source, not APIs in tag `v0.1.0`.

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

In the unreleased source, enabled `track` synchronously attempts an atomic JSON write before returning, subject to the capacity policy below. An immediately following `flush()` includes retained events in its snapshot; it is still not a delivery receipt. File I/O blocks the calling thread. Internal batches rotate after 64 events or before a combined batch would exceed the byte limit. Ordinary enqueue rewrites only its active batch; a cached file-size inventory and overflow-time ordering avoid decoding the entire backlog on every enqueue. Storage speed and event size still affect latency; no wall-clock bound is guaranteed. The caller owns flush scheduling.

The cap covers the logical byte lengths of owned UUID-named source JSON files **plus Blob sidecars**, not filesystem allocation units, transient atomic-write copies, the small loss ledger or other files in the directory. A single event whose one-element legacy JSON array exceeds the cap is discarded before admission and counted once; existing backlog is not evicted to admit an impossible event. At the limit, data is accepted. On overflow, the queue evicts **whole oldest batches**, counting their events rather than files; it may free more bytes than strictly necessary. Recovered batches use the existing file-creation ordering (UUID breaks equal-date eviction ties), followed by current-instance batches in enqueue order. It does not rewrite a partially journaled Blob request into a smaller batch or assign it a new identity.

The first flush snapshot also applies the configured cap to recovered backlog. An owned flush then protects its captured source/sidecar identities: new writes that would require eviction remain dirty in memory until that flush ends, without growing the persisted queue. Confirmed delivery frees capacity without counting a loss; otherwise pending capacity work is reconciled after release. A Blob sidecar that cannot fit is not written or sent; its existing persistence error stops that flush, then quota reconciliation can evict the oldest batch. Construction and disabled calls do not purge backlog. This is a disk-data bound, not a bound on failed/deferred memory fallback or a guarantee that an unreadable/undeletable pre-existing store can immediately be brought below a newly reduced limit.

`droppedEventCount` is a read-only, store-cumulative count of capacity rejections and logical evictions, restored on recreation and saturating at `Int.max`. It does not count disabled calls, successful delivery or network failures. A hidden `.queue-capacity` record commits the count and selected batch IDs before deletion; those tombstones are never replayed or recounted after restart. Cleanup removes the sidecar before its source and retries on later writes/flushes. Failure to commit the tombstone leaves the batch unchanged; failure to unlink retains a tombstoned file rather than pretending deletion succeeded or exceeding the cap with a new write. Wrong file types are retained, not recursively removed. This is scoped eviction cleanup, not general filesystem repair.

Counter persistence failures retain newly rejected-event counts in memory for retry, but process exit before a successful retry can lose those increments. An unreadable loss record is retained and fails storage operations instead of being overwritten with a fabricated zero; its prior total is unavailable until a read succeeds. Reads of the counters perform no I/O. Keep all queue files and the ledger together under one owner; external edits/deletions or older writers ignoring tombstones are unsupported. Atomic writes cover ordinary process termination, not power-loss/fsync durability.

`flush()` retries pending writes, then snapshots retained recovered batches whose IDs are not in this instance's memory first, in file-creation order. Current-instance batches follow in their original enqueue order, including memory-only fallback; a known ID uses its full memory original once, not its possibly incomplete disk copy. Retrying an older atomic write cannot move that live batch behind a newer one. If directory reading fails, that failure is counted and retained memory events can still be sent. Apart from explicit capacity eviction, a batch is removed only after HTTP success. A failed send or delivery removal stops that flush and retains pending work. Concurrent flush calls on one instance do not duplicate in-flight work; events tracked during transport form a separate batch for a later flush. A store directory must have one live service owner; no cross-instance/process locking is provided.

This is not a universal FIFO guarantee. After restart all recovered batches use the legacy file-creation ordering, not event timestamps or a persisted enqueue sequence. Atomic replacement can refresh creation dates; equal or unavailable dates have no defined relative order. Unreadable files are retained and counted but do not block healthy batches.

`persistenceFailureCount` counts failed storage operations (write, directory/read/decode, removal) for the current service instance, not lost events or failed uploads. Each failed attempt counts once, retries may increase it, successful operations do not reset it, and reading it performs no I/O. It resets with a new instance. A genuinely absent store or already-absent removed file is benign; permission errors are not treated as absence. Failed enqueue writes retain the original in memory for retry, but those events can still be lost on process exit. Corrupt files remain on disk and each failed read attempt is counted; healthy batches can still load. Disabling `isEnabled` blocks new tracks and flush attempts without erasing pending data.

The event disk format remains UUID-named JSON arrays using the existing ISO-8601 dates. Older batches can replay, and the previous SDK can decode retained event files on rollback. Older SDKs do not understand the loss ledger: resolve pending eviction cleanup before rollback, otherwise they may replay tombstoned files. As before, disk replay has whole-second timestamp precision; live memory retains original timestamps. Successful atomic event writes cover process termination after `track` returns, not power loss/fsync guarantees, failed/deferred storage, unlimited retention or exactly-once delivery. Ambiguous HTTP outcomes and failed delivery removals can cause duplicates. Keep retained unsent files when rolling back; capacity losses are irreversible.

The shipper sets a ten-second request timeout and accepts HTTP 2xx. It groups streams by event name; lines contain the name when properties are empty, otherwise sorted `key=value` text. This is not the Web/Python JSON envelope.

## Unreleased internal Azure Blob transport core

`AzureBlobTransport` is **internal**, not a new public `TelemetryService` or a
released consumer entry point. Loki APIs, defaults and wire bytes are unchanged.
Public Blob wiring remains dependent on separately reviewed privacy adoption,
configuration and observability work. This internal core enforces its own
default-deny policy; generic `TelemetryEvent.properties` do **not** inherit
`LokiLogSink` filtering. No consumer rollout is established here.

`AzureBlobPrivacyPolicy` is an instance-owned validator, not a global registry.
The caller supplies reviewed, code-configured exact event names and per-event
field constraints: `finiteNumber` accepts a complete finite JSON-number string,
and `label` accepts only membership in the configured closed set. There is no
arbitrary-string rule, wildcard name/key or automatic field removal. Unregistered
names/keys, unsafe values under registered keys and non-finite numbers reject the
whole batch with the fixed, content-free `privacyRejected` error. With no policy,
no batch can be exported. Valid accepted values are not normalized or rewritten.

The same policy explicitly lists approved app/build path labels, including any
historical values that may be replayed. Policy names/keys/labels must never be
derived from incoming event content. App/build and install UUID must come from
reviewed product code/configuration and an approved non-personal install-identity
lifecycle. Syntax, finite numbers or UUID shape cannot prove provenance: an account
UUID, sensitive numeric measurement or user-derived label does not become safe by
passing a parser. No general event-identifier rule or product vocabulary is added.

Blob obtains a quota-reconciled queue snapshot without retrying event writes, validates all events in each retained batch
before encoding or transport persistence, and only then attempts durable writes.
On restart it revalidates source events and stored path against the current policy.
It also decompresses the entire saved gzip stream and requires byte equality with
the currently approved canonical NDJSON; source digest alone is not privacy
approval. Extra JSON fields, optional gzip header metadata, trailing data,
concatenated gzip members or stricter-policy
mismatches block export without changing the journal, assigning a new upload ID,
acknowledging delivery, deleting or migrating any records. Valid legacy compressed
bytes are sent unchanged, not recompressed. As with other failures, a rejected
batch stops that flush and can block later safe backlog until its policy or data
disposition is explicitly resolved; this is not automatic recovery or disposal.

This is an export/journal guard, **not** a privacy guarantee for the generic queue.
Generic `TelemetryQueue` and public Loki admission still do not filter content;
TelemetryDeck is unchanged. Unsafe content already accepted can remain in memory
or raw JSON files unless the independent queue capacity policy evicts it. The core
does not provide ingress filtering. A rejected dirty suffix remains in memory
without a Blob-triggered rewrite unless quota eviction selects its batch; process exit can
still lose a previously failed generic enqueue, as documented above. Public
ingress protection, compatible adoption/migration and disposal of unsafe retained
records remain separate work. Rolling back to an older exporter can remove this
guard and expose old content; a readable queue format does not imply safe rollback.

The core takes an explicit HTTPS container URL, create-only container service SAS
query, app/build/install ID and the explicit privacy policy. It reads no environment,
plist, Keychain or build secrets. Stored-policy SAS (`si`, without `sp`) is supported;
explicit `sp`, when present, must be `c`. The caller owns the policy's actual
permissions and consent. The transport creates its own ephemeral `URLSession` for
each flush and invalidates it on exit, including failure and cancellation. It
never borrows a caller's session/delegate, credential store, cookies, additional
headers, cache or proxy configuration. Credential/cookie stores and caching are
disabled; redirects and non-server-trust authentication challenges are refused at
both the session (NTLM, Negotiate, client certificate) and task levels. Server trust
uses system default TLS validation, without supplying credentials or accepting
certificates itself. No payload, SAS URL or server error body is logged or included
in transport errors.

Response bodies are streamed to a discard-only data delegate, never aggregated,
written to disk, logged or copied into errors/journals. Only the HTTP status and
whether the exact overwrite code matched are retained by the receipt handler.
Headers alone do not acknowledge delivery: successful terminal task completion is
required, and a later network error or cancellation keeps the batch pending even
after 201/overwrite headers. No intentional header-only cancellation, response
size policy is introduced by the response handler. Queue capacity is enforced separately. Cancellation and completion
atomically take a single continuation; a cancelled flush releases its task/session
and later flushes can retry normally. Existing request timeouts remain unchanged;
this bounds application-retained response state, not total network traffic or
every transient buffer inside Foundation.

The internal `configuration` argument is only a source of `protocolClasses` for
isolated tests; all other settings are ignored, and the protocol list is captured
at construction. Injected protocols are trusted code capable of observing requests,
not a sandbox for untrusted networking extensions. Callers cannot use this seam to
replace the transport's authentication delegate. Synthetic tests verify Foundation
challenge routing, request isolation and the default-trust disposition; they do not
establish a real TLS handshake or live Azure acceptance.

Each request is `PUT` with `x-ms-blob-type: BlockBlob`, `If-None-Match: *`,
`Content-Type: application/x-ndjson` and `Content-Encoding: gzip`. The system zlib
produces the gzip stream; no new package dependency is required. Each NDJSON line
contains the existing event's `name`, `properties` and ISO8601 `timestamp`, with a
final newline. Blob timestamps use the legacy queue's whole-second precision from
the first send; live Loki timestamps retain their existing precision.

Before the first request, the full queue batch must be durable. A checksummed
`<queue-id>.azure-blob` sidecar freezes the exact compressed bytes, source digest,
destination and `<app>/<build>/<yyyy-mm-dd>/<install-id>/<batch-uuid>.ndjson.gz`
path, using UTC at preparation and a fresh upload UUID. It contains no SAS. Retries
and restarts use those bytes, not recompression or current build/clock/install
values. A changed container or mismatched/corrupt source record blocks that batch;
it cannot redirect old data using new credentials. SAS rotation for the same
container is possible without changing batch identity. One live owner per store
directory remains required; do not share the directory with concurrent Loki/Blob
instances, edit journals or mix copied queue files from different stores.

Only HTTP201, or a validated retransmission returning HTTP403 with exactly
`x-ms-error-code: UnauthorizedBlobOverwrite`, permits queue removal. The latter
relies on the durable immutable request, exclusive ownership of the upload
namespace and a previously unresolved attempt (including termination during the
request); it is not a remote content-hash readback. A first overwrite rejection is
not acknowledged, even on repeated definitive retries. Other 403/409 responses,
missing/unknown error codes and network ambiguity retain pending work. A failed
write-ahead record prevents sending; storage failures use the existing queue
counter. This is not an exactly-once or absolute no-loss guarantee.

Legacy UUID JSON event arrays stay readable without migration; older Loki code
ignores sidecars and loss tombstones and can replay those arrays, with duplicate
and rollback risks described above. Retain unsent files when rolling back.
Confirmed-delivery removal happens source-first; interruption or sidecar-removal failure at that point
can leave an inert sidecar, never deletion of unconfirmed source data. Automatic
orphan repair, heartbeat/disabled reporting, public privacy filtering, release
packaging and real consumer acceptance are not implemented by this internal core.
Queue-owned quota eviction and paired cleanup are described above. The current encoder retains data and fails preparation
if a single NDJSON body exceeds zlib's 32-bit input range; it does not evict events.

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
