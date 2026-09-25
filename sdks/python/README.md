# LokiKit Python SDK

Python logging handler that ships structured JSON logs to Grafana Loki.
Works with any Python 3.10+ project — FastAPI, Django, CLI tools, scripts.

## Install

```bash
pip install -e sdks/python/          # from LokiKit root
# or
pip install lokikit                  # once published
```

## Quick Start

```python
import logging
from lokikit import LokiHandler

handler = LokiHandler(
    endpoint="http://localhost:3100/loki/api/v1/push",
    labels={"app": "my-api", "env": "dev"},
    batch_size=20,
    flush_interval=5.0,
)

logger = logging.getLogger("my-api")
logger.addHandler(handler)
logger.setLevel(logging.DEBUG)

logger.info("Server started", extra={"port": 8000})
logger.error("Request failed", extra={"status": 500, "path": "/api/data"})
```

## FastAPI Integration

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from lokikit import LokiHandler
import logging

handler = LokiHandler(
    labels={"app": "my-fastapi", "env": "dev"},
)
logging.getLogger().addHandler(handler)
logging.getLogger().setLevel(logging.INFO)

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    handler.close()  # flush on shutdown

app = FastAPI(lifespan=lifespan)
```

## Low-Level Client

```python
from lokikit import LokiClient

client = LokiClient(
    labels={"app": "script", "env": "dev"},
    batch_size=50,
)
client.push('{"event": "processed", "count": 42}')
client.close()  # flush remaining
```

## Async Support

```python
from lokikit import LokiClient

client = LokiClient(labels={"app": "async-worker"})
await client.apush("async log line")
await client.aflush()  # uses aiohttp
```

`aflush()` now explicitly uses `aiohttp.ClientTimeout(total=5.0)`. Async
preparation/transport errors and cancellation still propagate to the caller.
Cancellation and event-loop scheduling can delay completion: this is not a hard
five-second wall-clock guarantee. `apush()` still calls synchronous `push()` and
can block when a batch triggers a synchronous flush.

## Delivery and Loss Accounting

`client.dropped_entries` is a read-only, thread-safe integer, initially zero and
cumulative for that client's lifetime. It counts entries removed from the local
buffer without confirmed successful delivery, including preparation failures,
transport failures and cancellation after an async batch is detached. It is not
proof of server-side loss: a timed-out or cancelled request may have reached Loki.
Later success does not reset the counter; empty flushes do not change it.

```python
client.flush()
locally_discarded = client.dropped_entries
```

Reading the counter performs no network I/O, logging or background work. The
counter retains no payloads or exception text and invokes no diagnostic callback.
Each detached batch is attempted at most once, with **no retries or requeue**.
Synchronous transport exceptions remain suppressed (best effort); synchronous
preparation errors still propagate. Async failures still propagate. All these
unsuccessful detached batches are counted once.

The default batch trigger is 20 entries, not a validated queue-size or byte-cap
guarantee. Synchronous requests retain `urlopen(..., timeout=5)`, which is not a
five-second whole-operation deadline. The default timer delay remains five
seconds, with the next timer scheduled after flush completion. `close()` cancels
the timer and performs a final synchronous flush; it adds no join, drain loop or
shutdown deadline.

This is loss visibility, not reliable delivery or authenticated receipt/storage
verification. Bounded queues, backoff/retry and non-blocking async enqueue remain
unresolved; this slice does not make the SDK ready to replace Financial's
existing telemetry delivery implementation.

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `endpoint` | `http://localhost:3100/loki/api/v1/push` | Loki push URL |
| `labels` | `{}` | Static labels for the log stream |
| `batch_size` | `20` | Flush after N buffered entries |
| `flush_interval` | `5.0` | Delay in seconds; next timer starts after flush completion |
| `token` | `None` | Bearer token for authenticated Loki |

## Environment Variables

| Variable | Purpose |
|---|---|
| `LOKI_ENDPOINT` | Not read automatically by the SDK; callers must explicitly read any approved environment configuration and pass `endpoint=` to `LokiClient` or `LokiHandler` |
| `LOKI_TOKEN` | Not read automatically by the SDK; callers must explicitly read any approved environment configuration and pass `token=` to `LokiClient` or `LokiHandler` |
# Version-bound AI contract

The packaged consumer entry is [`src/lokikit/ai/README.md`](src/lokikit/ai/README.md).
Installed wheels expose the same files through `importlib.resources.files("lokikit").joinpath("ai")`.
See that entry for public API limits, executable synthetic examples and migration.
