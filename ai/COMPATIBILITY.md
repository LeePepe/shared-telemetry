# Swift compatibility

| Surface | Declared | Evidence boundary |
| --- | --- | --- |
| SwiftPM | Tools 6.2, product/module `LokiKit` | Root and nested manifests must agree |
| Platforms | iOS 26, macOS 26 | Host tests and generic iOS simulator compile; minimum OS/device behavior needs separate evidence |
| Dependency | TelemetryDeck SwiftSDK from 2.0.0 | Exact resolution is recorded by each consumer lockfile; no live adapter test is implied |
| AI resources | Root source checkout `ai/` | Immutable-revision/tag consumer resolver checks shipped files |
| Wire | Loki push outer shape | Different event/log inner formats; no unified schema version |

The repository has no established root license file; release/publication needs
Owner resolution. This work does not choose a license or platform expansion.
The dependency range is unchanged; no consumer may silently substitute a
different resolved version when reporting tested evidence.

Existing provider tests include one explicit opt-in live-Loki test that stays
skipped in ordinary runs. Mock URLProtocol tests do not count as that live test.
Event enqueue/flush ordering, unbounded event queue, legacy product-specific
event names, real receiver authentication/storage readback, four-metric coverage,
dependency/security scans and full D1 remain open or unmeasured. There is no
whole-SDK redaction claim and no complete 6DQ pass.

No earlier published release/deprecation period is established. Future breaking
changes need explicit from/to guidance and reviewed consumer pin upgrades.
