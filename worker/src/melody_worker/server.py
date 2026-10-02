"""Request loop for Melody's embedded yt-dlp worker.

The Flutter application owns every policy decision: which options to pass,
where to stage files, how to classify failures, and what to do with results.
This process only selects the yt-dlp runtime and runs it.

Frames are UTF-8 JSON objects. The app sends ``{"id", "op", ...}``; the worker
answers each request once with ``{"id", "ok": true, "result"}`` or
``{"id", "ok": false, "error"}`` and may emit ``{"event", ...}`` frames, such
as download progress, at any time.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .updater import UpdateResult, YtDlpUpdater, prepare_yt_dlp

logger = logging.getLogger(__name__)

Send = Callable[[dict[str, Any]], None]

# Fields the app reads from yt-dlp info dictionaries. Everything else stays
# here, so a frame never carries formats, cookies, or HTTP headers.
_INFO_FIELDS = (
    "_type",
    "id",
    "url",
    "webpage_url",
    "original_url",
    "title",
    "uploader",
    "channel",
    "creator",
    "duration",
    "thumbnail",
    "playlist_title",
    "extractor",
    "extractor_key",
)
_THUMBNAIL_FIELDS = ("url", "width", "height", "preference")
_PROGRESS_INTERVAL = 0.1
# Network-bound extraction and FFmpeg-bound downloads. The app enforces the
# user's download concurrency; this only bounds the worker's own threads.
_MAX_THREADS = 12


class DownloadCancelled(Exception):
    """Raised from a progress hook to stop a cancelled yt-dlp job."""


class Worker:
    def __init__(
        self,
        send: Send,
        *,
        storage_directory: Path | None,
        check_remote: bool = False,
        youtube_dl: Any = None,
    ) -> None:
        self._send_frame = send
        self._send_lock = threading.Lock()
        self._storage_directory = storage_directory
        self._check_remote = check_remote
        self._youtube_dl = youtube_dl
        self._ready = threading.Event()
        self._selection: UpdateResult | None = None
        self._selection_error = ""
        self._pool = ThreadPoolExecutor(
            max_workers=_MAX_THREADS, thread_name_prefix="melody-worker"
        )
        self._cancelled: set[str] = set()
        self._cancel_lock = threading.Lock()

    # -- lifecycle -------------------------------------------------------
    def start(self) -> None:
        """Select yt-dlp in the background, then announce readiness."""
        threading.Thread(
            target=self._prepare, name="melody-yt-dlp-prepare", daemon=True
        ).start()

    def _prepare(self) -> None:
        try:
            if self._youtube_dl is None:
                self._selection = prepare_yt_dlp(
                    storage_directory=self._storage_directory,
                    check_remote=self._check_remote,
                )
                from yt_dlp import YoutubeDL

                self._youtube_dl = YoutubeDL
        except Exception as error:  # reported to the app
            logger.exception("yt-dlp could not be prepared")
            self._selection_error = str(error) or type(error).__name__
        finally:
            self._ready.set()
            self._emit({"event": "ready", "status": self._status()})

    def _status(self) -> dict[str, Any]:
        selection = asdict(self._selection) if self._selection else {}
        if self._selection_error:
            selection["errors"] = [
                *selection.get("errors", ()),
                self._selection_error,
            ]
        selection["available"] = self._youtube_dl is not None
        return selection

    # -- transport -------------------------------------------------------
    def receive(self, payload: bytes) -> None:
        try:
            frame = json.loads(payload.decode("utf-8"))
        except UnicodeDecodeError, json.JSONDecodeError:
            logger.warning("Ignoring an unreadable frame")
            return
        if not isinstance(frame, dict) or "id" not in frame:
            return
        if frame.get("op") == "cancel":
            # Never queue cancellation behind the work it cancels.
            self._respond(frame["id"], self._cancel, frame)
            return
        self._pool.submit(self._respond, frame["id"], self._dispatch, frame)

    def _emit(self, frame: dict[str, Any]) -> None:
        with self._send_lock:
            try:
                self._send_frame(frame)
            except Exception:  # a closed app must not kill workers
                logger.debug("Could not deliver a frame", exc_info=True)

    def _respond(
        self,
        request_id: Any,
        handler: Callable[[dict[str, Any]], Any],
        frame: dict[str, Any],
    ) -> None:
        try:
            result = handler(frame)
        except Exception as error:  # noqa: BLE001 - every failure is reported
            self._emit({"id": request_id, "ok": False, "error": describe(error)})
        else:
            self._emit({"id": request_id, "ok": True, "result": result})

    def _dispatch(self, frame: dict[str, Any]) -> Any:
        operation = frame.get("op")
        if operation == "status":
            self._ready.wait()
            return self._status()
        if operation == "latest_release":
            return self._latest_release()
        if operation == "extract":
            return self._extract(str(frame["target"]), dict(frame.get("options") or {}))
        if operation == "download":
            return self._download(
                str(frame["task"]),
                str(frame["url"]),
                Path(str(frame["directory"])),
                dict(frame.get("options") or {}),
            )
        raise ValueError(f"Unknown worker operation: {operation!r}")

    # -- operations ------------------------------------------------------
    def _client(self) -> Any:
        self._ready.wait()
        if self._youtube_dl is None:
            raise RuntimeError(
                self._selection_error or "yt-dlp is unavailable in this installation"
            )
        return self._youtube_dl

    def _extract(self, target: str, options: dict[str, Any]) -> dict[str, Any] | None:
        youtube_dl = self._client()
        with youtube_dl(options) as client:
            info = client.extract_info(target, download=False)
        return sanitize_info(info) if isinstance(info, dict) else None

    def _download(
        self, task: str, url: str, directory: Path, options: dict[str, Any]
    ) -> dict[str, Any]:
        youtube_dl = self._client()
        if not directory.is_dir():
            raise FileNotFoundError(f"Staging directory is missing: {directory}")
        last_sent = 0.0
        last_status = ""

        def hook(data: dict[str, Any]) -> None:
            nonlocal last_sent, last_status
            if self._is_cancelled(task):
                raise DownloadCancelled
            status = "processing" if data.get("status") == "finished" else "downloading"
            now = time.monotonic()
            if status == last_status and now - last_sent < _PROGRESS_INTERVAL:
                return
            last_sent, last_status = now, status
            info = data.get("info_dict") or {}
            self._emit(
                {
                    "event": "progress",
                    "task": task,
                    "status": status,
                    "downloaded_bytes": _integer(data.get("downloaded_bytes")),
                    "total_bytes": _integer(
                        data.get("total_bytes") or data.get("total_bytes_estimate")
                    ),
                    "filename": str(data.get("filename") or ""),
                    "title": str(info.get("title") or ""),
                    "uploader": str(
                        info.get("uploader")
                        or info.get("channel")
                        or info.get("creator")
                        or ""
                    ),
                    "thumbnail": str(info.get("thumbnail") or ""),
                }
            )

        merged = {
            **options,
            "paths": {"home": str(directory)},
            "progress_hooks": [hook],
        }
        try:
            if self._is_cancelled(task):
                return {"cancelled": True}
            with youtube_dl(merged) as client:
                client.download([url])
        except Exception as error:
            if self._is_cancelled(task) or any(
                isinstance(item, DownloadCancelled) for item in _chain(error)
            ):
                return {"cancelled": True}
            raise
        finally:
            with self._cancel_lock:
                self._cancelled.discard(task)
        return {"cancelled": False}

    def _cancel(self, frame: dict[str, Any]) -> bool:
        with self._cancel_lock:
            self._cancelled.add(str(frame["task"]))
        return True

    def _is_cancelled(self, task: str) -> bool:
        with self._cancel_lock:
            return task in self._cancelled

    def _latest_release(self) -> dict[str, str] | None:
        release = YtDlpUpdater(
            storage_directory=self._storage_directory
        ).latest_release()
        if release is None:
            return None
        return {"version": str(release.version), "filename": release.filename}


def sanitize_info(info: dict[str, Any], *, depth: int = 0) -> dict[str, Any]:
    """Keep only JSON-safe fields the application reads."""
    result: dict[str, Any] = {
        key: info[key]
        for key in _INFO_FIELDS
        if isinstance(info.get(key), (str, int, float, bool))
    }
    thumbnails = info.get("thumbnails")
    if isinstance(thumbnails, list):
        result["thumbnails"] = [
            {
                key: item[key]
                for key in _THUMBNAIL_FIELDS
                if isinstance(item.get(key), (str, int, float))
            }
            for item in thumbnails
            if isinstance(item, dict)
        ]
    entries = info.get("entries")
    if entries is not None and depth == 0:
        # Lazy playlists yield entries; flat extraction keeps each one small.
        result["entries"] = [
            sanitize_info(entry, depth=1) if isinstance(entry, dict) else None
            for entry in entries
        ]
    return result


def describe(error: BaseException) -> dict[str, Any]:
    """Expose the facts the app needs to classify a failure."""
    chain = _chain(error)
    return {
        "message": str(error) or type(error).__name__,
        "chain": [str(item) for item in chain[1:] if str(item)],
        "types": [type(item).__name__ for item in chain],
        "errnos": [
            item.errno
            for item in chain
            if isinstance(item, OSError) and isinstance(item.errno, int)
        ],
        "codes": [
            str(code)
            for item in chain
            if (code := getattr(item, "status", getattr(item, "code", None)))
            is not None
        ],
        "timeout": any(isinstance(item, TimeoutError) for item in chain),
        "connection": any(isinstance(item, ConnectionError) for item in chain),
    }


def _chain(error: BaseException) -> list[BaseException]:
    chain: list[BaseException] = []
    pending: list[BaseException | None] = [error]
    while pending:
        current = pending.pop(0)
        if current is None or any(current is item for item in chain):
            continue
        chain.append(current)
        # yt-dlp's DownloadError keeps the original exception in exc_info.
        exc_info = getattr(current, "exc_info", None)
        if isinstance(exc_info, tuple) and len(exc_info) > 1:
            original = exc_info[1]
            if isinstance(original, BaseException):
                pending.append(original)
        pending.extend((current.__cause__, current.__context__))
    return chain


def _integer(value: object) -> int:
    try:
        return max(0, int(value or 0))  # type: ignore[call-overload]
    except TypeError, ValueError, OverflowError:
        return 0
