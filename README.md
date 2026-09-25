# shared-telemetry

Shared telemetry SDKs and existing Loki/Grafana deployment assets. The canonical repository is [LeePepe/shared-telemetry](https://github.com/LeePepe/shared-telemetry) (repository ID `1213460359`), formerly LokiKit. The repository rename preserves the Swift `LokiKit`, Web `@leepepe/loki-web`, and Python `lokikit` package/import names; it is not an API migration or a release.

## Find the right document

| Task | Read |
|---|---|
| Understand modules, dependencies and existing exceptions | [Architecture](docs/architecture.md) |
| Consume or upgrade Swift with AI assistance; match docs to a dependency pin | [Version-bound Swift contract](ai/README.md); other SDKs: [SDK index](sdks/README.md) |
| Choose a language, entry point or compatibility baseline | [SDK index](sdks/README.md) |
| Plan consumer wiring and its later verification | [Onboarding checklist](docs/onboarding-checklist.md) |
| Inventory recoverable assets or propose an isolated drill | [Disaster recovery](docs/disaster-recovery.md) |

## Repository layout

| Path | Existing responsibility |
|---|---|
| [Package.swift](Package.swift) | Root Swift package entry; points at the source under `sdks/swift` |
| [sdks/swift](sdks/swift/README.md) | Logging and telemetry interfaces, Loki and TelemetryDeck adapters |
| [sdks/web](sdks/web/README.md) | TypeScript client, console logger, queue and shipper exports |
| [sdks/python](sdks/README.md#python-baseline-caveats) | Python logging handler and push client; older README has caveats |
| [stack](stack/) | Compose, Loki configuration, Grafana provisioning and dashboards |
| [agents/project-analyzer](agents/project-analyzer/) | Separate query/report tooling, not a required SDK runtime dependency |
| [scripts](scripts/) | Existing audit utilities, separate from SDK consumption |
| [skills](skills/) | Existing integration material; not proof of a packaged AI contract |

## Evidence and delivery status

**Existing implementation:** these documents are source-reviewed against `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. All three SDK source trees exist. Manifest versions and repository assets do not establish published packages, working consumer combinations, live deployments or successful recovery. The [compatibility table](sdks/README.md#compatibility-and-distribution) separates declarations from test evidence.

**Accepted target:** version-matched consumer contracts, product-local event semantics, and validated cross-SDK privacy, error and delivery behavior. A shared Loki push structure is present; a unified event envelope is not established. See [current versus target](docs/architecture.md#current-versus-accepted-target).

**Separate evidence required:** onboarding, product migration/rollback and recovery procedures need scoped execution. Existing README snippets remain illustrative; the [Swift public-product fixture](ai/EXAMPLES.md) is executable and verified separately per candidate. This is not release acceptance, complete cross-SDK contract delivery or T037 completion. It contains no operational quick start; stack operations require separate review.
