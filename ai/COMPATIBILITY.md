# Swift compatibility

| Surface | Declared | Evidence boundary |
| --- | --- | --- |
| SwiftPM | Tools 6.2, product/module `LokiKit` | Root and nested manifests must agree |
| Platforms | iOS 26, macOS 26 | Host tests and generic iOS simulator compile; minimum OS/device behavior needs separate evidence |
| Dependency | TelemetryDeck SwiftSDK from 2.0.0 | Exact resolution is recorded by each consumer lockfile; no live adapter test is implied |
| AI resources | Root source checkout `ai/` | Immutable-revision/tag consumer resolver checks shipped files |
| Wire | Loki push outer shape | Different event/log inner formats; no unified schema version |

Licensed under MIT (the `shared-telemetry` repository root `LICENSE` file).
This work does not choose a platform expansion.
The dependency range is unchanged; no consumer may silently substitute a
different resolved version when reporting tested evidence.

Existing provider tests include one explicit opt-in live-Loki test that stays
skipped in ordinary runs. Mock URLProtocol tests do not count as that live test.
Unreleased source closes the asynchronous enqueue/flush window with synchronous
atomic persistence and a storage-failure counter; the existing public methods,
initializer and legacy JSON batch format remain compatible. Synchronous file
I/O latency and write amplification are caller-visible costs; internal batch
rotation bounds rewrite growth without discarding events or changing the disk
format. The later configurable disk quota bounds source JSON and sidecars,
not memory fallback or metadata. Legacy product-specific
event names, real receiver authentication/storage readback, four-metric coverage,
dependency/security scans and full D1 remain open or unmeasured. There is no
whole-SDK redaction claim and no complete 6DQ pass.

0.1.0 is the first release, so no earlier deprecation period exists. Future
breaking changes need explicit from/to guidance and reviewed consumer pin
upgrades.

## Unreleased Blob addition

The new explicit Adapter adds five public inventory entries (including the policy's
nested ValueRule), for exactly15; no existing public type/default or dependency
range changes. Its private version1 catalog wraps unchanged event-array JSON and
immutable Blob sidecars in identity/build epoch directories. It rejects legacy
nonempty roots instead of importing/migrating them. Default TelemetryQueue/Loki
read behavior stays unchanged; strict failure propagation is opt-in for this Blob
path only. Event admission and catalog writes are synchronous and can block.

Catalog-only epochs and live failed-write originals are retryable; real structural/
read errors block. No inventory can detect arbitrary external deletion of unindexed
events after exit. No power-loss, global FIFO, exact-once or unlimited-retention
guarantee. Synthetic tests do not establish real TLS/Azure or product acceptance.

The same quota and durable drops span all Blob epochs; resetting identity does not
multiply capacity. The direct initializer remains timer-free unless
`heartbeatVersion` is supplied. The additive bundle initializer owns startup/daily
heartbeats and reads expanded Info.plist values; missing configuration is locally
observable and disabled, in Debug and Release. Versions must be explicitly
allowlisted. No environment-only fallback, background wakeup guarantee, product
activation or release-version change is implied.
