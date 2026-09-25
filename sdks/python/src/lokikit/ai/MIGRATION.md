# Migration and rollback

This first packaged-contract candidate does not change the Python runtime API.
The practical initial path is an old source/editable `lokikit` 0.1.0 checkout
to a wheel built from an approved fixed revision. No product migration has
been performed by this provider change.

1. Record the old source SHA, installed metadata, aiohttp version, endpoint
   configuration and consumer filtering. Do not include token values.
2. Build/record the new wheel digest, install in an isolated consumer and
   locate matching `ai/` resources. Run the packaged synthetic example.
3. Keep caller labels, event meanings and approved filtering unchanged. Check
   blocking `push/apush`, timer shutdown, failure/loss counters and duplicate
   handler registration before switching the product dependency.
4. For rollback, stop the new producer, restore the prior dependency/config
   and run the same consumer checks. Keep exactly one active producer.

There is no SDK-owned persistent queue to migrate. Buffered unsent entries can
be lost on process exit. Rolling back cannot retract delivered records, undo
retention changes or establish exactly-once semantics. Backend deletion,
retention, storage migration and live cutover need separate authority.

The wheel fixture proves provider distribution/HTTP behavior, not a consumer's
old→new→old workflow. Each product pin PR owns that evidence. Keep immutable
tags/artifacts; revert a consumer pin rather than replacing a release.
