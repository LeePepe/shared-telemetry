# Swift integration

Use the canonical repository URL and one root SwiftPM dependency. While there
is no release, pin a reviewed full commit SHA. The [consumer fixture](EXAMPLES.md)
provides a complete manifest. After an approved first tag, use
`.package(url: "https://github.com/LeePepe/shared-telemetry.git", exact: "0.1.0")`;
that is a future release instruction, not a published-version claim.

The public product/module remains `LokiKit`. Platforms are iOS 26 and macOS 26,
Swift tools 6.2. Commit consumer `Package.resolved` according to its policy;
record the resolved TelemetryDeck version/revision, not just the provider's
`from: "2.0.0"` range. No API/dependency-range change is made here.

Start with `NoopTelemetryService` until the consumer's consent/configuration is
approved. Inject endpoint, labels, credentials and isolated storage explicitly
into the selected adapter. Constructing TelemetryDeck initializes its SDK even
when disabled; do not instantiate it in generic tests. Do not use default event
storage in tests or assume endpoints namespace persisted data.

For a log mirror, inject a fixed-message allow-list, numeric context keys,
positive capacity, optional consumer-owned persistence URL and URLSession.
Keep/cancel the task returned by `LokiLogSink.start`. A PrintLogger remote sink
is process-wide; configure/disconnect it deliberately. Console output and event
telemetry require separate filtering.

Run the external public-API fixture, then the consumer's own lifecycle/error,
consent, platform and controlled-receiver checks. For removal, cancel owned
tasks and disconnect the mirror before reverting the pin. Do not erase queue
files or backend data without an approved consumer disposition.
