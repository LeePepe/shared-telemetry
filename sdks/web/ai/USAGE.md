# Public API and safety limits

Import the public API from `@leepepe/loki-web`.

- `LokiTelemetry(options)`: requires a nonempty endpoint; options include
  `labels`, `token`, `batchSize`, `flushIntervalMs`, `maxQueueSize` and `storage`
  (`auto`, `localStorage`, `memory`). Constructor labels `event`/`level` are
  ignored as reserved. Construction starts a timer and can load persisted data.
- `track(name, properties?)` and `log(level, message, context?)` enqueue JSON
  lines. Fields supplied by callers can overwrite similarly named generated
  JSON fields. Inputs are not a validated universal event envelope.
- `flush()` awaits an attempt, not confirmed receipt. Failure requeues the
  batch and schedules bounded exponential backoff (up to 30 seconds); it does
  not reject to signal delivery failure. Concurrent flush calls join the same
  in-flight attempt. Idle-timer behavior is covered only by its existing tests,
  not a claim of continuous periodic delivery under every lifecycle.
- `shutdown()` stops timers/listeners and initiates a final fire-and-forget
  flush. It is not awaitable and is not an end-to-end delivery guarantee.
- `LokiShipper.ship(events)` uses fetch and throws for transport/non-2xx
  results; `shipBeacon(events)` is best-effort and declines Bearer auth because
  Beacon cannot set the header. No fetch request timeout is implemented.
- `PersistentQueue(maxSize, mode, onDrop?)` is a bounded FIFO that drops oldest
  on overflow. Public methods: `size`, `enqueue`, `requeueFront`, `takeBatch`,
  `drain`, `snapshot`. Use memory storage for isolated tests.
- `buildPushBody(events)` groups Loki streams by labels. `STORAGE_KEY` is
  `loki-web:queue`; localStorage is origin-wide, not per-client. Multiple
  persistent clients can interfere. Persisted event input is not schema-checked.
- `PrintLogger`/`Logger` produce console output, not Loki telemetry. Error
  objects may expose message/stack; use approved synthetic or filtered data.

Types are listed in [registry.json](registry.json). The outer wire format is
Loki push v1; inner JSON is not a unified versioned cross-SDK schema.

There is no automatic redaction or strict validation of all label/event/option
values. The consumer must allow-list messages/fields and choose low-cardinality
labels. Never pass user text, recordings, transcripts, prompts, private health
or financial content, credentials, or arbitrary exception text. Missing schema
validation/redaction and real controlled Loki readback remain target gaps;
package verification does not waive them.
