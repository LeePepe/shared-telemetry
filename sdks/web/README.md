# @leepepe/loki-web

Read this contract for TypeScript/JavaScript telemetry, queue behavior and browser/Node lifecycle integration. Existing facts are source-reviewed at `eff9c1712cd648ed0717e41183ad8bd7bf39cbea`. Examples are **illustrative/source-reviewed, not executed**; accepted upgrade targets and proposed verification do not describe a released implementation.

## Package status and public exports

[package.json](package.json) declares version `0.1.0`, Node `>=18`, no runtime dependencies and **`private: true`**. Package exports name `dist/index.js` (ESM), `dist/index.cjs` (CJS) and `dist/index.d.ts` (types); artifact existence, package installation and publication were not validated. An npm installation command would not establish availability. The repository rename to `shared-telemetry` leaves this package name unchanged.

[src/index.ts](src/index.ts) exports:

- Runtime: `LokiTelemetry`, `PrintLogger`, `LokiShipper`, `buildPushBody`, `PersistentQueue`, `STORAGE_KEY`.
- Types: `Logger`, `LogLevel`, `Labels`, `Props`, `StorageMode`, `TelemetryEvent`, `TelemetryOptions`, `LokiStream`, `LokiPushBody`.

Queue and shipper are public exports, not inaccessible internals. `ShipperOptions` is declared in the shipper source but is not re-exported by the package index. The API is not interchangeable with Swift despite similar naming. See [compatibility](../README.md#compatibility-and-distribution) for declared versus tested support.

## Client usage

Illustrative/source-reviewed, not executed. This reserved-domain endpoint is a placeholder. Construction starts a timer and can read/write browser storage; the example is not an offline test.

```typescript
import { LokiTelemetry, PrintLogger } from '@leepepe/loki-web';

const telemetry = new LokiTelemetry({
  endpoint: 'https://telemetry.example.invalid/loki/api/v1/push',
  labels: { app: 'sample-consumer', env: 'synthetic' },
  batchSize: 20,
  flushIntervalMs: 5000,
  maxQueueSize: 1000,
  storage: 'memory',
});

telemetry.track('sample.completed', { count: 1 });
telemetry.log('info', 'sample.started', { count: 1 });
await telemetry.flush(); // Attempt completion, not a delivery receipt.
telemetry.shutdown(); // Starts a fire-and-forget final attempt.

const logger = new PrintLogger('sample-consumer');
logger.info('sample.completed', { count: 1 }); // Console only.
```

`LokiTelemetry` has `log(...)` and `track(...)`, not `info(...)`; level helpers belong to `PrintLogger`.

### Options and methods

Source: [client.ts](src/client.ts) and [types.ts](src/types.ts).

| Option | Existing behavior/default |
|---|---|
| `endpoint` | Required nonempty string; not a full URL/security validation |
| `labels` | Default `{}`; constructor ignores reserved `event`/`level` keys with a warning and stringifies other values |
| `token` | Optional Bearer-header value |
| `batchSize` | `20`; enqueue threshold for triggering flush, not a maximum request batch size |
| `flushIntervalMs` | `5000`; timer delay, subject to lifecycle caveats below |
| `maxQueueSize` | `1000`; drop-oldest capacity |
| `storage` | `'auto'`; also `'localStorage'` or `'memory'` |

Numeric options have no comprehensive runtime validation in this baseline. `track(name, properties?)` creates an `event` stream label; `log(level, message, context?)` creates a `level` label. Levels are `debug`, `performance`, `info`, `warning`, `error`, `critical`. Properties/context use `Record<string, unknown>`; caller properties are spread after standard JSON fields and can overwrite line fields without changing corresponding stream labels. Circular or otherwise non-serializable values can throw synchronously during `JSON.stringify`.

`flush(): Promise<void>` takes all currently queued entries. If another attempt is in flight it waits for that attempt and returns, potentially leaving newer entries queued. Network/non-2xx failures are normally caught, requeued and warned about; a resolved promise is not proof of acceptance, persistence or readback. `shutdown(): void` stops scheduling/listeners, makes later `track`/`log` no-ops, and starts a final flush without awaiting it. It neither promises a complete drain nor removes persisted entries that remain after failure.

## Queue and lifecycle limits

Source: [queue.ts](src/queue.ts), [client.ts](src/client.ts), [shipper.ts](src/shipper.ts).

- Overflow removes oldest entries and warns. Requeueing a failed batch at the front can itself drop old entries when newer events occupy capacity.
- Persistence uses the shared key **`loki-web:queue`**, not an endpoint/client namespace. Multiple clients/tabs sharing storage can overwrite or replay each other's queue; isolation is not established. Loading checks for an array, not a validated event schema.
- `'auto'` uses available localStorage, otherwise memory. Explicit `'localStorage'` also falls back to memory when unavailable; quota/access/parse errors are swallowed. Persisted events are loaded on construction and schedule an immediate attempt.
- Taking a batch also removes it from persisted storage before transmission. A crash in flight can lose it; ambiguous responses/replay can duplicate it. Browser persistence is best effort, not an independent backup.
- Construction schedules a timer. Nonempty successful attempts schedule the normal delay; failed attempts schedule exponential backoff capped at 30 seconds. **An empty flush returns without scheduling another timer.** Thus an expired idle timer can leave later sub-threshold events pending until another trigger. Do not describe this as a guaranteed periodic drain.
- Browser listeners attempt flush on `pagehide` and `visibilitychange` to hidden. Beacon is used when available and no token is configured; a `true` result means browser acceptance for sending, not server delivery. Otherwise events are requeued and a fire-and-forget regular fetch is attempted. Fetch uses `keepalive: false`; unload survival is not guaranteed.

## Lower-level APIs and console logging

`PersistentQueue(maxSize, mode, onDrop?)` exposes `size`, `enqueue`, `requeueFront`, `takeBatch`, `drain`, `snapshot`. `drain` removes its stored queue; it is not a send operation. The shared storage and validation caveats still apply when bypassing the client.

`LokiShipper({endpoint, token?}).ship(events)` rejects on network failure or non-2xx response; unlike the client it does not implement requeueing. No explicit request timeout is configured. `shipBeacon(events)` returns a best-effort boolean. `buildPushBody(events)` groups prebuilt events by labels; these APIs accept the exported `TelemetryEvent` shape (`labels`, `tsNanos`, `line`), not Swift's event shape.

[PrintLogger](src/logger.ts) implements `Logger`, with `minimumLevel`, `log`, `debug`, `info`, `warning`, `error`, `critical`. Constructor defaults are empty subsystem and `'debug'`. Errors can add stack/error-name context. Console logging does not feed `LokiTelemetry`; there is no Web equivalent here of Swift's process-wide remote mirror.

## Browser and Node differences

The fetch path uses global `fetch` (Node 18+ declared; evergreen-browser support is an existing claim, not a tested result here). Ordinary Node environments use memory and lack DOM lifecycle hooks; a supplied localStorage-like global can change storage selection. Node timers are unreferenced where supported, allowing process exit with queued data. Browser delivery additionally depends on storage availability, lifecycle scheduling, receiver CORS and applicable security policy; none was tested here.

## Privacy and authentication

There is no general event/context redaction or consent gate. `PrintLogger` can print messages, arbitrary context and error stacks locally; remote telemetry serializes supplied fields. Consumer-controlled synthetic data and low-cardinality labels are the basis of the proposed examples, not a privacy guarantee.

`token` produces an `Authorization: Bearer …` header on fetch; beacon cannot add that header and is skipped when a token is present. This is not proof of authenticated reception or Grafana Cloud compatibility. The prior base64-token recipe is unsupported. Keep credential values out of examples and verify the actual receiver's contract separately.

For accepted target gaps and version-bound migration read [AI-assisted usage](../../docs/ai-usage.md); for proposed storage drills read [disaster recovery](../../docs/disaster-recovery.md). No build, SDK import/execution, test, install or live endpoint check accompanies this documentation candidate.
