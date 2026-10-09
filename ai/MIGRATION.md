# Swift migration and rollback

Initial path: local `LokiKit` checkout → the same public module from a fixed
`shared-telemetry` revision. The repository URL/name changes; `import LokiKit`
does not. The original release baseline makes no runtime, platform or API change and
does not modify any product's dependency.

The later **unreleased queue-capacity change** adds a default 50 MiB disk-data
cap with a positive `maxDiskBytes` constructor override and `droppedEventCount`.
It preserves event JSON and Blob wire formats, but can discard oldest batches.
The loss ledger and all retained files form one single-owner store. Before
rolling back to a reader without this policy, resolve any pending eviction
cleanup using the capacity-aware SDK after storage becomes writable; otherwise
the older reader can replay logically dropped files. Do not discard the ledger
or mix old/new writers. Already evicted events cannot be recovered by rollback.
See the [queue contract](../sdks/swift/README.md#loki-event-telemetry) for accounting,
in-flight deferral and failed-persistence limits.

The public Blob candidate reuses this same quota across all identity/build epochs;
reset cannot multiply the 50 MiB default. Do not give an older unbounded Blob
candidate a capacity-aware store containing loss tombstones. Finish pending paired
eviction cleanup with the current reader before any separately reviewed rollback.
Bundle configuration and heartbeat are additive: adopt the standard host initializer
with explicit allowlisted app/build/version and consent. Missing plist settings
produce local disabled observability, not a fallback receiver. No actual SAS,
product pin, release version or legacy-store migration is selected here.

1. Record the old source SHA/resolution, consumer adapter, enabled/consent
   semantics, labels and persistence locations without copying private content.
2. Replace only the dependency source with the reviewed immutable candidate;
   resolve/record TelemetryDeck and read this checkout's contract.
3. Run the external fixture, then the actual consumer's build/tests and
   synthetic lifecycle/error/recovery journey. Keep event meanings and privacy
   filtering in the product; no unified-envelope migration is assumed.
4. Before activation, preserve the old pin/config and define queue disposition.
   Roll back by stopping producers/tasks, disconnecting the mirror, restoring
   the old pin/config and repeating the consumer checks.

SDK queue formats are not a versioned data-migration contract. Old batches may
replay; crashes/ambiguous responses can cause loss or duplicates. Reverting code
does not retract transmitted data. File conversion/deletion, retention, cloud
cutover and backend restore require separate authority. The provider fixture
does not prove any product's old→new→old rollback.

For consumers of the legacy released interfaces only, a candidate SHA pin can
be replaced with exact 0.1.0 (tag `v0.1.0`); confirm its resolved commit and rerun
version-mode external/consumer checks. That release does not contain the Blob
Interface. Blob candidate validation must use its reviewed immutable revision
and matching documentation; adoption of a future applicable approved release
requires new resolution and external/consumer checks, not a switch to 0.1.0.
Do not overwrite or delete an immutable release to repair consumers.

## Candidate Blob opt-in and rollback

The public Blob Interface is unreleased, not an API in tag0.1.0. Start with a new,
explicitly consented Blob-only directory and reviewed field/label/identity rules.
Do not copy legacy JSON into it or share its lease with another live owner. Existing
Loki/TelemetryDeck paths remain independently configured and are not retroactively
sanitized by this addition.

Reset only appends future-admission identity metadata; it never clears old data.
A failed reset pauses the current instance. After ending its tasks/lease, explicit
reconstruction from a valid last catalog has fresh readiness; an unpersisted failure
flag cannot survive restart. Unsafe historical content/read failures remain blocked
and retained, not automatically repaired. Stop producers, disable and await active
work before rollback; keep all unconfirmed epochs. Older code does not understand
this catalog layout, and reverting an exporter can remove privacy protection.
Migration/disposal and an actual product old→new→old drill require separate work.
