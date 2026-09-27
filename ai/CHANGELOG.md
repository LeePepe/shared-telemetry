# Swift release changes

## 0.1.0 — first release (Git tag v0.1.0)

- Ship a version-bound Swift consumer entry, registry/schema, integration and
  migration contract with the SwiftPM source checkout.
- Add public-product external tests for synthetic redaction, capacity and retry.
- Runtime API, platform requirements and dependency range remain unchanged.

First release, distributed from Git tag `v0.1.0` through SwiftPM:
`.package(url: "https://github.com/LeePepe/shared-telemetry.git", exact: "0.1.0")`.
Licensed under MIT (repository root `LICENSE`). Open target gaps
remain in [COMPATIBILITY.md](COMPATIBILITY.md).
