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

After publication, repeat with `--version 0.1.0`; a revision test is not tag
acceptance. Expected final output: `SWIFT_CONSUMER_OK`. This fixture covers the
listed public paths, not a real Loki write/readback, all adapters, platform
minimums, full D1, a product migration or complete 6DQ.
