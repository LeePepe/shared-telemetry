# SDK index

Use this page to choose a language and match its contract to a consumer dependency. Historical source baseline: `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. The current candidate also incorporates the Python loss-accounting and async-timeout delta from `852d7643bbb2c4fbed38018196a1a5c2c225e223`, distinguished below. Source behavior, accepted upgrade targets and verification evidence remain separate statuses; examples and combined runtime combinations remain unexecuted.

## Entry points

| SDK | Package and public entry | Contract to read |
|---|---|---|
| Swift | `LokiKit` product and import; [root manifest](../Package.swift) or [nested manifest](swift/Package.swift), both using the same source | [Swift usage and limitations](swift/README.md) for telemetry, logging or TelemetryDeck integration |
| Web | `@leepepe/loki-web`; [src/index.ts](web/src/index.ts) exports the public API; package exports target `dist/index.js`, `dist/index.cjs`, `dist/index.d.ts` | [Web usage and limitations](web/README.md) for browser/Node lifecycle and queue behavior |
| Python | `lokikit`; [src/lokikit/__init__.py](python/src/lokikit/__init__.py) exports `LokiClient` and `LokiHandler` | Read [baseline and current candidate caveats below](#python-baseline-caveats) with the [Python README](python/README.md) |

SDKs accept a configured receiver; the checked-in stack and analyzer are not demonstrated runtime prerequisites. For integration planning read [onboarding](../docs/onboarding-checklist.md). Swift version discovery/migration starts with the [version-bound contract](../ai/README.md); Web/Python use the installed package entries linked from their SDK READMEs. The older [AI-assisted usage note](../docs/ai-usage.md) is historical context.

## Compatibility and distribution

| SDK | Manifest-declared requirements | Source version/distribution facts | Tested revision/results |
|---|---|---|---|
| Swift | Swift tools `6.2`; iOS `26`, macOS `26`; TelemetryDeck SwiftSDK dependency from `2.0.0` | `LokiKit` library; both manifests declare TelemetryDeck, even when choosing the Loki adapter | Not established in this review |
| Web | Node `>=18`; uses global `fetch` | [package.json](web/package.json) says `0.1.0`, `private: true`, no runtime dependencies; ESM/CJS/types paths are declarations, not validated artifacts | Not established in this review; evergreen-browser support is an existing documentation claim, not a tested matrix |
| Python | Python `>=3.10`, `aiohttp>=3.9` | [pyproject.toml](python/pyproject.toml) says `0.1.0`; no SDK publication or installed-SDK-wheel validation established here | Source `852d7643…`: 42 synthetic SDK cases passed in the bounded hosted development run below; not combined PR-head or required-CI evidence |

The manifest/distribution facts above were inspected at historical baseline `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`; the Python source delta and its bounded test result are identified separately, not generalized to floating branches or the combined candidate. No deprecation schedule or tested cross-version migration is established here. A package version alone is not proof of publication. The accepted target is version-bound documentation plus validated consumer artifacts; those checks remain proposed/unexecuted.

## Python baseline caveats

At the historical baseline, Python had no loss-counter API and no explicit `aiohttp` total timeout. The current candidate incorporates source `852d7643bbb2c4fbed38018196a1a5c2c225e223`: loss accounting and an explicit async timeout, not a delivery redesign or released fix. The [Python README](python/README.md) describes that delta; its environment-variable table is reconciled to explicit constructor configuration. Its examples and installation claims remain unexecuted/unvalidated. Use the [client](python/src/lokikit/client.py) and [handler](python/src/lokikit/handler.py) at the selected revision to resolve discrepancies.

- Configuration is explicit: `LokiClient(endpoint=..., labels=..., batch_size=..., flush_interval=..., token=...)`; `LokiHandler` takes the same arguments plus `level`. The SDK does **not** automatically read `LOKI_ENDPOINT` or `LOKI_TOKEN`. Defaults include batch size `20` and interval `5.0`; relying on defaults does not select an approved receiver.
- Construction starts a daemon timer. `push(line, extra_labels=None)`, `flush()` and `close()` are synchronous; threshold-triggered and manual flushing perform HTTP while holding the buffer lock. The timer is not a nonblocking guarantee for caller-triggered sends.
- `apush(line)` calls synchronous `push()`, so reaching the threshold can block an async caller. `aflush()` removes buffered entries before its `aiohttp` request; failures can propagate without requeueing.
- Synchronous transport exceptions remain suppressed after removal from the buffer; preparation errors still propagate. The current read-only, thread-safe `dropped_entries` counter cumulatively counts detached entries without confirmed successful delivery, including preparation/transport failures and async cancellation, once per unsuccessful batch. It is local loss visibility, not proof of server-side loss; a timed-out request may have arrived. Later success does not reset it, and reads perform no I/O.
- The current `aflush()` explicitly uses `aiohttp.ClientTimeout(total=5.0)`; errors and cancellation still propagate. Scheduling/cancellation can delay completion, so this is not a hard five-second wall-clock guarantee. Synchronous `urlopen(..., timeout=5)` is unchanged and is not a whole-operation deadline. There is still no configurable timeout parameter, retry or requeue; each detached batch is attempted at most once.
- `push(..., extra_labels=...)` accepts but does not apply `extra_labels`. Client lines are caller-provided strings; the handler constructs JSON with logging fields and extra values, without a general redaction layer.
- `LokiHandler.client` exposes the underlying client. `flush()` and `close()` are attempts, not delivery receipts. There is no demonstrated durable replay, bounded overflow policy, process-crash recovery or lossless delivery guarantee.

The unchanged blocking behavior, missing bounded queues/backoff/retry and lack of authenticated receipt/storage verification mean this delta does not make Python ready to replace Financial's existing telemetry delivery implementation.

Hosted [run 35938736192, attempt 1](https://github.com/LeePepe/shared-telemetry/actions/runs/35938736192), job `107441645676`, passed 42 synthetic SDK cases (zero failures, errors or skips) against exact source `852d7643bbb2c4fbed38018196a1a5c2c225e223`. Workflow head `27e97449fc3fcd36552626d67c62ba70cd03022d` independently acquired that source; it is not the tested source revision and is not integrated here. This is bounded Python development evidence, not a test of the combined PR head, a required-check pass, consumer/packaging validation or full acceptance.

## Cross-SDK boundaries

All three Loki paths construct `streams` with label sets and timestamp/line pairs, but their line contents differ: Swift telemetry uses event names or sorted `key=value` text; Web constructs event/log JSON; Python's handler constructs logging JSON while its client accepts raw lines. These are not a validated unified event envelope.

Bearer-header support is a sender capability, not evidence of receiver authentication or general Grafana Cloud compatibility. Redaction, consent, endpoint policy and data retention cannot be inferred from a shared package name. Compare the [Swift](swift/README.md#privacy-and-authentication) and [Web](web/README.md#privacy-and-authentication) paths before choosing an adapter; product-specific event meanings remain the consumer's responsibility under the accepted target, with the [existing Swift exception](../docs/architecture.md#current-versus-accepted-target) still present.
