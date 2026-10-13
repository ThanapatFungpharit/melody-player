from __future__ import annotations

import argparse
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from tools.dev.worker import (
    WorkerError,
    WorkerProcess,
    _request,
    parse_assignments,
    summarize_search,
)

# Speaks the worker's stdio protocol without yt-dlp or ytmusicapi.
FAKE_WORKER = textwrap.dedent(
    """
    import json, sys

    def send(frame):
        sys.stdout.write(json.dumps(frame) + "\\n")
        sys.stdout.flush()

    send({"event": "log", "message": "starting"})
    send({"event": "ready", "status": {"packages": {"fake": {"available": True}}}})
    for line in sys.stdin:
        frame = json.loads(line)
        if frame["op"] == "echo":
            send({"event": "progress", "task": frame["id"]})
            send({"id": frame["id"], "ok": True, "result": frame})
        elif frame["op"] == "crash":
            print("crashed on purpose", file=sys.stderr, flush=True)
            sys.exit(3)
        else:
            send({"id": frame["id"], "ok": False, "error": {"message": "nope"}})
    """
)


class WorkerProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.source = Path(directory.name)
        package = self.source / "melody_worker"
        package.mkdir()
        (package / "__init__.py").write_text("")
        (package / "__main__.py").write_text(FAKE_WORKER)
        self.events: list[dict] = []

    def start(self) -> WorkerProcess:
        worker = WorkerProcess(sys.executable, self.source, on_event=self.events.append)
        self.addCleanup(worker.close)
        return worker

    def test_ready_returns_status_and_forwards_earlier_events(self) -> None:
        status = self.start().ready(timeout=30)

        self.assertEqual(status, {"packages": {"fake": {"available": True}}})
        self.assertEqual(self.events, [{"event": "log", "message": "starting"}])

    def test_request_returns_result_and_forwards_events(self) -> None:
        worker = self.start()
        worker.ready(timeout=30)

        first = worker.request("echo", {"value": 1}, timeout=30)
        second = worker.request("echo", {"value": 2}, timeout=30)

        self.assertEqual(first, {"value": 1, "id": 1, "op": "echo"})
        self.assertEqual(second["id"], 2)
        self.assertIn({"event": "progress", "task": 2}, self.events)

    def test_failed_request_raises_the_worker_error(self) -> None:
        worker = self.start()
        worker.ready(timeout=30)

        with self.assertRaisesRegex(WorkerError, "nope"):
            worker.request("unknown", {}, timeout=30)

    def test_exit_reports_code_and_log(self) -> None:
        worker = self.start()
        worker.ready(timeout=30)

        with self.assertRaisesRegex(WorkerError, "code 3(.|\n)*crashed on purpose"):
            worker.request("crash", {}, timeout=30)
        with self.assertRaises(WorkerError):  # stays stopped
            worker.request("echo", {}, timeout=30)


class ArgumentTests(unittest.TestCase):
    def test_assignments_read_json_values_and_fall_back_to_text(self) -> None:
        self.assertEqual(
            parse_assignments(["limit=5", "filter=songs", "flat=true", "q=a=b"]),
            {"limit": 5, "filter": "songs", "flat": True, "q": "a=b"},
        )

    def test_assignment_without_equals_is_rejected(self) -> None:
        with self.assertRaises(argparse.ArgumentTypeError):
            parse_assignments(["limit"])

    def test_search_builds_a_ytmusic_request(self) -> None:
        arguments = argparse.Namespace(
            command="search", query="daft punk", limit=3, filter="songs"
        )

        self.assertEqual(
            _request(arguments),
            (
                "ytmusic",
                {
                    "method": "search",
                    "arguments": {"query": "daft punk", "limit": 3, "filter": "songs"},
                },
            ),
        )

    def test_send_takes_op_and_drops_id(self) -> None:
        arguments = argparse.Namespace(
            command="send", frame='{"op": "latest_release", "id": 9, "package": "x"}'
        )

        self.assertEqual(_request(arguments), ("latest_release", {"package": "x"}))

    def test_send_requires_an_op(self) -> None:
        with self.assertRaises(SystemExit):
            _request(argparse.Namespace(command="send", frame='{"package": "x"}'))

    def test_search_summary_lists_songs_artists_and_limits(self) -> None:
        results = [
            {
                "resultType": "song",
                "title": "One More Time",
                "artists": [{"name": "Daft Punk"}],
                "duration": "5:21",
                "videoId": "abc",
            },
            {"resultType": "artist", "artist": "Daft Punk", "browseId": "UC1"},
            {"resultType": "song", "title": "Third", "videoId": "def"},
        ]

        summary = summarize_search(results, limit=2).splitlines()

        self.assertEqual(len(summary), 2)
        self.assertIn("One More Time  - Daft Punk  5:21  [abc]", summary[0])
        self.assertIn("Daft Punk  [UC1]", summary[1])
        self.assertEqual(summarize_search([]), "(no results)")


if __name__ == "__main__":
    unittest.main()
