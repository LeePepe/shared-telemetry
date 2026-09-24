---
layer: _root
support:
  - patterns: ["*.md", "sdks/README.md", "docs/**", "skills/**", ".claude/**"]
    reason: documentation, integration skill and agent configuration; checked by the contract audit, not a layer gate
  - patterns: [".github/**", ".githooks/**", "scripts/**", ".gitignore"]
    reason: CI, hooks, the verify entry and repository utilities; checked by the contract audit and workflow-lint
red_lines:
  - Dependencies point only in the direction listed in the table below; the SDKs never depend on each other.
  - Every tracked path resolves to exactly one layer or one support entry (no unmapped path, no overlap).
---

# shared-telemetry tech context

shared-telemetry (package and SDK name `LokiKit`) is the shared local telemetry
backend (Loki + Grafana) plus the client SDKs that push structured logs and
events to it. Three SDKs share one wire contract (Loki push API, JSON lines,
low-cardinality labels) but have no code dependency on each other.

| Layer | Responsibility | tech-context | depends_on |
|---|---|---|---|
| SwiftSDK | `LokiKit` Swift package (iOS/macOS 26): logger, Loki telemetry service, offline queue, privacy-filtered log sink, TelemetryDeck bridge | `sdks/swift/tech-context.md` | (none) |
| WebSDK | `@leepepe/loki-web` TypeScript SDK: batched client, beacon flush, logger | `sdks/web/tech-context.md` | (none) |
| PythonSDK | `lokikit` Python SDK: batching client and `logging.Handler` | `sdks/python/tech-context.md` | (none) |
| ProjectAnalyzer | Per-project Loki review agent (`agents/project-analyzer`): anomaly, regression and daily reports | `docs/architecture/project-analyzer/tech-context.md` | (none) |
| Stack | Docker Compose Loki + Grafana, provisioning and dashboards | `docs/architecture/stack/tech-context.md` | (none) |

The `depends_on` column must equal each leaf's frontmatter (the audit reports
`layer_table_drift`). External dependencies are described in the leaves, not in
`depends_on`: SwiftSDK uses TelemetryDeck SwiftSDK, PythonSDK uses aiohttp,
ProjectAnalyzer uses requests and PyYAML and talks to a Loki endpoint at runtime,
Stack uses the `grafana/loki` and `grafana/grafana` images.

The root `Package.swift` belongs to SwiftSDK: it re-exposes `sdks/swift` so that
consumers can use the repository root as an SPM path or URL dependency.

The ProjectAnalyzer and Stack leaves live under `docs/architecture/` so that the
analyzer and Grafana asset directories stay byte-for-byte unchanged.

## Consumers

- VoxPocket (Swift, via the repository root package).
- Financial frontend (`@leepepe/loki-web`, local path install).

Breaking SDK API changes need a coordinated consumer `adopt` PR in each consumer
repository. There is no release tag yet; consumers pin a commit SHA.
