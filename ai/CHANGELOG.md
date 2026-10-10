# Swift release changes

## Unreleased — public Azure Blob telemetry

- Add explicit-consent `AzureBlobTelemetryService`, content-free diagnostics/errors
  and public finite-number/closed-label policy; reject whole unsafe events before enqueue.
- Bind backlog to durable identity/build epochs, preserving disable/cancellation,
  failed-reset readiness, recreation and winning-receipt cleanup.
- Reuse the configurable 50 MiB policy across all epochs, including durable drops,
  deferred source/sidecar reservations and no unvalidated cleanup payload rewrites.
- Add host-bundle configuration and startup/daily `telemetry.heartbeat`; missing
  configuration logs one fixed local warning and exposes a disabled heartbeat
  without provisioning a store or transmitting.
- Retain the 32 MiB response-memory guard and observed-progress pacing.
  No dependency, legacy adapter, format, tag or published-version change.
  These candidate additions are not in released 0.1.0.

## Unreleased — queue disk capacity

- Add a host-configurable `maxDiskBytes` initializer input to `LokiTelemetryService`,
  defaulting to 50 MiB; no dependency on `LokiLogSink` defaults.
- Bound persisted event JSON plus Blob sidecars; reject individually oversized
  events and evict whole oldest batches, with persistent `droppedEventCount`.
- Journal evictions before paired cleanup so deletion failures and recreation
  cannot replay or recount the selected loss. Preserve owned flush snapshots;
  retry quota-deferred writes after the active flush releases them.
- Retain legacy event/wire formats and transport receipt rules. The new loss
  ledger must finish pending cleanup before rollback to an older reader.
  No release, live integration or full verification is implied by this entry.

## Unreleased — durable event enqueue

- Attempt atomic persistence before enabled `track` returns; retain failed writes
  in memory and expose cumulative per-instance `persistenceFailureCount`.
- Snapshot batches for serial retry and delete only after successful transport;
  concurrent enqueue/flush cannot clear a newer batch.
- Replay recovered history before current-instance batches; preserve live batch
  enqueue order across atomic write retries without duplicating disk/memory IDs.
  Restart still uses legacy file-creation order, not durable enqueue FIFO.
- Rotate internal batches without eviction to bound per-enqueue rewrite growth;
  retain memory delivery during directory-read failure and count inaccessible
  stores/removals instead of treating them as missing.
- Keep existing public signatures and legacy JSON batch compatibility. Storage
  I/O now blocks `track`; no disk limit, overflow policy, release or lossless
  delivery guarantee is introduced.

## 0.1.0 — first release (Git tag v0.1.0)

- Ship a version-bound Swift consumer entry, registry/schema, integration and
  migration contract with the SwiftPM source checkout.
- Add public-product external tests for synthetic redaction, capacity and retry.
- Runtime API, platform requirements and dependency range remain unchanged.

First release, distributed from Git tag `v0.1.0` through SwiftPM:
`.package(url: "https://github.com/LeePepe/shared-telemetry.git", exact: "0.1.0")`.
Licensed under MIT (repository root `LICENSE`). Open target gaps
remain in [COMPATIBILITY.md](COMPATIBILITY.md).
