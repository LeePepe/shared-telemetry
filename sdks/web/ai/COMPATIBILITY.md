# Compatibility

| Surface | Declared contract | Tested boundary |
| --- | --- | --- |
| Node | >=18 | Record actual Node version per candidate; host success is not minimum-version proof |
| Module loading | ESM, CommonJS, TypeScript declarations | Installed-tarball ESM type/runtime + CJS smoke |
| Browser | fetch; optional localStorage/Beacon | Existing happy-dom tests; no complete real-browser journey claimed |
| Runtime dependencies | None | Tarball manifest remains dependency-free |
| Wire | Loki push v1 outer structure | Synthetic fake-fetch body assertions, not server acceptance/readback |
| AI docs | filesystem files under package `ai/` | Actual installed tarball; not JSON ESM exports |

Licensed under MIT (the `shared-telemetry` repository root `LICENSE` file; the
package metadata also declares MIT).

No complete L1 coverage metrics, G2 vulnerability/secret audit, D1 concurrency/
crash isolation or L3 product rollback is established. Known runtime gaps
include cross-client localStorage collision, incomplete input/schema validation,
no fetch timeout, no automatic redaction and no unified inner event schema.
No 6DQ or overall release-readiness pass is claimed by packaging success.

0.1.0 is the first release, so no earlier deprecation period exists. Future
removals need a documented from/to migration and reviewed consumer upgrade.
