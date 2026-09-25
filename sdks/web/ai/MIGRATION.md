# Migration and rollback

Initial path: source/local-path `@leepepe/loki-web` 0.1.0 → an immutable packed
artifact from an approved revision. This provider slice changes packaging/docs
only, not runtime behavior or consumer dependencies.

1. Record the old source SHA, lockfile, labels, approved event fields, lifecycle
   wiring and storage mode. Do not capture secret values or real queued content.
2. Build/install the new exact tarball; record its SHA-256/integrity and source
   SHA. Validate version-bound docs and run the installed consumer fixture.
3. Preserve product event meanings/filtering. Validate the product's own
   success, rejection, shutdown and storage behavior in an isolated profile.
4. Roll back by stopping the new producer and reverting the consumer pin and
   adapter/config to the recorded prior revision; re-run the same checks.

There is no versioned persistence migration. `loki-web:queue` can contain old
events and may replay on construction. Do not promise exactly-once delivery,
safe arbitrary-version replay or automatic queue conversion. Do not delete
queued data without explicit consumer policy. Rolling back code cannot retract
sent records; backend retention/migration is a separate authorized operation.

The fixture proves package-level behavior, not any product's old→new→old path.
Each consumer PR owns its upgrade and rollback evidence. Never overwrite a
published tag or artifact to repair a bad version.
