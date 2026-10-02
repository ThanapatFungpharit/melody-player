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
STORAGE_VARIABLE = "MELODY_YT_DLP_RUNTIME"
CHECK_REMOTE_VARIABLE = "MELODY_YT_DLP_CHECK_REMOTE"


def _encode(frame: dict[str, Any]) -> bytes:
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    storage = os.environ.get(STORAGE_VARIABLE)
    options = {
        "storage_directory": Path(storage) if storage else None,
        "check_remote": os.environ.get(CHECK_REMOTE_VARIABLE) == "1",
    }
    port = os.environ.get(PORT_VARIABLE)
    if port:
        _serve_bridge(int(port), **options)
    else:
        _serve_stdio(**options)


def _serve_bridge(port: int, **options: Any) -> None:
    import dart_bridge  # provided by serious_python's embedded runtime

    worker = Worker(
        lambda frame: dart_bridge.send_bytes(port, _encode(frame)), **options
    )
    dart_bridge.set_enqueue_handler_func(port, worker.receive)
    worker.start()
    # The app owns the interpreter's lifetime.
    threading.Event().wait()


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
