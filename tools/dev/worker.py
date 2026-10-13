"""Talk to the real Python worker from a terminal, with the app's frames.

    uv run melody-worker status
    uv run melody-worker search "daft punk" --filter songs --limit 5
    uv run melody-worker ytmusic get_watch_playlist videoId=dQw4w9WgXcQ limit=5
    uv run melody-worker extract https://music.youtube.com/watch?v=dQw4w9WgXcQ
    uv run melody-worker send '{"op": "latest_release", "package": "ytmusicapi"}'

The worker runs in its development interpreter over stdio, exactly as
``MELODY_WORKER_PYTHON`` runs it for the app (frames are documented in
``worker/src/melody_worker/server.py``). Replies print as JSON on stdout;
events such as download progress print to stderr. Values in KEY=VALUE
arguments are read as JSON when they parse, otherwise as text. Runtime updates
are never installed: the worker uses the packages pinned in worker/uv.lock.
"""

from __future__ import annotations

import argparse
import io
import itertools
import json
import queue
import subprocess
import sys
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import IO, Any, Self

from tools.common import WORKER, child_environment, load_env_file, worker_python

Frame = dict[str, Any]


class WorkerError(RuntimeError):
    """The worker failed a request or stopped."""


class WorkerProcess:
    """A worker process speaking newline-delimited JSON over stdio."""

    def __init__(
        self,
        python: Path | str,
        source: Path = WORKER / "src",
        *,
        on_event: Callable[[Frame], None] | None = None,
        echo_log: bool = False,
    ) -> None:
        self._on_event = on_event or (lambda frame: None)
        self._echo_log = echo_log
        self._frames: queue.Queue[Frame | None] = queue.Queue()
        self._log: deque[str] = deque(maxlen=40)
        self._ids = itertools.count(1)
        self._process = subprocess.Popen(
            [str(python), "-m", "melody_worker"],
            cwd=source,
            env=child_environment({"PYTHONPATH": str(source), "PYTHONUNBUFFERED": "1"}),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert self._process.stdout is not None and self._process.stderr is not None
        threading.Thread(
            target=self._read_frames, args=(self._process.stdout,), daemon=True
        ).start()
        self._log_reader = threading.Thread(
            target=self._read_log, args=(self._process.stderr,), daemon=True
        )
        self._log_reader.start()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def _read_frames(self, stream: IO[bytes]) -> None:
        for line in stream:
            if not line.strip():
                continue
            try:
                frame = json.loads(line.decode("utf-8"))
            except UnicodeDecodeError, json.JSONDecodeError:
                self._log.append(f"(unreadable frame) {line!r}")
                continue
            if isinstance(frame, dict):
                self._frames.put(frame)
        self._frames.put(None)

    def _read_log(self, stream: IO[bytes]) -> None:
        for raw in stream:
            line = raw.decode("utf-8", "replace").rstrip()
            self._log.append(line)
            if self._echo_log:
                print(f"[worker] {line}", file=sys.stderr, flush=True)

    def _next(self, deadline: float) -> Frame:
        remaining = deadline - time.monotonic()
        try:
            frame = self._frames.get(timeout=max(remaining, 0))
        except queue.Empty:
            raise TimeoutError("The worker did not answer in time") from None
        if frame is None:
            self._frames.put(None)  # stay stopped for later calls
            code = self._process.wait()
            self._log_reader.join(timeout=2)  # include its last words
            log = "\n".join(self._log)
            raise WorkerError(
                f"The worker exited with code {code}" + (f":\n{log}" if log else "")
            )
        return frame

    def ready(self, timeout: float) -> Frame:
        """Wait for the ready event and return the worker's package status."""
        deadline = time.monotonic() + timeout
        while True:
            frame = self._next(deadline)
            if frame.get("event") == "ready":
                return frame.get("status") or {}
            self._on_event(frame)

    def request(self, operation: str, fields: Mapping[str, Any], timeout: float) -> Any:
        """Send one request and return its result, forwarding events."""
        request_id = next(self._ids)
        frame = {**fields, "id": request_id, "op": operation}
        assert self._process.stdin is not None
        try:
            self._process.stdin.write(json.dumps(frame).encode("utf-8") + b"\n")
            self._process.stdin.flush()
        except OSError as error:
            raise WorkerError(f"The worker is not running: {error}") from None
        deadline = time.monotonic() + timeout
        while True:
            reply = self._next(deadline)
            if reply.get("id") == request_id:
                if reply.get("ok"):
                    return reply.get("result")
                raise WorkerError(json.dumps(reply.get("error"), ensure_ascii=False))
            if "event" in reply:
                self._on_event(reply)

    def close(self) -> None:
        if self._process.stdin is not None and not self._process.stdin.closed:
            try:
                self._process.stdin.close()
            except OSError:
                pass
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()
            self._process.wait()


def parse_assignments(pairs: Sequence[str]) -> dict[str, Any]:
    """``["limit=5", "filter=songs"]`` -> ``{"limit": 5, "filter": "songs"}``."""
    values: dict[str, Any] = {}
    for pair in pairs:
        key, separator, text = pair.partition("=")
        if not separator or not key:
            raise argparse.ArgumentTypeError(f"Expected KEY=VALUE, got {pair!r}")
        try:
            values[key] = json.loads(text)
        except json.JSONDecodeError:
            values[key] = text
    return values


def summarize_search(results: Any, limit: int | None = None) -> str:
    """One line per YouTube Music search result, at most ``limit`` lines.

    ytmusicapi treats its own ``limit`` as a minimum and returns whole pages.
    """
    lines = []
    for item in (results if isinstance(results, list) else [])[:limit]:
        if not isinstance(item, dict):
            continue
        artists = ", ".join(
            artist.get("name") or ""
            for artist in item.get("artists") or ()
            if isinstance(artist, dict)
        )
        identifier = (
            item.get("videoId") or item.get("browseId") or item.get("playlistId")
        )
        parts = [
            f"{item.get('resultType') or '':<9}",
            str(item.get("title") or item.get("artist") or ""),
            f"- {artists}" if artists else "",
            str(item.get("duration") or ""),
            f"[{identifier}]" if identifier else "",
        ]
        lines.append("  ".join(part for part in parts if part))
    return "\n".join(lines) if lines else "(no results)"


def _request(arguments: argparse.Namespace) -> tuple[str, dict[str, Any]]:
    """The operation and fields for this command line."""
    if arguments.command == "search":
        query: dict[str, Any] = {"query": arguments.query, "limit": arguments.limit}
        if arguments.filter:
            query["filter"] = arguments.filter
        return "ytmusic", {"method": "search", "arguments": query}
    if arguments.command == "ytmusic":
        return "ytmusic", {
            "method": arguments.method,
            "arguments": parse_assignments(arguments.arguments),
        }
    if arguments.command == "extract":
        return "extract", {
            "target": arguments.url,
            "options": parse_assignments(arguments.option or ()),
        }
    try:
        frame = json.loads(arguments.frame)
    except json.JSONDecodeError as error:
        raise SystemExit(f"The frame is not JSON: {error}") from None
    if not isinstance(frame, dict) or not isinstance(frame.get("op"), str):
        raise SystemExit('The frame must be a JSON object with an "op", without "id"')
    frame.pop("id", None)
    return frame.pop("op"), frame


def _print_event(frame: Frame) -> None:
    print(json.dumps(frame, ensure_ascii=False), file=sys.stderr, flush=True)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-worker",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--timeout", type=float, default=120, help="Seconds per step (default 120)"
    )
    parser.add_argument(
        "--python", type=Path, help="Interpreter (default: worker/.venv, synced)"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Show the worker's log"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="Print which yt-dlp and ytmusicapi loaded")
    search = commands.add_parser("search", help="Search YouTube Music")
    search.add_argument("query")
    search.add_argument("--filter", help="songs, videos, albums, artists, playlists")
    search.add_argument("--limit", type=int, default=10)
    search.add_argument("--json", action="store_true", help="Print the raw results")
    ytmusic = commands.add_parser("ytmusic", help="Call a whitelisted YTMusic method")
    ytmusic.add_argument("method")
    ytmusic.add_argument("arguments", nargs="*", metavar="KEY=VALUE")
    extract = commands.add_parser("extract", help="Resolve a URL with yt-dlp")
    extract.add_argument("url")
    extract.add_argument(
        "--option", action="append", metavar="KEY=VALUE", help="yt-dlp option"
    )
    send = commands.add_parser("send", help="Send a raw request frame")
    send.add_argument("frame", help='JSON object such as {"op": "...", ...}')
    arguments = parser.parse_args(argv)
    load_env_file()

    if not sys.stdout.isatty() and isinstance(sys.stdout, io.TextIOWrapper):
        # Piped JSON is UTF-8 whatever the console's code page.
        sys.stdout.reconfigure(encoding="utf-8")
    request = None if arguments.command == "status" else _request(arguments)
    python = arguments.python or worker_python()
    try:
        with WorkerProcess(
            python, on_event=_print_event, echo_log=arguments.verbose
        ) as worker:
            status = worker.ready(arguments.timeout)
            if request is None:
                result: Any = status
            else:
                result = worker.request(*request, timeout=arguments.timeout)
    except (WorkerError, TimeoutError) as error:
        raise SystemExit(f"melody-worker: {error}") from None
    if arguments.command == "search" and not arguments.json:
        print(summarize_search(result, arguments.limit))
    else:
        print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
