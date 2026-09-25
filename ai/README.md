# shared-telemetry Swift consumer contract

Release unit **LokiKit / SwiftPM**, candidate **0.1.0** (unreleased).
Read this contract from the exact resolved `shared-telemetry` checkout, not
floating `main`. Repository/module renaming is not an API migration.

| Task | Read |
| --- | --- |
| Install, wire or remove Swift | [INTEGRATION.md](INTEGRATION.md) |
| API, error/lifecycle and privacy facts | [USAGE.md](USAGE.md) |
| Public-product external fixture | [EXAMPLES.md](EXAMPLES.md) |
| Platform/dependency matrix | [COMPATIBILITY.md](COMPATIBILITY.md) |
| From/to migration and rollback | [MIGRATION.md](MIGRATION.md) |
| Machine discovery | [registry.json](registry.json), [schema](registry.schema.json) |
| Changes | [CHANGELOG.md](CHANGELOG.md) |

SwiftPM distributes this directory with the same source revision as the SDK;
these files are not resources bundled into an App. Locate them under the
actual `.build/checkouts/shared-telemetry/ai` (or Xcode package checkout),
matching the revision in `Package.resolved`. Missing/mismatched docs are a
consumer integration failure, not permission to resolve `latest`.

Other release units are [Web](../sdks/web/README.md) and
[Python](../sdks/python/README.md), each with its own artifact packaging and
evidence. This Swift contract does not imply those SDKs share its API or privacy
behavior. Documentation grants no production access or publishing authority.
