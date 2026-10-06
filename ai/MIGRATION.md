# Swift migration and rollback

Initial path: local `LokiKit` checkout → the same public module from a fixed
`shared-telemetry` revision. The repository URL/name changes; `import LokiKit`
does not. This provider slice makes no runtime, platform or API change and
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

Switch a candidate SHA pin to exact 0.1.0 (tag `v0.1.0`), confirm its resolved
commit and rerun version-mode external/consumer checks.
Do not overwrite or delete an immutable release to repair consumers.
