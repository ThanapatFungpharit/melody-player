"""Request loop for Melody's embedded Python worker.

The worker hosts two libraries with no Dart equivalent: ytmusicapi, which
reads YouTube Music (search, radio, playlists, lyrics), and yt-dlp, which
resolves streams and downloads audio.

The Flutter application owns every policy decision: which options to pass,
where to stage files, how to classify failures, and what to do with results.
This process only selects each library's runtime and runs it.

Frames are UTF-8 JSON objects. The app sends ``{"id", "op", ...}``; the worker
answers each request once with ``{"id", "ok": true, "result"}`` or
``{"id", "ok": false, "error"}`` and may emit ``{"event", ...}`` frames, such
as download progress, at any time.

A new app session (see :meth:`Worker.restart_session`) invalidates every
request from the previous one: their replies are dropped and their downloads
are cancelled, because the new session reuses request ids.
"""

from __future__ import annotations

import dataclasses
import importlib
import json
import locale
import logging
import math
import threading
import time
from collections.abc import Callable, Collection, Mapping
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from .updater import (
    PACKAGES,
    YT_DLP,
    YTMUSICAPI,
    PackageUpdater,
    UpdateResult,
    prepare_package,
)

logger = logging.getLogger(__name__)

# yt-dlp and ytmusicapi are imported only once Worker._prepare has selected
# their runtimes; importing either at module level pins the bundled release.

Send = Callable[[dict[str, Any]], None]

# The class each package's client is built from, by distribution.
_CLIENT_CLASSES = {YT_DLP.distribution: "YoutubeDL", YTMUSICAPI.distribution: "YTMusic"}
# ytmusicapi methods the app calls (see app/lib/application/catalog.dart).
# All are anonymous reads; anything else, such as get_song with its signed
# stream URLs, is refused.
_YTMUSIC_METHODS = frozenset(
    {"search", "get_watch_playlist", "get_lyrics", "get_playlist"}
)
_MAX_JSON_DEPTH = 32

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
        runtime_directories: Mapping[str, Path | None] | None = None,
        check_remote: Collection[str] = (),
        youtube_dl: Any = None,
        ytmusic: Any = None,
        ffmpeg: Any = None,
    ) -> None:
        """``runtime_directories`` and ``check_remote`` are keyed by
        distribution name; ``youtube_dl`` and ``ytmusic`` replace the real
        client classes, and ``ffmpeg`` yt-dlp's FFmpegPostProcessor (tests)."""
        self._ffmpeg = ffmpeg
        self._send_frame = send
        # Reentrant: restart_session switches the transport while holding it,
        # and a bridge may deliver queued frames (and so replies) right then.
        self._send_lock = threading.RLock()
        self._runtime_directories = dict(runtime_directories or {})
        self._check_remote = frozenset(check_remote)
        self._clients: dict[str, Any] = {
            YT_DLP.distribution: youtube_dl,
            YTMUSICAPI.distribution: ytmusic,
        }
        self._ready = threading.Event()
        self._selections: dict[str, UpdateResult] = {}
        self._selection_errors: dict[str, str] = {}
        self._music_local = threading.local()
        self._music_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(
            max_workers=_MAX_THREADS, thread_name_prefix="melody-worker"
        )
        self._cancelled: set[str] = set()
        self._downloading: set[str] = set()
        self._cancel_lock = threading.Lock()
        self._session = 0

    # -- lifecycle -------------------------------------------------------
    def start(self) -> None:
        """Select each package in the background, then announce readiness."""
        threading.Thread(
            target=self._prepare, name="melody-runtime-prepare", daemon=True
        ).start()

    def _prepare(self) -> None:
        try:
            pending = [
                (name, package)
                for name, package in PACKAGES.items()
                if self._clients[name] is None
            ]
            # Packages are selected one at a time, but their release lookups
            # are independent: start them all now so each package's network
            # round trip overlaps the others' validation and downloads.
            releases = {
                name: self._pool.submit(
                    PackageUpdater(
                        package, storage_directory=self._runtime_directories.get(name)
                    ).latest_release
                )
                for name, package in pending
                if name in self._check_remote
            }
            for name, package in pending:
                release = releases.get(name)
                try:
                    self._selections[name] = prepare_package(
                        package,
                        storage_directory=self._runtime_directories.get(name),
                        check_remote=release is not None,
                        fetch_remote=(
                            (lambda _url, release=release: release.result())
                            if release is not None
                            else None
                        ),
                    )
                    module = importlib.import_module(package.module)
                    if not package.zip_safe:
                        require_unpacked(module)
                    self._clients[name] = getattr(module, _CLIENT_CLASSES[name])
                except Exception as error:  # reported to the app
                    logger.exception("%s could not be prepared", name)
                    self._selection_errors[name] = str(error) or type(error).__name__
        finally:
            self._ready.set()
            self._emit({"event": "ready", "status": self._status()})

    def restart_session(self, connect: Callable[[], None] | None = None) -> None:
        """Serve a new app session: forget the old one and announce readiness.

        ``connect`` points the transport at the new session. It runs once the
        new session is current and while no frame is being sent, so requests
        from the new session are never mistaken for old ones and no reply to
        the old session reaches the new one."""
        with self._send_lock:
            with self._cancel_lock:
                self._session += 1
                self._cancelled.update(self._downloading)
            if connect is not None:
                connect()
        if self._ready.is_set():
            self._emit({"event": "ready", "status": self._status()})

    def _status(self) -> dict[str, Any]:
        packages: dict[str, Any] = {}
        for name in PACKAGES:
            selected = self._selections.get(name)
            selection = dataclasses.asdict(selected) if selected else {}
            if error := self._selection_errors.get(name):
                selection["errors"] = [*selection.get("errors", ()), error]
            selection["available"] = self._clients[name] is not None
            packages[name] = selection
        return {"packages": packages}

    # -- transport -------------------------------------------------------
    def receive(self, payload: bytes) -> None:
        try:
            frame = json.loads(payload.decode("utf-8"))
        except UnicodeDecodeError, json.JSONDecodeError:
            logger.warning("Ignoring an unreadable frame")
            return
        if not isinstance(frame, dict) or "id" not in frame:
            return
        session = self._session
        if frame.get("op") == "cancel":
            # Never queue cancellation behind the work it cancels.
            self._respond(session, frame["id"], self._cancel, frame)
            return
        self._pool.submit(self._respond, session, frame["id"], self._dispatch, frame)

    def _emit(
        self, frame: dict[str, Any], *, session: int | None = None
    ) -> Exception | None:
        """Send ``frame``, or nothing when it answers a superseded ``session``.
        Returns the failure, if sending raised."""
        with self._send_lock:
            if session is not None and session != self._session:
                return None
            try:
                self._send_frame(frame)
            except Exception as error:  # a closed app must not kill workers
                logger.debug("Could not deliver a frame", exc_info=True)
                return error
        return None

    def _respond(
        self,
        session: int,
        request_id: Any,
        handler: Callable[[dict[str, Any], int], Any],
        frame: dict[str, Any],
    ) -> None:
        if session != self._session:
            return  # superseded while queued; nobody waits for this reply
        try:
            reply = {"id": request_id, "ok": True, "result": handler(frame, session)}
        except Exception as error:  # noqa: BLE001 - every failure is reported
            reply = {"id": request_id, "ok": False, "error": describe(error)}
        failure = self._emit(reply, session=session)
        if failure is not None and reply["ok"]:
            # The result could not be encoded (such as a NaN); the request
            # still gets its one reply.
            self._emit(
                {"id": request_id, "ok": False, "error": describe(failure)},
                session=session,
            )

    def _dispatch(self, frame: dict[str, Any], session: int) -> Any:
        operation = frame.get("op")
        if operation == "latest_release":
            return self._latest_release(str(frame.get("package") or "yt-dlp"))
        if operation == "ytmusic":
            return self._ytmusic(_text(frame, "method"), _mapping(frame, "arguments"))
        if operation == "extract":
            return self._extract(_text(frame, "target"), _mapping(frame, "options"))
        if operation == "download":
            return self._download(
                _text(frame, "task"),
                _text(frame, "url"),
                Path(_text(frame, "directory")),
                _mapping(frame, "options"),
                _tags(frame),
                session,
            )
        if operation == "tag":
            return self._tag(
                Path(_text(frame, "source")),
                Path(_text(frame, "target")),
                _tags(frame),
                _mapping(frame, "options"),
            )
        raise ValueError(f"Unknown worker operation: {operation!r}")

    # -- operations ------------------------------------------------------
    def _client(self, name: str = YT_DLP.distribution) -> Any:
        self._ready.wait()
        client = self._clients[name]
        if client is None:
            raise RuntimeError(
                self._selection_errors.get(name)
                or f"{name} is unavailable in this installation"
            )
        return client

    def _music(self) -> Any:
        """This thread's YouTube Music client; sessions are not thread-safe."""
        client = getattr(self._music_local, "client", None)
        if client is None:
            factory = self._client(YTMUSICAPI.distribution)
            # YTMusic() sets the process locale, which the embedding app
            # shares; restore it once the client exists.
            with self._music_lock:
                saved = locale.setlocale(locale.LC_ALL)
                try:
                    client = factory()
                finally:
                    try:
                        locale.setlocale(locale.LC_ALL, saved)
                    except locale.Error:
                        # Some platforms report a composite locale they
                        # cannot set back; that must not fail the client.
                        logger.warning("Could not restore the locale %r", saved)
            self._music_local.client = client
        return client

    def _ytmusic(self, method: str, arguments: dict[str, Any]) -> Any:
        if method not in _YTMUSIC_METHODS:
            raise ValueError(f"Unsupported YouTube Music method: {method!r}")
        return json_safe(getattr(self._music(), method)(**arguments))

    def _extract(self, target: str, options: dict[str, Any]) -> dict[str, Any] | None:
        youtube_dl = self._client()
        with youtube_dl(options) as client:
            info = client.extract_info(target, download=False)
        return sanitize_info(info) if isinstance(info, dict) else None

    def _download(
        self,
        task: str,
        url: str,
        directory: Path,
        options: dict[str, Any],
        metadata: dict[str, str] | None = None,
        session: int | None = None,
    ) -> dict[str, Any]:
        """Download ``url`` into ``directory``. ``metadata`` adds tags, such as
        ``lyrics``, that FFmpegMetadata writes into the file. A download for a
        superseded ``session`` is cancelled."""
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
        with self._cancel_lock:
            self._downloading.add(task)
            if session is not None and session != self._session:
                self._cancelled.add(task)
        try:
            # Registered first: a new session while package selection is still
            # running (the wait below) cancels this download too.
            youtube_dl = self._client()
            if not directory.is_dir():
                raise FileNotFoundError(f"Staging directory is missing: {directory}")
            if self._is_cancelled(task):
                return {"cancelled": True}
            with youtube_dl(merged) as client:
                if metadata:
                    client.add_post_processor(
                        metadata_fields(metadata), when="pre_process"
                    )
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
                self._downloading.discard(task)
        return {"cancelled": False}

    def _tag(
        self,
        source: Path,
        target: Path,
        metadata: dict[str, str],
        options: dict[str, Any],
    ) -> None:
        """Write ``source`` to ``target`` with every stream and tag copied and
        ``metadata`` tags, such as ``lyrics``, set. FFmpeg runs through yt-dlp
        so ``ffmpeg_location`` in ``options`` applies as it does to downloads."""
        youtube_dl = self._client()
        ffmpeg = self._ffmpeg
        if ffmpeg is None:
            from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor as ffmpeg
        tags = [
            argument
            for key, value in metadata.items()
            for argument in ("-metadata", f"{key}={value}")
        ]
        with youtube_dl(options) as client:
            processor = ffmpeg(client)
            processor.run_ffmpeg(
                str(source),
                str(target),
                [
                    *processor.stream_copy_opts(ext=target.suffix.lstrip(".")),
                    "-map_metadata",
                    "0",
                    *tags,
                ],
            )

    def _cancel(self, frame: dict[str, Any], _session: int) -> bool:
        task = _text(frame, "task")
        with self._cancel_lock:
            self._cancelled.add(task)
        return True

    def _is_cancelled(self, task: str) -> bool:
        with self._cancel_lock:
            return task in self._cancelled

    def _latest_release(self, name: str) -> dict[str, str] | None:
        package = PACKAGES.get(name)
        if package is None:
            raise ValueError(f"Unknown runtime package: {name!r}")
        release = PackageUpdater(
            package, storage_directory=self._runtime_directories.get(name)
        ).latest_release()
        if release is None:
            return None
        return {"version": str(release.version), "filename": release.filename}


def require_unpacked(module: Any) -> None:
    """Fail when a package that reads its own data files was imported from an
    archive. Android zip-imports site-packages from ``sitepackages.zip``
    unless the build lists the package in ``SERIOUS_PYTHON_ANDROID_EXTRACT_PACKAGES``;
    ytmusicapi would then import but fail every ``YTMusic()`` on its gettext
    catalogs."""
    package_directory = Path(str(getattr(module, "__file__", "") or "")).parent
    if not package_directory.is_dir():
        raise RuntimeError(
            f"{module.__name__} was imported from an archive ({package_directory}) "
            "and cannot read its data files; it must be packaged unpacked"
        )


def metadata_fields(fields: dict[str, str]) -> Any:
    """A yt-dlp postprocessor that sets ``meta_<key>`` info fields, which
    FFmpegMetadata writes as tags with those keys."""
    from yt_dlp.postprocessor.common import PostProcessor

    class MetadataFields(PostProcessor):
        def run(self, information: dict[str, Any]) -> tuple[list[str], dict[str, Any]]:
            for key, value in fields.items():
                information[f"meta_{key}"] = value
            return [], information

    return MetadataFields()


def json_safe(value: Any, *, depth: int = 0) -> Any:
    """Convert a ytmusicapi reply to JSON: dataclasses become objects, and
    values JSON cannot carry (such as NaN) are dropped."""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if depth >= _MAX_JSON_DEPTH:
        return None
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        value = dataclasses.asdict(value)
    if isinstance(value, Mapping):
        return {
            str(key): json_safe(item, depth=depth + 1)
            for key, item in value.items()
            if isinstance(key, (str, int))
        }
    if isinstance(value, (list, tuple)):
        return [json_safe(item, depth=depth + 1) for item in value]
    return None


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


def _text(frame: Mapping[str, Any], key: str) -> str:
    """A required, non-empty string field of a request."""
    value = frame.get(key)
    if not isinstance(value, str) or not value:
        raise TypeError(f"The request needs a non-empty {key!r} string")
    return value


def _mapping(frame: Mapping[str, Any], key: str) -> dict[str, Any]:
    """An optional object field of a request; absent or null means empty."""
    value = frame.get(key)
    if value is None:
        return {}
    if not isinstance(value, Mapping):
        raise TypeError(f"The request's {key!r} must be an object")
    return dict(value)


def _tags(frame: Mapping[str, Any]) -> dict[str, str]:
    return {
        str(key): str(value)
        for key, value in _mapping(frame, "metadata").items()
        if value is not None
    }


def _integer(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except TypeError, ValueError, OverflowError:
        return 0
