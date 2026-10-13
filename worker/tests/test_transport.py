from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import types
from pathlib import Path
from typing import Any

import pytest

from melody_worker import transport


class FakeDartBridge(types.ModuleType):
    """The subset of serious_python's ``dart_bridge`` module the worker uses."""

    def __init__(self) -> None:
        super().__init__("dart_bridge")
        self.handlers: dict[int, Any] = {}
        self.sent: list[tuple[int, dict[str, Any]]] = []
        self.restart_handlers: list[Any] = []
        self._changed = threading.Condition()

    def set_enqueue_handler_func(self, port: int, handler: Any) -> None:
        self.handlers[port] = handler

    def send_bytes(self, port: int, payload: bytes) -> None:
        with self._changed:
            self.sent.append((port, json.loads(payload)))
            self._changed.notify_all()

    def add_session_restart_handler(self, handler: Any) -> None:
        self.restart_handlers.append(handler)

    def frame(self, index: int) -> tuple[int, dict[str, Any]]:
        with self._changed:
            assert self._changed.wait_for(lambda: len(self.sent) > index, timeout=5)
            return self.sent[index]


READY = {
    "event": "ready",
    "status": {
        "packages": {
            "yt-dlp": {"available": True},
            "ytmusicapi": {"available": True},
        }
    },
}


@pytest.fixture
def bridge(monkeypatch) -> FakeDartBridge:
    fake = FakeDartBridge()
    monkeypatch.setitem(sys.modules, "dart_bridge", fake)
    original = transport.Worker
    # Stand-in clients keep startup offline.
    monkeypatch.setattr(
        transport,
        "Worker",
        lambda send, **options: original(
            send, youtube_dl=object, ytmusic=object, **options
        ),
    )
    transport._connect_bridge(7)
    assert fake.frame(0) == (7, READY)
    return fake


def test_bridge_reconnects_to_a_new_dart_session(bridge) -> None:
    (reconnect,) = bridge.restart_handlers
    reconnect({"worker": 9})

    assert bridge.frame(1) == (9, READY)
    bridge.handlers[9](b'{"id": 1, "op": "nothing"}')
    port, reply = bridge.frame(2)
    assert (port, reply["id"], reply["ok"]) == (9, 1, False)


@pytest.mark.parametrize("ports", [{}, {"other": 3}])
def test_reconnect_ignores_sessions_without_a_worker_port(bridge, ports) -> None:
    bridge.restart_handlers[0](ports)
    assert set(bridge.handlers) == {7}
    assert len(bridge.sent) == 1


def test_starting_the_worker_leaves_runtime_packages_unimported() -> None:
    """The runtime updater selects yt-dlp and ytmusicapi before their first
    import; an earlier import keeps an installed update from ever applying."""
    source = Path(__file__).resolve().parents[1] / "src"
    probe = (
        "import sys\n"
        "import melody_worker.transport\n"
        "print([name for name in ('yt_dlp', 'ytmusicapi') if name in sys.modules])\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", probe],
        capture_output=True,
        text=True,
        check=True,
        env={**os.environ, "PYTHONPATH": str(source)},
    )
    assert result.stdout.strip() == "[]"
