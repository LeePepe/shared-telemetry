# Consumer onboarding checklist

Use this checklist when adding an SDK to a consumer or replacing an existing client. Source-reviewed baseline: `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. This is integration planning, not evidence that a consumer is installed, connected or tested. Accepted delivery targets remain distinct from the existing source.

All referenced examples in this candidate are **illustrative/source-reviewed, not executed**. Sections 1–3 support static planning; sections 4–5 describe proposed/unexecuted integration validation. Constructors can start timers, initialize external SDKs or create storage; running them is not a static check.

## 1. Match the consumer to a version

- [ ] Identify the consumer language, existing logging/telemetry abstraction and current dependency pin or local source revision.
- [ ] Read the [SDK index](../sdks/README.md) for the package entry point and declared requirements; read only the selected SDK's contract for public signatures.
- [ ] Record the exact resolved SDK revision/artifact and matching documentation revision. If either is missing or different, record the gap before planning code against it.
- [ ] Distinguish declarations from tested platforms using the [compatibility table](../sdks/README.md#compatibility-and-distribution). For Python, include the [older README caveats](../sdks/README.md#python-baseline-caveats).

**Completion criterion:** a recorded consumer, package/import name, resolution source, immutable revision and compatibility gaps; no inferred published release from a manifest version.

## 2. Select the integration boundary

- [ ] Locate the consumer-owned event naming, consent, redaction and low-cardinality label decisions. The accepted target leaves product semantics in the product; the [current Swift exception](architecture.md#current-versus-accepted-target) has not been extracted.
- [ ] Select the public interface: Swift event telemetry versus console/remote logging versus TelemetryDeck; Web client versus console logger; Python handler versus low-level client.
- [ ] Identify explicit endpoint/authentication configuration and a synthetic-only data set. The SDKs' Bearer capability does not establish receiver authentication; existing local stack defaults are not production guidance.
- [ ] Plan storage isolation, lifecycle ownership and failure handling from the chosen contract. Include timers/tasks, optional persistence, blocking calls, queue overflow, loss and duplicate risks.

**Completion criterion:** a consumer-owned wiring plan with approved synthetic fields, configuration sources, lifecycle owner and known limits. No new receiver, dashboard or analyzer dependency is implied.

## 3. Plan dependency wiring and rollback

- [ ] Swift: choose the root or nested manifest exposing `LokiKit`, not both; record the consumer's resolved revision and TelemetryDeck dependency resolution.
- [ ] Web: distinguish `src/index.ts` from the manifest's declared `dist` exports; `private: true` does not establish a registry artifact. Record how a separately approved candidate artifact would be supplied.
- [ ] Python: retain `from lokikit import LokiHandler, LokiClient` as the public import route; plan explicit constructor configuration. Do not adopt unpublished loss-counter/timeout APIs as baseline behavior.
- [ ] Use the [source-reviewed Swift example](../sdks/swift/README.md#loki-event-telemetry) or [Web example](../sdks/web/README.md#client-usage) only as an API illustration. No ready-to-run consumer fixture is validated here.
- [ ] Record the previous dependency/configuration and the proposed rollback from [AI-assisted usage](ai-usage.md#migration-and-rollback). Include already-sent records and persisted-queue compatibility, which a source rollback cannot undo.

**Completion criterion:** a dependency and wiring proposal with explicit missing artifact/example evidence, and a bounded rollback plan. This checklist performs no install, stack startup or registry update.

## 4. Proposed isolated integration verification

- [ ] Obtain separate scope for an isolated synthetic consumer, compatible receiver, and exact disposable resources. Review the [recovery isolation criteria](disaster-recovery.md#proposed-isolated-drill) before using persistence or stack volumes.
- [ ] Validate the actual pinned artifact and public imports, then the selected platform/runtime combination. Record tool versions and precise outcomes, including failed attempts.
- [ ] Compare expected synthetic records with receiver acceptance and minimal readback, not just `flush()` return. Check labels, line format, privacy filtering where implemented, invalid inputs, capacity, retry and shutdown behavior.
- [ ] Record missing/duplicate records, synchronous blocking effects, persistence behavior and teardown results. A dashboard appearing is not delivery proof.

**Completion criterion:** revision-bound, public-safe evidence for the selected consumer path, or explicit failures/gaps. **Status here: not run.** No SDK import/call, build, test, install, Docker, analyzer or network probe was used for this documentation slice.

## 5. Proposed removal or rollback verification

- [ ] Identify consumer registrations/tasks to disconnect: logging handler attachment, optional process-wide Swift sink, caller-owned tasks and Web lifecycle resources as applicable.
- [ ] Plan stopping production of new events before an attempted drain; distinguish that attempt from a delivery acknowledgment. Unsent records and persistent queues need an explicit disposition, not automatic deletion.
- [ ] In a separately approved isolated consumer, restore the previous dependency/configuration and verify expected behavior with synthetic data. Preserve source data and evidence; cleanup covers only explicitly approved disposable resources.

**Completion criterion:** observed rollback usability and known irreversible effects, or a documented inability to roll back safely. **Status here: proposed/unexecuted.** There are no stack/dashboard operations or destructive commands in this checklist.
