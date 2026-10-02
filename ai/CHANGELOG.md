# Swift release changes

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
