# Architecture and implementation boundaries

Read this page to locate a change, understand a dependency direction or distinguish the historical implementation from accepted upgrade goals. The architecture snapshot below was inspected at `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`; it is not a current release inventory. For version selection and registry discovery, start with the [Swift release-unit contract](../ai/README.md); for its executable public-product fixture, see [Swift examples](../ai/EXAMPLES.md). Use the selected dependency's matching documents. This is descriptive task material, not a new layer policy, agent role or permission source.

## Current module map

| Boundary | Existing direction and responsibility | Source evidence |
|---|---|---|
| Swift package entries | Root `LokiKit` target points at `sdks/swift/Sources/LokiKit`; nested package uses that same source directory through SwiftPM defaults | [Root manifest](../Package.swift), [nested manifest](../sdks/swift/Package.swift) |
| Swift logging | Consumer → `Logger` / `PrintLogger` → console; optional process-wide mirror → `LokiLogSink` → HTTP and optional persistence | [Logger](../sdks/swift/Sources/LokiKit/Logger.swift), [PrintLogger](../sdks/swift/Sources/LokiKit/PrintLogger.swift), [sink](../sdks/swift/Sources/LokiKit/LokiLogSink.swift) |
| Swift event telemetry | Consumer → `TelemetryService`; alternatives are `NoopTelemetryService`, `LokiTelemetryService` and `TelemetryDeckService`. Loki implementation uses internal `TelemetryQueue` and Swift `LokiShipper` | [Interface](../sdks/swift/Sources/LokiKit/TelemetryService.swift), [Loki adapter](../sdks/swift/Sources/LokiKit/LokiTelemetryService.swift), [queue](../sdks/swift/Sources/LokiKit/TelemetryQueue.swift), [shipper](../sdks/swift/Sources/LokiKit/LokiShipper.swift) |
| Swift external adapter | `TelemetryDeckService` → TelemetryDeck SwiftSDK; both manifests declare the dependency | [TelemetryDeck adapter](../sdks/swift/Sources/LokiKit/TelemetryDeckService.swift) |
| Web | Consumer → exports in `src/index.ts`; `client.ts` → `queue.ts` / `shipper.ts`; `logger.ts` is a console path. Queue/shipper are also public exports | [Exports](../sdks/web/src/index.ts), [client](../sdks/web/src/client.ts), [queue](../sdks/web/src/queue.ts), [shipper](../sdks/web/src/shipper.ts), [logger](../sdks/web/src/logger.ts) |
| Python | Consumer imports from `lokikit`; `LokiHandler` → `LokiClient` → sync HTTP or async helper path | [Exports](../sdks/python/src/lokikit/__init__.py), [handler](../sdks/python/src/lokikit/handler.py), [client](../sdks/python/src/lokikit/client.py) |
| Deployment assets | Compose → Loki configuration and Grafana provisioning/dashboard files, with separate data volumes | [Stack manifest](../stack/docker-compose.yml), [Loki config](../stack/loki-config.yaml), [provisioning](../stack/grafana/provisioning/), [dashboards](../stack/grafana/dashboards/) |
| Query/report tooling | `agents/project-analyzer/run.py` → its own `lib` query, analysis and reporting modules. Its `LokiClient` is distinct from the Python SDK client | [Analyzer entry](../agents/project-analyzer/run.py), [query client](../agents/project-analyzer/lib/loki_client.py) |

These are dependency directions visible in source, not invented uniform layer numbers or a dependency checker already enforced by CI. SDKs construct requests to configured endpoints; neither the checked-in stack nor the analyzer is a required SDK runtime dependency established by this inspection. Analyzer/reporting operations are separate from consuming a client library.

## Terminology and contract ownership

- **Event** means a consumer-selected name and properties; meaning is not guaranteed by a shared method name. Swift and Web both expose a `TelemetryEvent` name but different shapes.
- **Log** means a level/message/context path. Console output, the Swift remote mirror and event transport have different filtering and lifecycle behavior.
- **Loki push structure** means streams containing labels and timestamp/line pairs. It is not a unified line schema: see [cross-SDK boundaries](../sdks/README.md#cross-sdk-boundaries).
- **Queue/persistence** means pending client data, not server retention, an independent backup or exactly-once delivery.
- **Receiver acceptance/readback** is separate from an SDK flush attempt. A nonthrowing API cannot substitute for measured receipt.

The SDK documents own signatures and behavior: [Swift](../sdks/swift/README.md), [Web](../sdks/web/README.md), and the [Python baseline caveats](../sdks/README.md#python-baseline-caveats) accompanying its separately owned older README. [Recovery](disaster-recovery.md) owns the asset inventory/proposed drill. Version selection and migration routing belong to the [Swift release-unit contract](../ai/README.md) and the Web/Python installed-package contracts reached through their SDK READMEs; [AI-assisted usage](ai-usage.md) is historical context. This division avoids duplicate API recipes in architecture and root entries.

## Current versus accepted target

| Accepted target | What is actually established at the inspected revision |
|---|---|
| Product-local event semantics with shared transport/contracts | [VoxPocketTelemetryEventNames.swift](../sdks/swift/Sources/LokiKit/VoxPocketTelemetryEventNames.swift) still exports product-specific names. This is an existing exception; no extraction or relocation is claimed or performed here |
| Cross-SDK envelope and validated schema/privacy/error behavior | Common Loki outer structure, differing event/log lines and privacy behavior. No validated unified envelope or universal redaction |
| Explicit bounded queue/retry/flush/loss contracts | Different implementations: Swift event and log-sink paths differ; Web has lifecycle/storage limits; Python has removal-before-send loss risks. Current SDK docs describe them, not a completed reliability upgrade |
| Version-matched AI-assisted consumption | The historical snapshot predates the versioned consumption assets. The released `v0.1.0` source includes the [Swift contract and registry/schema](../ai/README.md) and [executable external-consumer fixture](../ai/EXAMPLES.md). Their existence is not a fixture pass, artifact-validation result or completed product migration/rollback |
| Validated isolated recovery | An [asset inventory and drill proposal](disaster-recovery.md) only; backup availability, RPO/RTO and usable restore remain unknown/unmeasured |

The repository's canonical name is `LeePepe/shared-telemetry` (ID `1213460359`), while existing package/module and asset names remain unchanged. The name-only migration does not prove compatibility, publication or runtime delivery. Existing Grafana dashboards, analyzer assets and product-specific names remain in place; this documentation slice changes no product semantics.

## Development and verification map

| Question/change area | Inspect first | Later execution evidence, not established here |
|---|---|---|
| Swift public API or either Loki path | Selected [Swift contract](../sdks/swift/README.md), manifests and corresponding source | [Swift tests](../sdks/swift/Tests/LokiKitTests/) plus a matching external consumer; isolate endpoint/storage before execution |
| Web exports, client lifecycle or storage | [Web contract](../sdks/web/README.md), exports and source | [Web tests](../sdks/web/tests/), actual ESM/CJS/type artifacts and selected browser/Node consumers |
| Python integration or loss behavior | [Canonical caveats](../sdks/README.md#python-baseline-caveats), source and manifest; not an unpublished candidate | [Python tests](../sdks/python/tests/), installed-artifact consumer and loss/async verification |
| Stack or persisted data recovery | [Recovery inventory](disaster-recovery.md#asset-inventory) and exact deployment config | Separately approved isolated restore/readback, not a Git checkout or a dashboard screenshot |
| Query/report behavior | [Analyzer source directory](../agents/project-analyzer/) | Independently scoped tooling validation; not an SDK requirement |

Existing test files are discoverability pointers, not pass results or permission to execute them. The historical architecture review used static source comparison and offline document checks only; its SDK examples were **illustrative/source-reviewed, not executed**. The linked executable Swift fixture is a later asset, not an execution receipt recorded by this page. This page records no fresh runtime or consumer acceptance evidence. Final implementation versions still require reconciliation and independent review before delivery acceptance.
