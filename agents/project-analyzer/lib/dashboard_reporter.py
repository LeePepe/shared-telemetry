"""Vendored thin copy of the shared DashboardReporter pattern.

Adapted from the agent-ops-dashboard project's agents/common/dashboard_reporter.py.
Best-effort: all network calls are logged but never raised, so the analyzer
keeps working even if the dashboard is down.

Persists {agent_id, api_key} in AGENT_OPS_STATE_DIR (~/.agent-ops/<name>.json).
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

import requests

log = logging.getLogger("dashboard-reporter")

DEFAULT_BASE_URL = os.environ.get(
    "AGENT_OPS_BASE_URL", "http://localhost:47823/api/v1"
)
STATE_DIR = Path(
    os.environ.get("AGENT_OPS_STATE_DIR", str(Path.home() / ".agent-ops"))
)


class DashboardReporter:
    """Best-effort reporter: .setup() once, then .heartbeat()/.record_task()."""

    def __init__(self, name: str, kind: str, description: str | None = None):
        self.name = name
        self.kind = kind
        self.description = description
        self.agent_id: str | None = None
        self.api_key: str | None = None
        self.enabled = False
        self._base_url: str = DEFAULT_BASE_URL

    def _state_path(self) -> Path:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        safe = self.name.replace("/", "_")
        return STATE_DIR / f"{safe}.json"

    def _headers(self) -> dict[str, str]:
        h: dict[str, str] = {"Content-Type": "application/json"}
        if self.api_key:
            h["Authorization"] = f"Bearer {self.api_key}"
        return h

    def setup(self, base_url: str | None = None) -> None:
        self._base_url = (base_url or DEFAULT_BASE_URL).rstrip("/")
        state_file = self._state_path()

        # Try to reuse persisted agent_id
        try:
            if state_file.exists():
                data = json.loads(state_file.read_text(encoding="utf-8"))
                self.agent_id = data.get("agent_id")
                self.api_key = data.get("api_key")
                # Verify with a heartbeat
                try:
                    self.heartbeat(status="running")
                    self.enabled = True
                    log.info("Reusing dashboard agent_id=%s", self.agent_id)
                    return
                except Exception:
                    self.agent_id = None
                    self.api_key = None
        except Exception as exc:
            log.warning("Failed to load reporter state: %s", exc)

        # Fresh register
        try:
            resp = requests.post(
                f"{self._base_url}/agents/register",
                json={"name": self.name, "kind": self.kind,
                      "description": self.description},
                timeout=10,
            )
            resp.raise_for_status()
            body = resp.json()
            self.agent_id = body["agent_id"]
            self.api_key = body.get("api_key")
            state_file.write_text(
                json.dumps({"agent_id": self.agent_id, "api_key": self.api_key}, indent=2),
                encoding="utf-8",
            )
            self.enabled = True
            log.info("Registered with dashboard: agent_id=%s", self.agent_id)
        except Exception as exc:
            log.warning("Dashboard register failed (continuing without): %s", exc)

    def heartbeat(self, status: str = "running", meta: dict | None = None) -> None:
        if not self.enabled or not self.agent_id:
            return
        try:
            requests.post(
                f"{self._base_url}/agents/{self.agent_id}/heartbeat",
                json={"status": status, **({"meta": meta} if meta else {})},
                headers=self._headers(),
                timeout=5,
            )
        except Exception as exc:
            log.debug("heartbeat failed: %s", exc)

    def record_task(self, kind: str, ref: str | None = None, count: int = 1,
                    payload: dict | None = None) -> None:
        if not self.enabled or not self.agent_id:
            return
        try:
            requests.post(
                f"{self._base_url}/agents/{self.agent_id}/tasks",
                json={"kind": kind, "ref": ref, "count": count,
                      **({"payload": payload} if payload else {})},
                headers=self._headers(),
                timeout=5,
            )
        except Exception as exc:
            log.debug("record_task(%s) failed: %s", kind, exc)
