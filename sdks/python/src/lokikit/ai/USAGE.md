# Public API and boundaries

Import `LokiClient` and `LokiHandler` from `lokikit`.

`LokiClient(endpoint, labels=None, batch_size=20, flush_interval=5.0, token=None)`
starts a daemon timer. Always supply an approved endpoint explicitly; the
default localhost endpoint is not a production recommendation. Constructors
do not read environment variables. Pass a token explicitly if the receiver
requires Bearer authentication. Never include credentials in labels or lines.

- `push(line, extra_labels=None)` buffers a string and may perform blocking
  HTTP I/O when the batch threshold is reached. `extra_labels` currently has
  no effect. Labels are constructor-wide, not per entry.
- `flush()` synchronously attempts delivery and empties the local buffer.
  Transport exceptions are swallowed and entries count as local discards;
  there is no retry/requeue or durable storage. Preparation errors can escape.
- `close()` stops the timer and attempts a final synchronous flush. Do not
  push after close; the API does not enforce post-close rejection.
- `apush(line)` calls synchronous `push` and can block; it is not a nonblocking
  producer. `aflush()` uses aiohttp with a 5-second total request timeout and
  propagates failure/cancellation. Removed entries are counted as discards
  unless delivery completes successfully. A timeout is not a hard wall-clock
  guarantee and may leave remote receipt uncertain.
- `dropped_entries` is a read-only cumulative local-discard counter, not a
  server-side loss measurement or end-to-end receipt.

`LokiHandler` accepts the same connection/batching arguments plus logging
`level`. Attach it to a product-owned logger; remove and close it on shutdown.
`handler.client` exposes the client. The handler serializes message, standard
record metadata and extra fields. It catches formatting/emission errors via
`handleError`; explicit `flush`/`close` can still expose preparation errors.

## Wire contract and safety limits

The outer request is the Loki push JSON object `streams[].{stream,values}`.
Each value is `[nanosecond_timestamp_string, line_string]`. `push` accepts
caller-prepared lines; the handler creates a JSON line. This does not establish
one versioned cross-SDK event envelope. Product event meanings stay in the
consumer; do not infer parity with Swift or Web line formats.

There is **no automatic content redaction, label/schema validation or strict
queue-capacity contract** in this Python version. The consumer must allow-list
messages/fields before calling it. Do not send audio, transcripts, prompts,
health or financial content, arbitrary exception text, or user input. Privacy,
invalid-input rejection, durable retry and unified-envelope requirements not
implemented here remain release-readiness gaps; documentation is not a waiver.
