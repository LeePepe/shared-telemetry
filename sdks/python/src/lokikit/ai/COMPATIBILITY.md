# Compatibility

| Surface | Declared contract | Validation boundary |
| --- | --- | --- |
| Python | >=3.10 | Run results name the tested interpreter; minimum Python is not implied by a newer host pass |
| aiohttp | >=3.9 | Used by `aflush`; installed version must be captured by the consumer |
| Package/import | distribution `lokikit`, imports `LokiClient`, `LokiHandler` | Wheel consumer, not editable install |
| Wire | Loki push outer format | Inner lines are consumer strings/handler JSON; no unified event schema version |
| Auth | Optional explicit Bearer token | Loopback success/rejection fixture; receiver-specific production authentication unverified |
| AI resources | `lokikit/ai` within wheel and sdist | `importlib.resources`, registry/package version equality and artifact inspection |

Licensed under MIT (the `shared-telemetry` repository root `LICENSE` file; the
package metadata also declares MIT).

The existing Python test suite covers sync/async local loss accounting, timers
and logging paths with test doubles. The packaged fixture covers the synchronous
HTTP client and handler. A real controlled Loki write/readback, asynchronous
installed-package journey, schema/input rejection and redaction are not proved
by those checks. Four-metric coverage, full G2 scanning and D1 failure/concurrency
isolation remain unmeasured. No complete 6DQ pass is claimed.

0.1.0 is the first release, so no earlier deprecation period exists. Future
breaking changes require an explicit migration and consumer upgrade; no
compatibility with an untested old client is inferred.
