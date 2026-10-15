# Loki Web consumer contract

Package `@leepepe/loki-web`, released **0.2.0** (Git tag `v0.2.0`).
ESM and CommonJS with TypeScript declarations. Released as an npm tarball
built from repository tag `v0.2.0`; no npm registry publication.

| Task | Read |
| --- | --- |
| Install or remove | [INTEGRATION.md](INTEGRATION.md) |
| API/errors/privacy | [USAGE.md](USAGE.md) |
| Installed-tarball example | [EXAMPLES.md](EXAMPLES.md) |
| Runtime/dependencies | [COMPATIBILITY.md](COMPATIBILITY.md) |
| Upgrade/rollback | [MIGRATION.md](MIGRATION.md) |
| Machine discovery | [registry.json](registry.json), [schema](registry.schema.json) |
| Changes | [CHANGELOG.md](CHANGELOG.md) |

`ai/` is included in the npm tarball. Read it relative to the actual installed
package root (`node_modules/@leepepe/loki-web/ai`), after confirming the lockfile
integrity and package/registry version match. It is filesystem data, **not an
ESM export**; the export map intentionally exposes only the public SDK entry.
Never fall back to floating `main` docs when the installed files are missing.

This contract grants no new permission to collect content, transmit production
telemetry, publish packages or change consumer policy.
