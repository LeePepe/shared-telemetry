# Swift integration

Use the canonical repository URL and one root SwiftPM dependency:
`.package(url: "https://github.com/LeePepe/shared-telemetry.git", exact: "0.1.0")`
(tag `v0.1.0`). The [consumer fixture](EXAMPLES.md) shows a complete manifest;
it pins a full revision.

The public product/module remains `LokiKit`. Platforms are iOS 26 and macOS 26,
Swift tools 6.2. Commit consumer `Package.resolved` according to its policy;
record the resolved TelemetryDeck version/revision, not just the provider's
`from: "2.0.0"` range. The dependency range is unchanged; candidate Blob additions
below are not present in released 0.1.0.

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

## Candidate Blob integration

Use only a reviewed immutable candidate containing `AzureBlobTelemetryService`.
Supply `containerURL`, `sasQuery`, `app`, `build`, `privacy`, `storeDirectory`,
`isEnabled` and `identityProvider` explicitly. Use a dedicated new Blob-only store,
not Loki's default queue or another Adapter's directory. One instance/task lifetime
holds the store lease. Policy fields/labels, app/build and UUID provenance belong
to trusted caller code/configuration, never incoming user content.

Direct construction is timer-free.
Caller schedules `flush`; `track` and
catalog changes synchronously perform local I/O. Provide identity on initial
creation/reset; valid reconstruction restores the catalog identity without calling
the provider. Disable before disconnecting, await the active flush's exit, and
retain pending files. An already-won terminal receipt may complete cleanup. Do not
erase the store, rotate old pending identities or treat reset as data deletion.
`maxDiskBytes` defaults to 50 MiB for the **whole Blob store**, not each reset.
Queue counters, oldest-batch eviction, oversize rejection and paired cleanup
apply across ordered epochs. The budget covers JSON plus Blob sidecars, not
catalog/ledger metadata, memory fallback or atomic-write transients.
See [USAGE](USAGE.md) for field and diagnostic scope.
