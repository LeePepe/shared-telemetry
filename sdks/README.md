# SDK index

Use this page to choose a language and match its contract to a consumer dependency. Source baseline: `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. Existing source, accepted upgrade targets and proposed verification are separate statuses; none of the examples or runtime combinations was executed for this documentation candidate.

## Entry points

| SDK | Package and public entry | Contract to read |
|---|---|---|
| Swift | `LokiKit` product and import; [root manifest](../Package.swift) or [nested manifest](swift/Package.swift), both using the same source | [Swift usage and limitations](swift/README.md) for telemetry, logging or TelemetryDeck integration |
| Web | `@leepepe/loki-web`; [src/index.ts](web/src/index.ts) exports the public API; package exports target `dist/index.js`, `dist/index.cjs`, `dist/index.d.ts` | [Web usage and limitations](web/README.md) for browser/Node lifecycle and queue behavior |
| Python | `lokikit`; [src/lokikit/__init__.py](python/src/lokikit/__init__.py) exports `LokiClient` and `LokiHandler` | Read [baseline caveats below](#python-baseline-caveats) before the [older Python README](python/README.md); its corrections are separately owned |

SDKs accept a configured receiver; the checked-in stack and analyzer are not demonstrated runtime prerequisites. For integration planning read [onboarding](../docs/onboarding-checklist.md); for version discovery and migration read [AI-assisted usage](../docs/ai-usage.md).

## Compatibility and distribution

| SDK | Manifest-declared requirements | Source version/distribution facts | Tested revision/results |
|---|---|---|---|
| Swift | Swift tools `6.2`; iOS `26`, macOS `26`; TelemetryDeck SwiftSDK dependency from `2.0.0` | `LokiKit` library; both manifests declare TelemetryDeck, even when choosing the Loki adapter | Not established in this review |
| Web | Node `>=18`; uses global `fetch` | [package.json](web/package.json) says `0.1.0`, `private: true`, no runtime dependencies; ESM/CJS/types paths are declarations, not validated artifacts | Not established in this review; evergreen-browser support is an existing documentation claim, not a tested matrix |
| Python | Python `>=3.10`, `aiohttp>=3.9` | [pyproject.toml](python/pyproject.toml) says `0.1.0`; no publication or installed-wheel validation established here | Not established in this review |

The inspected revision for every row is `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`, not a promise that floating branches or unpublished candidates share these facts. No deprecation schedule or tested cross-version migration is established here. A package version alone is not proof of publication. The accepted target is version-bound documentation plus validated consumer artifacts; those checks remain proposed/unexecuted.

## Python baseline caveats

This compatibility summary records the canonical source's current limits without editing or adopting a separate Python candidate. The [older README](python/README.md) has stale environment-variable guidance and does not adequately describe blocking/loss behavior; its examples and installation claims were not executed or validated here. Use the [client](python/src/lokikit/client.py) and [handler](python/src/lokikit/handler.py) at the pinned revision to resolve discrepancies.

- Configuration is explicit: `LokiClient(endpoint=..., labels=..., batch_size=..., flush_interval=..., token=...)`; `LokiHandler` takes the same arguments plus `level`. The SDK does **not** automatically read `LOKI_ENDPOINT` or `LOKI_TOKEN`. Defaults include batch size `20` and interval `5.0`; relying on defaults does not select an approved receiver.
- Construction starts a daemon timer. `push(line, extra_labels=None)`, `flush()` and `close()` are synchronous; threshold-triggered and manual flushing perform HTTP while holding the buffer lock. The timer is not a nonblocking guarantee for caller-triggered sends.
- `apush(line)` calls synchronous `push()`, so reaching the threshold can block an async caller. `aflush()` removes buffered entries before its `aiohttp` request; failures can propagate without requeueing.
- Synchronous transmission failures are swallowed after removal from the buffer. The existing synchronous request has a fixed five-second timeout; no configurable timeout parameter or loss-counter API exists in this baseline. An unpublished candidate is not a released fix.
- `push(..., extra_labels=...)` accepts but does not apply `extra_labels`. Client lines are caller-provided strings; the handler constructs JSON with logging fields and extra values, without a general redaction layer.
- `LokiHandler.client` exposes the underlying client. `flush()` and `close()` are attempts, not delivery receipts. There is no demonstrated durable replay, bounded overflow policy, process-crash recovery or lossless delivery guarantee.

## Cross-SDK boundaries

All three Loki paths construct `streams` with label sets and timestamp/line pairs, but their line contents differ: Swift telemetry uses event names or sorted `key=value` text; Web constructs event/log JSON; Python's handler constructs logging JSON while its client accepts raw lines. These are not a validated unified event envelope.

Bearer-header support is a sender capability, not evidence of receiver authentication or general Grafana Cloud compatibility. Redaction, consent, endpoint policy and data retention cannot be inferred from a shared package name. Compare the [Swift](swift/README.md#privacy-and-authentication) and [Web](web/README.md#privacy-and-authentication) paths before choosing an adapter; product-specific event meanings remain the consumer's responsibility under the accepted target, with the [existing Swift exception](../docs/architecture.md#current-versus-accepted-target) still present.
