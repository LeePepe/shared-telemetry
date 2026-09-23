"""Synthetic success/loss tests; no real transports, timers or timeout waits."""

import asyncio
import json
import socket
import threading
import urllib.error
from unittest.mock import patch

import aiohttp
import pytest

from lokikit.client import LokiClient


ENDPOINT = "https://telemetry.invalid/loki/api/v1/push"
TOKEN = "synthetic-test-token"


def make_client(**kwargs):
    return LokiClient(endpoint=ENDPOINT, **kwargs)


def enqueue(client, count):
    for index in range(count):
        client.push(f"synthetic-entry-{index}")


def assert_async_timeout(io, count=1):
    assert io.session_factory.call_count == count
    for call in io.session_factory.call_args_list:
        assert call.args == ()
        timeout = call.kwargs["timeout"]
        assert isinstance(timeout, aiohttp.ClientTimeout)
        assert timeout.total == 5.0


def sync_error(kind):
    if kind == "connection":
        return urllib.error.URLError("synthetic connection failure")
    if kind == "timeout":
        return TimeoutError("synthetic timeout")
    return urllib.error.HTTPError(ENDPOINT, int(kind), "synthetic HTTP", {}, None)


def async_error(kind):
    if kind == "connection":
        return aiohttp.ClientConnectionError("synthetic connection failure")
    if kind == "timeout":
        return asyncio.TimeoutError("synthetic timeout")
    return aiohttp.ClientResponseError(
        request_info=None, history=(), status=int(kind), message="synthetic HTTP"
    )


def test_build_body():
    client = make_client(labels={"app": "synthetic"})
    assert client._build_body([("1000", "hello"), ("2000", "world")]) == {
        "streams": [{
            "stream": {"app": "synthetic"},
            "values": [["1000", "hello"], ["2000", "world"]],
        }]
    }


@pytest.mark.parametrize("asynchronous", [False, True])
def test_success_preserves_wire_body_and_headers(isolated_io, asynchronous):
    client = make_client(labels={"app": "synthetic"}, token=TOKEN)
    with patch("lokikit.client.time.time_ns", side_effect=[1000, 2000]):
        assert client.push("hello") is None
        assert client.push("world") is None
    assert client._buffer == [("1000", "hello"), ("2000", "world")]
    expected = {"streams": [{
        "stream": {"app": "synthetic"},
        "values": [["1000", "hello"], ["2000", "world"]],
    }]}
    if asynchronous:
        assert asyncio.run(client.aflush()) is None
        assert_async_timeout(isolated_io)
        session = isolated_io.sessions[0]
        session.post.assert_called_once_with(
            ENDPOINT, json=expected,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"},
        )
        session.response.raise_for_status.assert_called_once_with()
        assert session.closed and session.response.exited
        isolated_io.urlopen.assert_not_called()
    else:
        assert client.flush() is None
        isolated_io.urlopen.assert_called_once()
        request = isolated_io.urlopen.call_args.args[0]
        assert request.full_url == ENDPOINT
        assert request.method == "POST"
        assert json.loads(request.data) == expected
        assert request.get_header("Content-type") == "application/json"
        assert request.get_header("Authorization") == f"Bearer {TOKEN}"
        assert isolated_io.urlopen.call_args.kwargs == {"timeout": 5}
        isolated_io.session_factory.assert_not_called()
    assert client._buffer == []
    assert client.dropped_entries == 0
    client.close()


def test_empty_flush_close_and_counter_read_have_no_side_effects(isolated_io, capsys, caplog):
    client = make_client()
    timers_before = tuple(isolated_io.timers)
    for _ in range(3):
        assert type(client.dropped_entries) is int
        assert client.dropped_entries == 0
        assert client.flush() is None
        assert asyncio.run(client.aflush()) is None
    with pytest.raises(AttributeError):
        client.dropped_entries = 10
    assert tuple(isolated_io.timers) == timers_before
    isolated_io.urlopen.assert_not_called()
    isolated_io.session_factory.assert_not_called()
    assert capsys.readouterr() == ("", "")
    assert not caplog.records
    client.close()
    client.close()
    assert client.dropped_entries == 0
    isolated_io.urlopen.assert_not_called()
    isolated_io.session_factory.assert_not_called()


@pytest.mark.parametrize("kind", ["connection", "timeout", "401", "500"])
def test_sync_failures_count_once_without_retry(isolated_io, kind):
    client = make_client()
    isolated_io.urlopen.side_effect = sync_error(kind)
    enqueue(client, 2)
    assert client.flush() is None
    assert client.dropped_entries == 2
    assert client._buffer == []
    client.flush()
    client.close()
    client.close()
    assert client.dropped_entries == 2
    isolated_io.urlopen.assert_called_once()
    assert isolated_io.urlopen.call_args.kwargs == {"timeout": 5}


@pytest.mark.parametrize("kind", ["connection", "timeout", "401", "500"])
def test_async_failures_count_once_and_propagate(isolated_io, kind):
    client = make_client()
    error = async_error(kind)
    if kind in {"401", "500"}:
        isolated_io.response_status_error = error
    else:
        isolated_io.response_entry_error = error
    enqueue(client, 3)
    with pytest.raises(type(error)) as raised:
        asyncio.run(client.aflush())
    assert raised.value is error
    assert client.dropped_entries == 3
    assert client._buffer == []
    assert_async_timeout(isolated_io)
    session = isolated_io.sessions[0]
    session.post.assert_called_once()
    assert session.closed
    assert session.exit_type is type(error)
    asyncio.run(client.aflush())
    client.flush()
    client.close()
    client.close()
    assert client.dropped_entries == 3
    assert_async_timeout(isolated_io)
    isolated_io.urlopen.assert_not_called()


@pytest.mark.parametrize("asynchronous", [False, True])
def test_cumulative_losses_survive_later_success(isolated_io, asynchronous):
    client = make_client()
    error = TimeoutError("synthetic timeout")
    isolated_io.urlopen.side_effect = error
    isolated_io.response_entry_error = error
    for size, total in [(2, 2), (3, 5)]:
        enqueue(client, size)
        if asynchronous:
            with pytest.raises(TimeoutError):
                asyncio.run(client.aflush())
        else:
            client.flush()
        assert client.dropped_entries == total
    isolated_io.urlopen.side_effect = None
    isolated_io.response_entry_error = None
    enqueue(client, 1)
    if asynchronous:
        asyncio.run(client.aflush())
        assert_async_timeout(isolated_io, count=3)
        isolated_io.urlopen.assert_not_called()
    else:
        client.flush()
        assert isolated_io.urlopen.call_count == 3
    assert client.dropped_entries == 5
    client.close()
    assert client.dropped_entries == 5


@pytest.mark.parametrize("path", ["batch", "explicit", "timer", "close"])
@pytest.mark.parametrize("fails", [False, True])
def test_sync_flush_paths_account_consistently(isolated_io, path, fails):
    client = make_client(batch_size=2 if path == "batch" else 20)
    first_timer = isolated_io.timers[0]
    assert first_timer.interval == 5.0
    assert first_timer.started and first_timer.daemon
    if fails:
        isolated_io.urlopen.side_effect = TimeoutError("synthetic timeout")
    enqueue(client, 2)
    if path == "explicit":
        client.flush()
    elif path == "timer":
        def respond_before_reschedule(*args, **kwargs):
            assert len(isolated_io.timers) == 1
            if fails:
                raise TimeoutError("synthetic timer timeout")

        isolated_io.urlopen.side_effect = respond_before_reschedule
        first_timer.fire()
        assert len(isolated_io.timers) == 2
        assert isolated_io.timers[-1].interval == 5.0
        first_timer.fire()  # A controlled timer fires only once.
    elif path == "close":
        client.close()
    assert client.dropped_entries == (2 if fails else 0)
    isolated_io.urlopen.assert_called_once()
    client.close()
    client.close()
    for timer in isolated_io.timers:
        assert timer.cancelled or timer.fired
        timer.fire()
    assert client.dropped_entries == (2 if fails else 0)
    isolated_io.urlopen.assert_called_once()


def test_sync_base_exception_is_not_newly_suppressed(isolated_io):
    client = make_client()
    error = asyncio.CancelledError("synthetic cancellation")
    isolated_io.urlopen.side_effect = error
    enqueue(client, 2)
    with pytest.raises(asyncio.CancelledError) as raised:
        client.flush()
    assert raised.value is error
    assert client.dropped_entries == 2
    client.close()
    assert client.dropped_entries == 2
    isolated_io.urlopen.assert_called_once()


def test_default_batch_trigger_remains_twenty(isolated_io):
    client = make_client()
    enqueue(client, 19)
    isolated_io.urlopen.assert_not_called()
    client.push("synthetic-twentieth")
    isolated_io.urlopen.assert_called_once()
    assert client.dropped_entries == 0


def test_apush_still_uses_sync_batch_flush(isolated_io):
    client = make_client(batch_size=1)
    isolated_io.urlopen.side_effect = TimeoutError("synthetic timeout")
    assert asyncio.run(client.apush("synthetic-entry")) is None
    assert client.dropped_entries == 1
    isolated_io.urlopen.assert_called_once()
    isolated_io.session_factory.assert_not_called()


@pytest.mark.parametrize("stage", ["body", "serialization", "request", "header"])
def test_sync_preparation_errors_count_and_still_propagate(isolated_io, stage):
    client = make_client(token=TOKEN)
    enqueue(client, 2)
    error = ValueError("synthetic preparation failure")
    targets = {
        "body": "lokikit.client.LokiClient._build_body",
        "serialization": "lokikit.client.json.dumps",
        "request": "lokikit.client.urllib.request.Request",
        "header": "lokikit.client.urllib.request.Request.add_header",
    }
    with patch(targets[stage], side_effect=error):
        with pytest.raises(ValueError) as raised:
            client.flush()
    assert raised.value is error
    assert client.dropped_entries == 2
    assert client._buffer == []
    client.flush()
    client.close()
    assert client.dropped_entries == 2
    isolated_io.urlopen.assert_not_called()


@pytest.mark.parametrize("stage", ["body", "timeout", "session", "session_entry", "post"])
def test_async_preparation_errors_count_and_still_propagate(isolated_io, stage):
    client = make_client()
    enqueue(client, 2)
    error = ValueError("synthetic preparation failure")
    if stage == "session_entry":
        isolated_io.session_entry_error = error
        target = None
    else:
        target = {
            "body": "lokikit.client.LokiClient._build_body",
            "timeout": "aiohttp.ClientTimeout",
            "session": "aiohttp.ClientSession",
            "post": None,
        }[stage]
    if stage == "post":
        def session_with_failing_post(*args, **kwargs):
            session = isolated_io._session(*args, **kwargs)
            session.post.side_effect = error
            return session

        isolated_io.session_factory.side_effect = session_with_failing_post
    if target is not None:
        with patch(target, side_effect=error):
            with pytest.raises(ValueError) as raised:
                asyncio.run(client.aflush())
    else:
        with pytest.raises(ValueError) as raised:
            asyncio.run(client.aflush())
    assert raised.value is error
    assert client.dropped_entries == 2
    assert client._buffer == []
    if stage == "post":
        assert isolated_io.sessions[0].closed
        isolated_io.sessions[0].post.assert_called_once()
    if stage == "session_entry":
        isolated_io.sessions[0].post.assert_not_called()
    asyncio.run(client.aflush())
    client.close()
    assert client.dropped_entries == 2
    isolated_io.urlopen.assert_not_called()


@pytest.mark.parametrize("cancel", [False, True])
def test_inflight_async_batch_does_not_consume_new_entries(isolated_io, cancel):
    client = make_client()

    async def scenario():
        entered = asyncio.Event()
        release = asyncio.Event()

        async def hold_request():
            entered.set()
            await release.wait()

        isolated_io.response_enter_hook = hold_request
        error = aiohttp.ClientConnectionError("synthetic in-flight failure")
        isolated_io.response_entry_error = error
        enqueue(client, 2)
        task = asyncio.create_task(client.aflush())
        try:
            await asyncio.wait_for(entered.wait(), timeout=2)
            client.push("synthetic-batch-B")
            assert [line for _, line in client._buffer] == ["synthetic-batch-B"]
            assert client.dropped_entries == 0
            if cancel:
                task.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await task
            else:
                release.set()
                with pytest.raises(aiohttp.ClientConnectionError) as raised:
                    await task
                assert raised.value is error
            assert client.dropped_entries == 2
            session = isolated_io.sessions[0]
            assert session.closed
            assert session.exit_type is (asyncio.CancelledError if cancel else type(error))
            session.post.assert_called_once()
            assert [line for _, line in client._buffer] == ["synthetic-batch-B"]
            isolated_io.response_enter_hook = None
            isolated_io.response_entry_error = None
            await client.aflush()
            assert client._buffer == []
            assert client.dropped_entries == 2
            delivered = isolated_io.sessions[1].post.call_args.kwargs["json"]
            assert [line for _, line in delivered["streams"][0]["values"]] == ["synthetic-batch-B"]
            await client.aflush()
            client.close()
            client.close()
            assert client.dropped_entries == 2
            assert_async_timeout(isolated_io, count=2)
            isolated_io.urlopen.assert_not_called()
        finally:
            release.set()
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    asyncio.run(scenario())


def test_concurrent_async_and_sync_failures_do_not_lose_increments(isolated_io):
    client = make_client(batch_size=100)
    workers = 8
    rendezvous = threading.Barrier(workers + 1)
    errors = []
    threads = []
    released = False
    isolated_io.urlopen.side_effect = TimeoutError("synthetic sync timeout")

    async def rendezvous_then_fail():
        # Separate event loops/threads finish detached batches concurrently.
        rendezvous.wait(timeout=5)
        raise aiohttp.ClientConnectionError("synthetic concurrent failure")

    isolated_io.response_enter_hook = rendezvous_then_fail

    def flush_batch():
        try:
            with pytest.raises(aiohttp.ClientConnectionError):
                asyncio.run(client.aflush())
        except BaseException as error:
            errors.append(error)

    try:
        for _ in range(workers):
            enqueue(client, 2)
            detached = threading.Event()

            def session_after_detachment(*args, signal=detached, **kwargs):
                session = isolated_io._session(*args, **kwargs)
                signal.set()
                return session

            isolated_io.session_factory.side_effect = session_after_detachment
            thread = threading.Thread(target=flush_batch, daemon=True)
            threads.append(thread)
            thread.start()
            # Synchronization bound only, not a simulated request timeout.
            assert detached.wait(timeout=3)
        enqueue(client, 3)
        rendezvous.wait(timeout=5)
        released = True
        client.flush()
    finally:
        if not released:
            rendezvous.abort()
        for thread in threads:
            thread.join(timeout=5)
    assert all(not thread.is_alive() for thread in threads), "Accounting deadlocked"
    assert not errors
    assert client.dropped_entries == workers * 2 + 3
    assert_async_timeout(isolated_io, count=workers)
    assert all(session.closed for session in isolated_io.sessions)
    assert all(session.post.call_count == 1 for session in isolated_io.sessions)
    isolated_io.urlopen.assert_called_once()
    client.close()
    assert client.dropped_entries == workers * 2 + 3


def test_socket_backstop_denies_connections_and_dns():
    with pytest.raises(AssertionError, match="Real network"):
        socket.create_connection(("telemetry.invalid", 443))
    with pytest.raises(AssertionError, match="Real network"):
        socket.getaddrinfo("telemetry.invalid", 443)
    with socket.socket() as sock:
        with pytest.raises(AssertionError, match="Real network"):
            sock.connect(("127.0.0.1", 9))
        with pytest.raises(AssertionError, match="Real network"):
            sock.connect_ex(("127.0.0.1", 9))
