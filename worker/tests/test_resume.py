"""Stopped downloads against the real yt-dlp and a local server, without fakes."""

from __future__ import annotations

import http.server
import queue
import shutil
import subprocess
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

from melody_worker.server import Worker


@pytest.fixture
def audio(tmp_path) -> bytes:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        pytest.skip("needs FFmpeg on PATH")
    path = tmp_path / "source.mp3"
    subprocess.run(
        [ffmpeg, "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
        + [str(path)],
        check=True,
        stdin=subprocess.DEVNULL,
    )
    return path.read_bytes()


@pytest.fixture
def server(audio: bytes) -> Iterator[tuple[str, list[str | None]]]:
    """Serves ``audio`` at a URL with ranges, recording each request's range."""
    ranges: list[str | None] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            wanted = self.headers.get("Range")
            ranges.append(wanted)
            start = int(wanted.split("=")[1].split("-")[0]) if wanted else 0
            self.send_response(206 if wanted else 200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(audio) - start))
            if wanted:
                self.send_header(
                    "Content-Range", f"bytes {start}-{len(audio) - 1}/{len(audio)}"
                )
            self.end_headers()
            self.wfile.write(audio[start:])

        def log_message(self, format: str, *args: Any) -> None:
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}/song.mp3", ranges
    finally:
        httpd.shutdown()
        httpd.server_close()


def download(directory: Path, url: str, postprocessors: list[dict[str, Any]]) -> None:
    from yt_dlp import YoutubeDL

    frames: queue.Queue[dict[str, Any]] = queue.Queue()
    # The app's real path to yt-dlp; only the other library is left out.
    worker = Worker(frames.put, youtube_dl=YoutubeDL, ytmusic=object)
    worker.start()
    assert frames.get(timeout=5)["event"] == "ready"
    worker._download(
        "task",
        url,
        directory,
        {
            "outtmpl": "%(title)s.%(ext)s",
            "quiet": True,
            "noprogress": True,
            "final_ext": "mp3",
            "postprocessors": postprocessors,
        },
    )


def test_a_partial_stream_carries_on_from_where_it_stopped(
    tmp_path, audio, server
) -> None:
    url, ranges = server
    staging = tmp_path / "staging"
    staging.mkdir()
    (staging / "song.mp3.part").write_bytes(audio[:1000])

    download(staging, url, [])

    assert ranges[-1] == "bytes=1000-"
    assert (staging / "song.mp3").read_bytes() == audio


def test_a_partial_stream_of_another_format_starts_again(
    tmp_path, audio, server
) -> None:
    url, ranges = server
    staging = tmp_path / "staging"
    staging.mkdir()
    (staging / ".melody-stream-format").write_text("another", encoding="utf-8")
    (staging / "song.mp3.part").write_bytes(b"bytes of another format")

    download(staging, url, [])

    assert ranges[-1] is None
    assert (staging / "song.mp3").read_bytes() == audio


def test_a_finished_song_is_not_downloaded_again(tmp_path, audio, server) -> None:
    url, ranges = server
    staging = tmp_path / "staging"
    staging.mkdir()
    extract = [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3"}]
    download(staging, url, extract)
    before = len(ranges)
    (staging / "song.mp3").write_bytes(audio)

    download(staging, url, extract)

    # The extractor looks at the link once more, but downloads nothing.
    assert len(ranges) <= before + 1
    assert (staging / "song.mp3").read_bytes() == audio


def test_a_cover_that_cannot_be_embedded_keeps_the_audio(
    tmp_path, audio, server, monkeypatch
) -> None:
    from yt_dlp.postprocessor.embedthumbnail import (
        EmbedThumbnailPP,
        EmbedThumbnailPPError,
    )

    def fail(self, information):
        raise EmbedThumbnailPPError("Conversion failed!")

    monkeypatch.setattr(EmbedThumbnailPP, "run", fail)
    url, _ = server
    staging = tmp_path / "staging"
    staging.mkdir()

    download(
        staging,
        url,
        [
            {"key": "FFmpegExtractAudio", "preferredcodec": "mp3"},
            {"key": "EmbedThumbnail", "already_have_thumbnail": True},
        ],
    )

    assert (staging / "song.mp3").read_bytes()[:3] in {b"ID3", audio[:3]}
    assert [item.name for item in staging.glob("*.temp.*")] == []
