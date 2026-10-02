from __future__ import annotations

import errno
import json
import queue
import threading
from pathlib import Path
from typing import Any, ClassVar, Self

import pytest

from melody_worker.server import Worker, describe, sanitize_info


class FakeYoutubeDL:
    """Stands in for yt_dlp.YoutubeDL; behavior is set per test."""

    info: ClassVar[dict[str, Any] | None] = None
    error: ClassVar[Exception | None] = None
    gate: ClassVar[threading.Event | None] = None
    calls: ClassVar[list[tuple[str, dict[str, Any]]]] = []

    def __init__(self, options: dict[str, Any]) -> None:
        self.options = options

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def extract_info(self, target: str, *, download: bool) -> Any:
        assert download is False
        self.calls.append((target, self.options))
        if self.error is not None:
            raise self.error
        return self.info

    def download(self, urls: list[str]) -> None:
        hook = self.options["progress_hooks"][0]
        home = Path(self.options["paths"]["home"])
        hook(
            {
                "status": "downloading",
                "downloaded_bytes": 5,
                "total_bytes": 10,
                "filename": str(home / "song.webm"),
                "info_dict": {"title": "Song", "channel": "Artist"},
            }
        )
        if self.gate is not None:
            self.gate.wait(5)
            hook({"status": "downloading", "downloaded_bytes": 6, "total_bytes": 10})
        (home / "song.mp3").write_bytes(b"audio")
        hook({"status": "finished", "downloaded_bytes": 10, "total_bytes": 10})


@pytest.fixture
def worker() -> tuple[Worker, queue.Queue[dict[str, Any]]]:
    FakeYoutubeDL.info = None
    FakeYoutubeDL.error = None
    FakeYoutubeDL.gate = None
    FakeYoutubeDL.calls = []
    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    instance = Worker(frames.put, storage_directory=None, youtube_dl=FakeYoutubeDL)
    instance.start()
    assert frames.get(timeout=5)["event"] == "ready"
    return instance, frames


def request(worker: Worker, frame: dict[str, Any]) -> None:
    worker.receive(json.dumps(frame).encode("utf-8"))


def response(frames: queue.Queue[dict[str, Any]], request_id: int) -> dict[str, Any]:
    while True:
        frame = frames.get(timeout=5)
        if frame.get("id") == request_id:
            return frame


def test_extract_returns_only_fields_the_app_reads(worker) -> None:
    instance, frames = worker
    FakeYoutubeDL.info = {
        "_type": "playlist",
        "title": "Mix",
        "http_headers": {"Cookie": "secret"},
        "entries": [
            {"id": "a", "title": "A", "formats": [{"url": "x"}], "duration": 3.5},
            None,
        ],
    }
    request(instance, {"id": 1, "op": "extract", "target": "t", "options": {"q": 1}})
    reply = response(frames, 1)
    assert reply["ok"] is True
    assert reply["result"] == {
        "_type": "playlist",
        "title": "Mix",
        "entries": [{"id": "a", "title": "A", "duration": 3.5}, None],
    }
    assert FakeYoutubeDL.calls == [("t", {"q": 1})]


def test_failures_carry_classification_facts(worker) -> None:
    instance, frames = worker
    cause = OSError(errno.ENOSPC, "No space left on device")
    error = RuntimeError("ERROR: unable to download")
    error.__cause__ = cause
    FakeYoutubeDL.error = error
    request(instance, {"id": 2, "op": "extract", "target": "t"})
    reply = response(frames, 2)
    assert reply["ok"] is False
    assert reply["error"]["types"] == ["RuntimeError", "OSError"]
    assert reply["error"]["errnos"] == [errno.ENOSPC]
    assert reply["error"]["message"] == "ERROR: unable to download"


def test_download_streams_progress_into_the_staging_directory(worker, tmp_path) -> None:
    instance, frames = worker
    request(
        instance,
        {
            "id": 3,
            "op": "download",
            "task": "t1",
            "url": "u",
            "directory": str(tmp_path),
        },
    )
    events = []
    while True:
        frame = frames.get(timeout=5)
        if frame.get("id") == 3:
            break
        events.append(frame)
    assert frame == {"id": 3, "ok": True, "result": {"cancelled": False}}
    assert events[0]["status"] == "downloading"
    assert events[0]["uploader"] == "Artist"
    assert events[-1]["status"] == "processing"
    assert (tmp_path / "song.mp3").read_bytes() == b"audio"


def test_cancel_stops_a_running_download(worker, tmp_path) -> None:
    instance, frames = worker
    FakeYoutubeDL.gate = threading.Event()
    request(
        instance,
        {
            "id": 4,
            "op": "download",
            "task": "t2",
            "url": "u",
            "directory": str(tmp_path),
        },
    )
    assert frames.get(timeout=5)["event"] == "progress"
    request(instance, {"id": 5, "op": "cancel", "task": "t2"})
    assert response(frames, 5)["result"] is True
    FakeYoutubeDL.gate.set()
    assert response(frames, 4)["result"] == {"cancelled": True}
    assert not (tmp_path / "song.mp3").exists()


def test_unknown_operations_are_rejected(worker) -> None:
    instance, frames = worker
    request(instance, {"id": 6, "op": "shell"})
    assert response(frames, 6)["ok"] is False


def test_download_error_exc_info_is_part_of_the_chain() -> None:
    original = TimeoutError("timed out")
    wrapper = RuntimeError("ERROR: wrapped")
    wrapper.exc_info = (TimeoutError, original, None)  # type: ignore[attr-defined]
    described = describe(wrapper)
    assert described["timeout"] is True
    assert described["chain"] == ["timed out"]


def test_nested_entries_are_not_expanded() -> None:
    info = {"entries": [{"id": "a", "entries": [{"id": "b"}]}]}
    assert sanitize_info(info) == {"entries": [{"id": "a"}]}
