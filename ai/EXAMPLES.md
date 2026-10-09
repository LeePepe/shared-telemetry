# Executable Swift consumer

[examples/swift/Package.swift](examples/swift/Package.swift) defines a separate
remote SwiftPM consumer. Its [tests](examples/swift/Tests/ConsumerTests/ConsumerTests.swift)
use only public `LokiKit` APIs: event/no-op construction plus a bounded
`LokiLogSink` with an ephemeral URLSession and synthetic URLProtocol receiver.
The receiver never reaches a network endpoint. Tests verify redaction, numeric
context filtering, capacity overflow, failure requeue and successful drain.

```sh
python3 sdks/swift/scripts/external_consumer.py --revision <full-40-character-SHA>
```

The runner copies the fixture into a run-owned temporary directory, resolves
the remote immutable revision, checks matching shipped `ai/`, then runs macOS
build/test and an iOS simulator compile with isolated DerivedData. No local path
dependency, App launch, live TelemetryDeck initialization, real recording or
production endpoint is used. Temporary consumer/build files are removed after
the command; package-manager caches may be shared.

For the released baseline, run its matching tag0.1.0 checkout/fixture with
`--version 0.1.0`; the candidate Blob fixture cannot compile against that older
Interface. A revision test is not tag acceptance. Expected successful output is
`SWIFT_CONSUMER_OK`. This fixture covers the
listed public paths, not a real Loki write/readback, all adapters, platform
minimums, full D1, a product migration or complete 6DQ.

## Candidate Blob tracer

The candidate fixture also uses ordinary public imports for whole-event rejection,
explicit disabled admission, reset before first flush and recreation with old
identity/build preserved. A synthetic host Bundle also proves missing configuration
stays locally observable with a disabled heartbeat and no identity/store provisioning.
It inspects actual synthetic gzip bodies and request paths;
no internal store/control API or public fault-injection framework is used.
Supplementary provider tests attach internal timing observations to the real public
operations for pre-start and post-terminal arbitration cuts; those are distinct
from ordinary-import consumer proof, not manufactured receipts or live TLS tests.

These added tests require the unreleased candidate, not tag0.1.0. Resolve and run the
exact published candidate revision before claiming consumer validation. Extending
this fixture in source alone is not proof the external command or iOS compile ran.
