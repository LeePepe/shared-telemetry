"""Synthetic I/O for the whole SDK suite, including handler/fixture teardown.

No timer starts a thread. No transport falls through to a real implementation.
Socket/DNS denial is a session-scoped backstop, not a replacement for the fakes.
"""

import socket
import threading
import urllib.request
from unittest.mock import MagicMock

import aiohttp
import pytest


class ControlledTimer:
    def __init__(self, interval, function, args=None, kwargs=None):
        self.interval = interval
        self.function = function
        self.args = args or ()
        self.kwargs = kwargs or {}
        self.daemon = False
        self.started = False
        self.cancelled = False
        self.fired = False

    def start(self):
        self.started = True

    def cancel(self):
        self.cancelled = True

    def fire(self):
        """Explicitly run a scheduled callback once; never wait for real time."""
        if self.started and not self.cancelled and not self.fired:
            self.fired = True
            self.function(*self.args, **self.kwargs)


class SyntheticResponse:
    def __init__(self, io):
        self.io = io
        self.exited = False
        self.exit_type = None
        self.raise_for_status = MagicMock(side_effect=io.response_status_error)

    async def __aenter__(self):
        if self.io.response_enter_hook is not None:
            await self.io.response_enter_hook()
        if self.io.response_entry_error is not None:
            raise self.io.response_entry_error
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        self.exited = True
        self.exit_type = exc_type
        return False


class SyntheticSession:
    def __init__(self, io):
        self.io = io
        self.closed = False
        self.entered = False
        self.exit_type = None
        self.response = SyntheticResponse(io)
        self.post = MagicMock(return_value=self.response)

    async def __aenter__(self):
        if self.io.session_entry_error is not None:
            raise self.io.session_entry_error
        self.entered = True
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        self.closed = True
        self.exit_type = exc_type
        return False


class SyntheticIO:
    def __init__(self):
        self.timers = []
        self.sessions = []
        self.response_enter_hook = None
        self.response_entry_error = None
        self.response_status_error = None
        self.session_entry_error = None
        self.urlopen = MagicMock(name="synthetic_urlopen")
        self.session_factory = MagicMock(
            name="synthetic_ClientSession", side_effect=self._session
        )

    def _session(self, *args, **kwargs):
        session = SyntheticSession(self)
        self.sessions.append(session)
        return session

    def _timer(self, *args, **kwargs):
        timer = ControlledTimer(*args, **kwargs)
        self.timers.append(timer)
        return timer

    def install(self, patcher):
        patcher.setattr(urllib.request, "urlopen", self.urlopen)
        patcher.setattr(aiohttp, "ClientSession", self.session_factory)
        patcher.setattr(threading, "Timer", self._timer)

    def close_clients(self):
        # Every SDK client registers its bound callback at construction, even
        # clients created by unchanged handler tests or other fixture teardown.
        clients = {timer.function.__self__ for timer in self.timers}
        for timer in self.timers:
            timer.cancel()
        try:
            for client in clients:
                client.close()
        finally:
            for timer in self.timers:
                timer.cancel()


@pytest.fixture(scope="session", autouse=True)
def network_guard():
    """Keep baseline fakes and socket denial active through suite teardown."""
    def deny_network(*args, **kwargs):
        raise AssertionError("Real network access is forbidden in SDK tests")

    with pytest.MonkeyPatch.context() as patcher:
        patcher.delenv("LOKI_ENDPOINT", raising=False)
        patcher.delenv("LOKI_TOKEN", raising=False)
        patcher.setattr(socket, "create_connection", deny_network)
        patcher.setattr(socket, "getaddrinfo", deny_network)
        patcher.setattr(socket.socket, "connect", deny_network)
        patcher.setattr(socket.socket, "connect_ex", deny_network)
        patcher.setattr(socket.socket, "sendto", deny_network)
        if hasattr(socket.socket, "sendmsg"):
            patcher.setattr(socket.socket, "sendmsg", deny_network)
        baseline = SyntheticIO()
        baseline.install(patcher)
        try:
            yield
        finally:
            baseline.close_clients()


@pytest.fixture(autouse=True)
def isolated_io(network_guard):
    """Fresh per-test controls; close clients before restoring baseline fakes."""
    with pytest.MonkeyPatch.context() as patcher:
        io = SyntheticIO()
        io.install(patcher)
        try:
            yield io
        finally:
            io.close_clients()
