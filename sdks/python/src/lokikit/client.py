"""Low-level Loki push client with batching and async support."""

from __future__ import annotations

import json
import threading
import time
import urllib.request
from typing import Any

DEFAULT_ENDPOINT = "http://localhost:3100/loki/api/v1/push"


class LokiClient:
    """Batching client that pushes structured JSON logs to Loki.

    Parameters
    ----------
    endpoint : str
        Loki push API URL.
    labels : dict[str, str]
        Static labels attached to every log stream.
    batch_size : int
        Flush after this many buffered entries (default 20).
    flush_interval : float
        Delay before an automatic flush, scheduled after completion (default 5.0).
    token : str | None
        Optional Bearer token for Grafana Cloud / authenticated Loki.
    """

    def __init__(
        self,
        endpoint: str = DEFAULT_ENDPOINT,
        labels: dict[str, str] | None = None,
        batch_size: int = 20,
        flush_interval: float = 5.0,
        token: str | None = None,
    ) -> None:
        self.endpoint = endpoint
        self.labels = labels or {}
        self.batch_size = batch_size
        self.flush_interval = flush_interval
        self.token = token

        self._buffer: list[tuple[str, str]] = []  # (nano_ts, line)
        self._lock = threading.Lock()
        self._dropped_entries = 0
        self._timer: threading.Timer | None = None
        self._closed = False
        self._start_timer()

    # -- public API ----------------------------------------------------------

    @property
    def dropped_entries(self) -> int:
        """Cumulative entries discarded without confirmed successful delivery.

        A timeout or cancellation can leave remote delivery uncertain. This
        read-only count describes local loss, not proven server-side loss.
        """
        with self._lock:
            return self._dropped_entries

    def push(self, line: str, extra_labels: dict[str, str] | None = None) -> None:
        """Buffer a log line. Flushes automatically when batch_size is reached."""
        ts = str(int(time.time_ns()))
        with self._lock:
            self._buffer.append((ts, line))
            if len(self._buffer) >= self.batch_size:
                self._flush_locked()

    def flush(self) -> None:
        """Force-flush all buffered entries."""
        with self._lock:
            self._flush_locked()

    def close(self) -> None:
        """Flush remaining entries and stop the background timer."""
        self._closed = True
        if self._timer:
            self._timer.cancel()
        self.flush()

    # -- async helpers -------------------------------------------------------

    async def apush(self, line: str) -> None:
        """Async wrapper — delegates to sync push (I/O happens on flush)."""
        self.push(line)

    async def aflush(self) -> None:
        """Async flush using aiohttp."""
        import aiohttp

        with self._lock:
            entries = list(self._buffer)
            self._buffer.clear()
        if not entries:
            return
        delivered = False
        try:
            body = self._build_body(entries)
            headers = {"Content-Type": "application/json"}
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
            timeout = aiohttp.ClientTimeout(total=5.0)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(self.endpoint, json=body, headers=headers) as resp:
                    resp.raise_for_status()
            delivered = True
        finally:
            # Also accounts for cancellation, without changing propagation.
            if not delivered:
                with self._lock:
                    self._dropped_entries += len(entries)

    # -- internals -----------------------------------------------------------

    def _start_timer(self) -> None:
        if self._closed:
            return
        self._timer = threading.Timer(self.flush_interval, self._timer_flush)
        self._timer.daemon = True
        self._timer.start()

    def _timer_flush(self) -> None:
        self.flush()
        self._start_timer()

    def _flush_locked(self) -> None:
        entries = list(self._buffer)
        self._buffer.clear()
        if not entries:
            return
        delivered = False
        try:
            body = self._build_body(entries)
            data = json.dumps(body).encode()
            req = urllib.request.Request(
                self.endpoint,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            if self.token:
                req.add_header("Authorization", f"Bearer {self.token}")
            try:
                urllib.request.urlopen(req, timeout=5)
            except Exception:
                # Only transport exceptions remain best-effort/non-raising.
                pass
            else:
                delivered = True
        finally:
            # The caller already holds _lock; preparation failures still raise.
            if not delivered:
                self._dropped_entries += len(entries)

    def _build_body(self, entries: list[tuple[str, str]]) -> dict[str, Any]:
        return {
            "streams": [
                {
                    "stream": self.labels,
                    "values": [[ts, line] for ts, line in entries],
                }
            ]
        }
