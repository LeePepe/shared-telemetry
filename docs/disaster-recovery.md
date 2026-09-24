# Recovery assets and isolated drill proposal

Read this page to determine what a source checkout can recover, what needs separate data recovery, or what evidence an isolated drill would need. Source inspection: `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. This is an asset inventory and **proposed/unexecuted** drill, not a restore runbook, operation permission or successful recovery receipt. The accepted target is usable, measured recovery with independently reviewed isolation.

## Asset inventory

| Asset class | Existing source evidence and boundary | Recovery limitation |
|---|---|---|
| Source, manifests and consumer dependency pins | [Root manifest](../Package.swift), [Swift manifest](../sdks/swift/Package.swift), [Web manifest](../sdks/web/package.json), [Python manifest](../sdks/python/pyproject.toml); consumer pins belong to their own repositories | Git can recover committed source, not telemetry records or all consumer configuration/artifacts. Installed artifact availability and consumer pin recovery are not established here |
| Swift telemetry memory and batch files | [TelemetryQueue](../sdks/swift/Sources/LokiKit/TelemetryQueue.swift) and [LokiTelemetryService](../sdks/swift/Sources/LokiKit/LokiTelemetryService.swift); failed-send JSON batches in the configured store directory | Memory is not persisted at each enqueue. Default store is not per-endpoint; malformed files/write errors and replay duplicates remain possible |
| Swift optional log-sink persistence | [LokiLogSink](../sdks/swift/Sources/LokiKit/LokiLogSink.swift); bounded memory, optional caller-selected persistence file | Persistence happens during flush and is best effort; capacity truncation and crash windows remain. This is a different asset/format from telemetry batches |
| Web browser storage | [PersistentQueue](../sdks/web/src/queue.ts); shared `loki-web:queue` localStorage key when available | Not a per-client backup; quota/access errors, shared-key interference and removal-before-send can lose records |
| Web Node memory queue | Same queue with memory backend in ordinary Node environments | No demonstrated process-crash recovery; unreferenced timers do not keep the process alive |
| Python process-memory buffer | [LokiClient](../sdks/python/src/lokikit/client.py) | No durable replay; batches are removed before transmission, with the [canonical loss/async caveats](../sdks/README.md#python-baseline-caveats) |
| Loki backend state | Compose logical volume `loki_data`; [Loki config](../stack/loki-config.yaml) uses filesystem storage | Mutable backend data needs its own consistent backup; repository files do not contain that state |
| Grafana backend state | Compose logical volume `grafana_data` | Mutable Grafana database/settings are distinct from committed dashboards and provisioning |
| Committed dashboards and provisioning | [Dashboard files](../stack/grafana/dashboards/), [dashboard provisioning](../stack/grafana/provisioning/dashboards/dashboard.yaml), [datasource provisioning](../stack/grafana/provisioning/datasources/loki.yaml) | Recovering JSON/configuration is not restoring all Loki/Grafana state or proving dashboard usability |
| Separate analyzer assets | [Query/report tooling](../agents/project-analyzer/) | Committed tooling is source; any generated reports or external reporting state need a separate inventory. Not an SDK recovery dependency proven here |

TelemetryDeck is an external dependency/provider, not a Loki volume or one of these queue formats. Its service/account state and recovery guarantees were not inspected; Loki asset restoration cannot stand in for provider-specific evidence.

### Stack facts, not backup guarantees

[docker-compose.yml](../stack/docker-compose.yml) declares Loki `3.1.0`, Grafana `11.2.0`, loopback-bound host ports and separate logical volumes `loki_data` / `grafana_data`. These logical names are not verified physical resource IDs or isolation evidence. [loki-config.yaml](../stack/loki-config.yaml) declares filesystem storage, replication factor one and `auth_enabled: false`.

This describes a local configuration, not an authenticated production receiver, replication-based recovery or an approved backup. Grafana's UI authentication settings do not establish authentication for Loki ingestion. Actual deployment state, backup availability, backup consistency, retention guarantees, recovery point objective (RPO), recovery time objective (RTO) and restored usability are **unknown/unmeasured**. No credentials, production paths or operational commands are reproduced here.

## Proposed isolated drill

Every step below is **proposed/unexecuted**. Illustrations and fixtures would be synthetic and separately approved; source review alone performs none of the capture, restore, verification or cleanup operations.

1. **Select revision and fixtures.** Identify exact provider/consumer revisions, artifact/image identities, approved synthetic fixture IDs and expected counts/line formats. Inventory source assets, queue formats, dependency pins and backend resources; specify which are in scope and what recovery loss/time targets would be acceptable.
   **Completion criterion:** reviewed asset/fixture manifest with expected records and explicit exclusions. Real health, recording, financial or other personal payloads are excluded; goals are agreed, not retroactively inferred from results.
2. **Define the first isolated disposable target.** Independently verify endpoint configuration, storage namespaces, ports, volume identities, browser origin/profile where applicable and Swift persistence locations. Verify no overlap with live deployments, default queue locations or existing volumes. Existing/default Compose names and volumes are not safe isolation evidence; a project label alone is insufficient.
   **Completion criterion:** exact separately approved disposable resources and evidence of non-overlap, with source resources preserved. Ambiguous identity stops the proposed operation for review.
3. **Capture a consistent synthetic backup.** Establish the chosen consistency boundary for writers/in-flight batches and backend state. Capture the scoped synthetic assets with a manifest including revision/image identity, format, record inventory, timestamps and integrity digests; distinguish durable assets from memory-only observations. The consistency method itself requires review, not an assumed live-volume copy.
   **Completion criterion:** an integrity-checked backup matching the manifest and a documented consistency boundary; absent/uncaptured memory entries are recorded as limitations, not recoverable records.
4. **Restore into a second isolated target.** Independently verify the destination's resources and storage/port/endpoint separation from both the first target and all live resources. Restore only the reviewed assets, preserving the first target and captured backup intact.
   **Completion criterion:** destination identity and restored asset integrity match the scoped manifest, with source preservation recorded. This establishes reconstruction only, not usable service recovery.
5. **Verify readability and usable behavior.** Subsequently read back synthetic records and exercise the separately approved minimum consumer behavior against the restored target. Compare expected and observed IDs/counts/formats; distinguish Loki data, Grafana mutable state, dashboards and client replay. Record missing records, duplicates, elapsed time, compatibility and all failures.
   **Completion criterion:** observed usable behavior plus measured loss/time against pre-agreed criteria, or explicit failed/partial recovery. Successful checksum comparison alone cannot pass this step.
6. **Preserve evidence and scope cleanup.** Preserve the public-safe manifest, digests, observations, timestamps and failed attempts. Verify which exact resources are disposable and separately approved for cleanup; exclude source data and evidence. Cleanup is not implied by this document.
   **Completion criterion:** retained evidence and readback that only the explicitly approved disposable resources were removed, or a recorded reason cleanup was deferred.

## Evidence required for a later recovery claim

A later receipt needs the actual revision/artifact/image identities, approved resource manifest, fixture inventory, backup digests and consistency method, source/destination isolation evidence, reconstruction and usability results, missing/duplicate counts, elapsed time, compatibility, failures and exact cleanup outcome. RPO/RTO need measured loss and elapsed-time evidence against approved objectives, not merely successful startup.

Until that evidence exists:

- Git checkout recovery does not restore telemetry data.
- Dashboard/configuration recovery is not full Loki/Grafana state restoration.
- Memory queues have no demonstrated process-crash recovery.
- Persisted queues are not independent backups or exactly-once guarantees.
- An HTTP/flush attempt or readable backup does not prove restored consumer usability.
- Existing backup availability/consistency, RPO/RTO and restored usability remain unknown/unmeasured.

## Separate Workflow continuation boundary

Workflow-state continuation concerns platform-specific task/session state, dispatch routes, ownership, review and delivery handoffs. It requires separate platform-specific evidence; it is not covered by SDK queue replay, Git source recovery or stack restoration. This document changes no platform instructions, roles or authority and does not establish continuation success.

No restore, deletion, volume reset, service restart, credential handling, production cutover, SDK execution, Docker command, analyzer invocation or network check was performed for this authoring slice. Offline documentation checks are not recovery tests, and this proposal does not complete actual recovery acceptance.
