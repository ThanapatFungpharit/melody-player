"""Connect the worker to the app's in-process bridge, or to stdio.

Inside Melody, serious_python provides ``dart_bridge`` and the app passes its
port in ``MELODY_WORKER_PORT``. Without it (tests, local development) the
worker reads newline-delimited JSON on stdin and writes it to stdout.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
from pathlib import Path
from typing import Any

from .server import Worker

PORT_VARIABLE = "MELODY_WORKER_PORT"
# Per package: (runtime storage directory, "1" to install the newest
# compatible release during this launch).
PACKAGE_VARIABLES = {
    "yt-dlp": ("MELODY_YT_DLP_RUNTIME", "MELODY_YT_DLP_CHECK_REMOTE"),
    "ytmusicapi": ("MELODY_YTMUSICAPI_RUNTIME", "MELODY_YTMUSICAPI_CHECK_REMOTE"),
}
# The label the app uses for this channel in DartBridge.signalDartSession.
SESSION_PORT_LABEL = "worker"

logger = logging.getLogger(__name__)


def _encode(frame: dict[str, Any]) -> bytes:
    # NaN is not JSON and the app cannot decode it: fail here, where the
    # worker still answers with an error. A lone surrogate (text cut in the
    # middle of an emoji) is replaced rather than losing the whole frame.
    return json.dumps(
        frame, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ).encode("utf-8", "replace")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    options = {
        "runtime_directories": {
            name: Path(storage) if (storage := os.environ.get(variable)) else None
            for name, (variable, _) in PACKAGE_VARIABLES.items()
        },
        "check_remote": {
            name
            for name, (_, variable) in PACKAGE_VARIABLES.items()
            if os.environ.get(variable) == "1"
        },
    }
    port = os.environ.get(PORT_VARIABLE)
    if port:
        _serve_bridge(int(port), **options)
    else:
        _serve_stdio(**options)


def _serve_bridge(port: int, **options: Any) -> None:
    _connect_bridge(port, **options)
    # The app owns the interpreter's lifetime.
    threading.Event().wait()


def _connect_bridge(port: int, **options: Any) -> Worker:
    # Provided by serious_python's embedded runtime only.
    import dart_bridge  # ty: ignore[unresolved-import]

    channel = {"port": port}
    worker = Worker(
        lambda frame: dart_bridge.send_bytes(channel["port"], _encode(frame)),
        **options,
    )
    dart_bridge.set_enqueue_handler_func(port, worker.receive)

    def reconnect(ports: dict[str, int]) -> None:
        # Android kept this process, and with it the interpreter, alive
        # across a Dart VM restart. Serve the new app session instead.
        new_port = ports.get(SESSION_PORT_LABEL)
        if new_port is None:
            return

        def connect() -> None:
            channel["port"] = int(new_port)
            dart_bridge.set_enqueue_handler_func(int(new_port), worker.receive)

        # The new session must be current before its requests can arrive.
        worker.restart_session(connect)
        logger.info("Reconnected to a new app session")

    add_restart_handler = getattr(dart_bridge, "add_session_restart_handler", None)
    if add_restart_handler is not None:
        add_restart_handler(reconnect)
    worker.start()
    return worker


def _serve_stdio(**options: Any) -> None:
    output = sys.stdout.buffer

    def send(frame: dict[str, Any]) -> None:
        output.write(_encode(frame) + b"\n")
        output.flush()

    worker = Worker(send, **options)
    worker.start()
    for line in sys.stdin.buffer:
        if line.strip():
            worker.receive(line)
