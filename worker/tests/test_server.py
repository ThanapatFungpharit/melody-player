from __future__ import annotations

import dataclasses
import errno
import json
import queue
import shutil
import subprocess
import sys
import threading
import zipfile
from pathlib import Path
from typing import Any, ClassVar, Self

import pytest

from melody_worker import transport
from melody_worker.server import Worker, describe, json_safe, sanitize_info


class FakeYoutubeDL:
    """Stands in for yt_dlp.YoutubeDL; behavior is set per test."""

    info: ClassVar[dict[str, Any] | None] = None
    error: ClassVar[Exception | None] = None
    gate: ClassVar[threading.Event | None] = None
    calls: ClassVar[list[tuple[str, dict[str, Any]]]] = []
    # The info dict each download's pre_process postprocessors produced.
    processed: ClassVar[list[dict[str, Any]]] = []

    def __init__(self, options: dict[str, Any]) -> None:
        self.options = options
        self.preprocessors: list[Any] = []

    def add_post_processor(self, pp: Any, when: str = "post_process") -> None:
        assert when == "pre_process"
        self.preprocessors.append(pp)

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
        info: dict[str, Any] = {"title": "Song"}
        for pp in self.preprocessors:
            _, info = pp.run(info)
        self.processed.append(info)
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


class FakeYTMusic:
    """Stands in for ytmusicapi.YTMusic."""

    calls: ClassVar[list[tuple[str, dict[str, Any]]]] = []
    error: ClassVar[Exception | None] = None

    def search(self, **arguments: Any) -> Any:
        self.calls.append(("search", arguments))
        if self.error is not None:
            raise self.error
        return [{"videoId": "abc", "title": "Song", "extra": object()}]

    def get_lyrics(self, **arguments: Any) -> Any:
        self.calls.append(("get_lyrics", arguments))
        return {
            "lyrics": [LyricLine("Hello", 1000, 2000, 1)],
            "source": "Source: Test",
            "hasTimestamps": True,
        }


class FakeFFmpeg:
    """Stands in for yt_dlp's FFmpegPostProcessor."""

    runs: ClassVar[list[tuple[str, str, list[str], dict[str, Any]]]] = []

    def __init__(self, downloader: FakeYoutubeDL) -> None:
        self.downloader = downloader

    @staticmethod
    def stream_copy_opts(copy: bool = True, *, ext: str | None = None) -> Any:
        yield from ("-map", "0", "-c", "copy", f"ext={ext}")

    def run_ffmpeg(self, path: str, out_path: str, opts: list[str]) -> None:
        self.runs.append((path, out_path, list(opts), self.downloader.options))


@dataclasses.dataclass
class LyricLine:
    text: str
    start_time: int
    end_time: int
    id: int


@pytest.fixture
def worker() -> tuple[Worker, queue.Queue[dict[str, Any]]]:
    FakeYoutubeDL.info = None
    FakeYoutubeDL.error = None
    FakeYoutubeDL.gate = None
    FakeYoutubeDL.calls = []
    FakeYoutubeDL.processed = []
    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    FakeYTMusic.calls = []
    FakeYTMusic.error = None
    FakeFFmpeg.runs = []
    instance = Worker(
        frames.put, youtube_dl=FakeYoutubeDL, ytmusic=FakeYTMusic, ffmpeg=FakeFFmpeg
    )
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


@pytest.mark.parametrize(
    "frame",
    [
        {"op": "extract"},
        {"op": "extract", "target": 5},
        {"op": "extract", "target": "https://x", "options": ["a", "b"]},
        {"op": "ytmusic", "method": "search", "arguments": "query"},
        {"op": "download", "task": "t", "url": "", "directory": "."},
        {"op": "cancel"},
    ],
)
def test_malformed_requests_are_answered_with_an_error(worker, frame) -> None:
    instance, frames = worker
    request(instance, {"id": 30, **frame})
    reply = response(frames, 30)
    assert reply["ok"] is False
    assert "request" in reply["error"]["message"]
    assert FakeYoutubeDL.calls == []
    assert FakeYTMusic.calls == []


def test_download_error_exc_info_is_part_of_the_chain() -> None:
    class DownloadError(RuntimeError):
        exc_info: tuple[type[BaseException], BaseException, None]

    original = TimeoutError("timed out")
    wrapper = DownloadError("ERROR: wrapped")
    wrapper.exc_info = (TimeoutError, original, None)
    described = describe(wrapper)
    assert described["timeout"] is True
    assert described["chain"] == ["timed out"]


def test_nested_entries_are_not_expanded() -> None:
    info = {"entries": [{"id": "a", "entries": [{"id": "b"}]}]}
    assert sanitize_info(info) == {"entries": [{"id": "a"}]}


def test_a_new_session_drops_old_replies_and_cancels_old_downloads(
    worker, tmp_path
) -> None:
    instance, frames = worker
    FakeYoutubeDL.gate = threading.Event()
    request(
        instance,
        {
            "id": 1,
            "op": "download",
            "task": "old",
            "url": "u",
            "directory": str(tmp_path),
        },
    )
    assert frames.get(timeout=5)["event"] == "progress"

    instance.restart_session()
    assert frames.get(timeout=5) == {
        "event": "ready",
        "status": {
            "packages": {
                "yt-dlp": {"available": True},
                "ytmusicapi": {"available": True},
            }
        },
    }
    FakeYoutubeDL.gate.set()
    # The new session reuses request id 1; the old download's reply must not
    # answer it.
    request(instance, {"id": 1, "op": "extract", "target": "t"})
    reply = response(frames, 1)
    assert reply == {"id": 1, "ok": True, "result": None}
    assert frames.empty()
    assert not (tmp_path / "song.mp3").exists()


def test_requests_delivered_while_a_new_session_connects_are_answered(
    worker,
) -> None:
    instance, frames = worker

    def connect() -> None:
        # A bridge may deliver the new session's queued requests as soon as
        # its handler is registered, before restart_session returns.
        request(instance, {"id": 1, "op": "extract", "target": "t"})
        request(instance, {"id": 2, "op": "cancel", "task": "none"})

    instance.restart_session(connect)
    # The cancel is answered synchronously, so the replies arrive in either
    # order.
    replies: dict[int, dict[str, Any]] = {}
    while len(replies) < 2:
        frame = frames.get(timeout=5)
        if frame.get("id") in (1, 2):
            replies[frame["id"]] = frame
    assert replies[1] == {"id": 1, "ok": True, "result": None}
    assert replies[2] == {"id": 2, "ok": True, "result": True}


@pytest.fixture
def encoding_worker(worker) -> tuple[Worker, queue.Queue[dict[str, Any]]]:
    """A worker whose frames go through the real JSON encoding."""
    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    instance = Worker(
        lambda frame: frames.put(json.loads(transport._encode(frame))),
        youtube_dl=FakeYoutubeDL,
        ytmusic=FakeYTMusic,
    )
    instance.start()
    assert frames.get(timeout=5)["event"] == "ready"
    return instance, frames


def test_a_result_json_cannot_carry_is_answered_with_an_error(
    encoding_worker,
) -> None:
    instance, frames = encoding_worker
    FakeYoutubeDL.info = {"title": "Song", "duration": float("nan")}
    request(instance, {"id": 1, "op": "extract", "target": "t"})
    reply = response(frames, 1)
    assert reply["ok"] is False
    assert reply["error"]["types"] == ["ValueError"]


def test_text_cut_inside_an_emoji_is_still_delivered(encoding_worker) -> None:
    instance, frames = encoding_worker
    FakeYoutubeDL.info = {"title": "Song \ud83c"}
    request(instance, {"id": 1, "op": "extract", "target": "t"})
    assert response(frames, 1) == {"id": 1, "ok": True, "result": {"title": "Song ?"}}


def test_ytmusic_calls_return_json(worker) -> None:
    instance, frames = worker
    request(
        instance,
        {
            "id": 7,
            "op": "ytmusic",
            "method": "search",
            "arguments": {"query": "q", "filter": "songs"},
        },
    )
    reply = response(frames, 7)
    assert reply["result"] == [{"videoId": "abc", "title": "Song", "extra": None}]
    assert FakeYTMusic.calls == [("search", {"query": "q", "filter": "songs"})]


def test_timed_lyrics_become_plain_objects(worker) -> None:
    instance, frames = worker
    request(
        instance,
        {"id": 8, "op": "ytmusic", "method": "get_lyrics", "arguments": {}},
    )
    assert response(frames, 8)["result"]["lyrics"] == [
        {"text": "Hello", "start_time": 1000, "end_time": 2000, "id": 1}
    ]


def test_ytmusic_values_json_cannot_carry_are_dropped() -> None:
    reply = {"duration": float("nan"), "plays": float("inf"), "rating": 4.5}
    assert json_safe(reply) == {"duration": None, "plays": None, "rating": 4.5}


def test_only_listed_ytmusic_methods_are_callable(worker) -> None:
    instance, frames = worker
    request(
        instance,
        {"id": 9, "op": "ytmusic", "method": "delete_playlist", "arguments": {}},
    )
    reply = response(frames, 9)
    assert reply["ok"] is False
    assert FakeYTMusic.calls == []


def test_latest_release_rejects_unknown_packages(worker) -> None:
    instance, frames = worker
    request(instance, {"id": 10, "op": "latest_release", "package": "pip"})
    assert response(frames, 10)["ok"] is False


def test_download_metadata_becomes_tagged_fields(worker, tmp_path) -> None:
    instance, frames = worker
    request(
        instance,
        {
            "id": 11,
            "op": "download",
            "task": "t3",
            "url": "u",
            "directory": str(tmp_path),
            "metadata": {"lyrics": "[00:01.00]Hello"},
        },
    )
    assert response(frames, 11)["ok"] is True
    assert FakeYoutubeDL.processed == [
        {"title": "Song", "meta_lyrics": "[00:01.00]Hello"}
    ]


def test_tag_copies_every_stream_and_sets_tags(worker, tmp_path) -> None:
    instance, frames = worker
    source, target = tmp_path / "song.m4a", tmp_path / ".copy.m4a"
    request(
        instance,
        {
            "id": 12,
            "op": "tag",
            "source": str(source),
            "target": str(target),
            "metadata": {"lyrics": "[00:01.00]Hello\nWorld"},
            "options": {"ffmpeg_location": "ffmpeg-folder"},
        },
    )
    assert response(frames, 12)["ok"] is True
    assert FakeFFmpeg.runs == [
        (
            str(source),
            str(target),
            [
                *("-map", "0", "-c", "copy", "ext=m4a"),
                *("-map_metadata", "0"),
                *("-metadata", "lyrics=[00:01.00]Hello\nWorld"),
            ],
            {"ffmpeg_location": "ffmpeg-folder"},
        )
    ]


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs FFmpeg")
def test_tag_keeps_cover_art_with_real_ffmpeg(tmp_path) -> None:
    from yt_dlp import YoutubeDL

    def ffmpeg(*arguments: str) -> str:
        return subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostdin", *arguments],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        ).stderr

    cover, plain = tmp_path / "cover.png", tmp_path / "plain.m4a"
    source, target = tmp_path / "song.m4a", tmp_path / ".copy.m4a"
    ffmpeg("-f", "lavfi", "-i", "color=red:s=16x16", "-frames:v", "1", str(cover))
    ffmpeg("-f", "lavfi", "-i", "sine=d=1", "-c:a", "aac", str(plain))
    ffmpeg(
        *("-i", str(plain), "-i", str(cover), "-map", "0", "-map", "1"),
        *("-c", "copy", "-disposition:v", "attached_pic"),
        *("-metadata", "title=Song", str(source)),
    )
    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    instance = Worker(frames.put, youtube_dl=YoutubeDL, ytmusic=FakeYTMusic)
    instance.start()
    assert frames.get(timeout=5)["event"] == "ready"
    request(
        instance,
        {
            "id": 1,
            "op": "tag",
            "source": str(source),
            "target": str(target),
            "metadata": {"lyrics": "[00:00.50]Hello\n[00:00.90]World"},
            "options": {"quiet": True},
        },
    )
    assert response(frames, 1)["ok"] is True
    probe = ffmpeg("-i", str(target))
    assert "lyrics          : [00:00.50]Hello" in probe
    assert "title           : Song" in probe
    assert "(attached pic)" in probe


def _prepare_music_package(
    monkeypatch: pytest.MonkeyPatch, location: Path
) -> dict[str, Any]:
    """Prepare a stand-in for ytmusicapi importable from ``location`` and
    return the worker's ytmusicapi status."""
    from melody_worker import server
    from melody_worker.updater import YT_DLP, YTMUSICAPI, UpdateResult

    monkeypatch.syspath_prepend(str(location))
    monkeypatch.delitem(sys.modules, "packaged_music", raising=False)
    monkeypatch.setattr(
        server,
        "PACKAGES",
        {
            YT_DLP.distribution: YT_DLP,
            YTMUSICAPI.distribution: dataclasses.replace(
                YTMUSICAPI, module="packaged_music"
            ),
        },
    )
    monkeypatch.setattr(
        server,
        "prepare_package",
        lambda package, **_: UpdateResult(
            active_version="1.12.3",
            bundled_version="1.12.3",
            current_version=None,
            previous_version=None,
            remote_version=None,
            updated=False,
            recovered=False,
            rolled_back=False,
            active_source="bundled",
        ),
    )
    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    instance = Worker(frames.put, youtube_dl=FakeYoutubeDL)
    instance.start()
    ready = frames.get(timeout=5)
    assert ready["event"] == "ready"
    sys.modules.pop("packaged_music", None)
    return ready["status"]["packages"]["ytmusicapi"]


_MUSIC_MODULE = "class YTMusic:\n    pass\n"


def test_a_zip_imported_music_package_is_reported_unavailable(
    monkeypatch, tmp_path
) -> None:
    # Android imports site-packages from sitepackages.zip unless the build
    # extracts the package; ytmusicapi cannot load its catalogs from there.
    archive = tmp_path / "sitepackages.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("packaged_music/__init__.py", _MUSIC_MODULE)

    status = _prepare_music_package(monkeypatch, archive)

    assert status["available"] is False
    assert any("imported from an archive" in error for error in status["errors"])


def test_an_extracted_music_package_is_available(monkeypatch, tmp_path) -> None:
    package = tmp_path / "extract" / "packaged_music"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text(_MUSIC_MODULE, encoding="utf-8")

    status = _prepare_music_package(monkeypatch, tmp_path / "extract")

    assert status["available"] is True
    assert "errors" not in status or not status["errors"]


def test_release_lookups_overlap_package_selection(monkeypatch, tmp_path) -> None:
    from melody_worker import server
    from melody_worker.updater import YT_DLP, YTMUSICAPI, UpdateResult

    (tmp_path / "packaged_dl.py").write_text("class YoutubeDL:\n    pass\n")
    (tmp_path / "packaged_music.py").write_text(_MUSIC_MODULE)
    monkeypatch.syspath_prepend(str(tmp_path))
    for module in ("packaged_dl", "packaged_music"):
        monkeypatch.delitem(sys.modules, module, raising=False)
    packages = {
        YT_DLP.distribution: dataclasses.replace(YT_DLP, module="packaged_dl"),
        YTMUSICAPI.distribution: dataclasses.replace(
            YTMUSICAPI, module="packaged_music", zip_safe=True
        ),
    }
    monkeypatch.setattr(server, "PACKAGES", packages)
    music_lookup = threading.Event()

    class FakeUpdater:
        def __init__(self, package: Any, **_: Any) -> None:
            self._name = package.distribution

        def latest_release(self) -> str:
            if self._name == YTMUSICAPI.distribution:
                music_lookup.set()
            return f"{self._name} release"

    def prepare_package(package: Any, **options: Any) -> UpdateResult:
        # yt-dlp is selected first; the ytmusicapi lookup must not wait for it.
        assert music_lookup.wait(5)
        assert options["check_remote"] is True
        remote = options["fetch_remote"](package.metadata_url)
        assert remote == f"{package.distribution} release"
        return UpdateResult(
            active_version="1",
            bundled_version="1",
            current_version=None,
            previous_version=None,
            remote_version=None,
            updated=False,
            recovered=False,
            rolled_back=False,
            active_source="bundled",
        )

    monkeypatch.setattr(server, "PackageUpdater", FakeUpdater)
    monkeypatch.setattr(server, "prepare_package", prepare_package)
    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    instance = Worker(frames.put, check_remote=packages)
    instance.start()
    ready = frames.get(timeout=10)
    sys.modules.pop("packaged_dl", None)
    sys.modules.pop("packaged_music", None)

    for status in ready["status"]["packages"].values():
        assert status["available"] is True, status
