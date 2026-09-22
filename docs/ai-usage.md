# AI-assisted consumer usage

Read this page when using AI assistance to integrate, change, upgrade or investigate a consumer of shared-telemetry. The source contract described here is `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. It describes an existing implementation and accepted delivery targets; proposed verification remains unexecuted.

“AI usage” means assistance consuming the library's public contract. It is not permission to transmit user data to an AI service. These documents are task material, not new agent instructions, runtime policy or operational authority. Product-owned semantics, data approval and operational permissions remain with their existing owners.

## Route by task

| Task | Read when needed | Useful outcome |
|---|---|---|
| New consumer integration | [SDK entry points](../sdks/README.md#entry-points), then [onboarding](onboarding-checklist.md) | Matching package/import and a scoped wiring/verification plan |
| Implement an API call or configuration change | Selected [Swift](../sdks/swift/README.md) or [Web](../sdks/web/README.md) contract; for Python start with [baseline caveats](../sdks/README.md#python-baseline-caveats) | Source-backed public signatures and relevant failure/lifecycle limits |
| Upgrade or replace a local implementation | [Compatibility](../sdks/README.md#compatibility-and-distribution), then [migration and rollback](#migration-and-rollback) | Explicit from/to pins, behavior differences and rollback constraints |
| Investigate missing records or unexpected output | Selected SDK lifecycle/privacy sections, then [architecture](architecture.md) to locate the path | A distinction between local output, queued data, attempted transmission and actual receipt |
| Assess crash/data recovery | [Recovery asset inventory](disaster-recovery.md#asset-inventory) and [proposed drill](disaster-recovery.md#proposed-isolated-drill) | Known asset boundaries and unmeasured recovery gaps |

The entry provides branches rather than requiring every consumer to read every SDK or operational asset. Detailed API facts remain in their language contract/source.

## Match source, docs and dependency

1. Identify the actual resolved dependency from the consumer manifest/lockfile or Swift package resolution. For a local checkout dependency, record its exact revision and any local divergence, not only its directory name.
   **Completion criterion:** package identity, resolved revision/artifact and consumer platform are recorded.
2. Locate documentation for that exact revision. This candidate covers only the baseline stated above; Web/Python `0.1.0` declarations alone cannot distinguish all local candidates or prove publication. The repository rename preserves existing imports and does not validate old URL redirects as a consumer integration strategy.
   **Completion criterion:** documentation and source version match, or the mismatch is explicitly reported before relying on examples.
3. Discover the public surface from [SDK entry points](../sdks/README.md#entry-points), then inspect only the relevant exports/signatures. Swift's queue/shipper are internal; Web's queue/shipper are exported. Python imports come from `lokikit`; its older README needs the canonical caveats.
   **Completion criterion:** each proposed call maps to an actual public API at the selected version, without borrowing APIs from unpublished work.
4. Separate declared requirements from observed support using the [compatibility table](../sdks/README.md#compatibility-and-distribution). Missing artifacts, inaccessible version-bound docs or absent test evidence are gaps, not reasons to silently use floating `main`/latest documentation.
   **Completion criterion:** unsupported assumptions are visible and later validation is scoped to the selected artifact/platform.

No registry resolver, package installation or network lookup is executed by this document.

## Examples and failure interpretation

The [Swift examples](../sdks/swift/README.md#loki-event-telemetry) illustrate event configuration and a separate console logger. The [Web example](../sdks/web/README.md#client-usage) illustrates `track`, `log`, attempted flush and shutdown. All are **illustrative/source-reviewed, not executed**. Python's older examples remain separately owned and unvalidated; consult [baseline caveats](../sdks/README.md#python-baseline-caveats) before using them.

Source review does not instantiate clients: constructors can start timers, initialize TelemetryDeck, create directories or touch browser storage. A parse-only result does not establish public import resolution, type correctness, delivery, privacy or shutdown safety. Those require separate matching execution evidence.

For a missing record, first identify the selected adapter and whether it was ever enqueued; then distinguish overflow, in-memory exit loss, persistence failure and a receiver outcome. SDK completion is not end-to-end receipt. A shared Loki outer structure does not make a Swift event line interchangeable with Web/Python JSON. Receiver authentication and cloud compatibility require receiver-specific evidence beyond a Bearer header.

## Migration and rollback

This is a **proposed/unexecuted** consumer migration outline, not a tested version-to-version recipe. The accepted target includes migration from old LokiKit/product clients toward shared contracts; the inspected source does not yet establish a unified envelope or completed product-semantics extraction.

1. **Inventory the old path.** Record old/new source or artifact pins, package/import names, event/log formats, labels, consent/filtering, lifecycle hooks and persistence locations. Include queries that depend on the old line format, without modifying analyzer/dashboard assets here.
   **Completion criterion:** an explicit from→to mapping and known incompatibilities; no assumption that a repository rename changes module names.
2. **Plan a narrow adapter change.** Retain consumer-owned event meanings and wrappers. Compare actual public interfaces, error/blocking behavior and credential configuration. Avoid duplicate producers during a proposed trial; accepted target features absent from the selected version remain gaps.
   **Completion criterion:** a scoped consumer diff proposal and synthetic expected records, with receiver/storage isolation defined.
3. **Propose validation against exact artifacts.** Follow [onboarding verification](onboarding-checklist.md#4-proposed-isolated-integration-verification) for public imports, compatibility, synthetic receipt/readback and failure cases. Format/schema changes require query compatibility evidence; no executed migration fixture exists in this slice.
   **Completion criterion:** later revision-bound evidence or an explicit hold, not a claim that illustrative examples pass.
4. **Plan rollback before activation.** Preserve the prior dependency pin and consumer configuration, identify registrations/tasks to disconnect and a disposition for unsent records. Reverting code cannot retract records already sent. Persisted data may replay or be unreadable across versions; any conversion, deletion or backend cutover needs separate approval and recovery evidence.
   **Completion criterion:** a known prior state and a separately verifiable rollback path, or an explicit statement that safe rollback is not established.
5. **Record the result when separately executed.** Capture exact versions, observed loss/duplicates, time, failures, rollback usability and approved cleanup. Release/deprecation claims need matching release evidence; none is inferred from this proposal.
   **Completion criterion:** a versioned consumer result, not provider-document completion alone.

## Equivalent AI-contract mapping and remaining gaps

| Contract concern | Current equivalent entry | Outstanding accepted target |
|---|---|---|
| Entry, compatibility, migration | This page plus the [SDK index](../sdks/README.md) | Validated immutable-version resolution and tested migration/rollback combinations |
| Public usage and errors | SDK READMEs; Python caveats in the index pending separately owned README correction | Reconciliation with final implementation candidates and complete cross-SDK contract verification |
| Integration | [Onboarding](onboarding-checklist.md) | Actual clean-consumer artifact installation, wiring and removal evidence |
| Examples | Existing documentation examples, explicitly illustrative | Executable consumer fixtures and matching compile/type/behavior results |
| Machine discovery | No versioned machine registry established in this slice | Versioned schema/registry resolving capabilities and documents to actual public APIs |
| Distribution | Source-relative links at the inspected checkout | Validated package contents or immutable, digest-bound document attachments and a resolver |

Web's package file list names `dist` and its README; that does not establish delivery of these root/docs pages. Python wheel/sdist document resolution and Swift resolved-checkout document discovery remain unvalidated. No packaged AI contract, FR-005 completion, T037 completion, release, full documentation acceptance or runtime recovery success is claimed. Independent review and final-version validation remain separate gates.
