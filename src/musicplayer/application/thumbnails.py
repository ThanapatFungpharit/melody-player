"""Durable, offline-first thumbnail storage.

The authoritative artwork is embedded in each downloaded media file. The UI
renders a URL-keyed copy. Native Flet images receive the cache file path so
Flutter can load it without Python reading and sending every image on the UI
thread. Web images still receive bytes for access to the private cache.
Native media sessions receive a file URI for the same derived cache entry.
"""

from __future__ import annotations

import hashlib
import logging
import stat
import threading
from collections import OrderedDict
from pathlib import Path
from urllib.parse import urlsplit

from musicplayer.core.storage import atomic_write

logger = logging.getLogger(__name__)

_MAX_THUMBNAIL_BYTES = 8 * 1024 * 1024
_MEMORY_CACHE_ENTRIES = 32
_MEMORY_CACHE_BYTES = 16 * 1024 * 1024


class ThumbnailCache:
    """Store thumbnail bytes by source URL and prefer them for every read."""

    def __init__(
        self,
        directory: str | Path,
    ) -> None:
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        # Serializes the rare artwork writes; concurrent replacement of one
        # destination can fail on Windows. Reads never wait for a write.
        self._write_lock = threading.Lock()
        self._memory: OrderedDict[str, bytes] = OrderedDict()
        self._memory_bytes = 0
        self.native_image_sources = False

    def cached_path(self, url: str) -> Path | None:
        """Return the durable entry for a remote URL without touching network."""
        key = _remote_key(url)
        if key is None:
            return None
        path = self.directory / f"{key}.thumb"
        try:
            metadata = path.stat()
            return (
                path
                if stat.S_ISREG(metadata.st_mode) and metadata.st_size > 0
                else None
            )
        except OSError:
            return None

    def image_source(self, source: str | bytes) -> str | bytes:
        """Resolve to cached bytes when possible, otherwise preserve *source*."""
        if isinstance(source, bytes) or not source:
            return source
        path = self.cached_path(source)
        if path is None:
            return source
        key = path.stem
        with self._lock:
            cached = self._memory.get(key)
            if cached is not None:
                self._memory.move_to_end(key)
                return cached
        try:
            data = path.read_bytes()
            _validate_image(data)
        except OSError, ValueError:
            logger.warning("Ignoring invalid cached thumbnail: path=%s", path)
            return source
        self._remember(key, data)
        return data

    def display_source(self, source: str | bytes) -> str | bytes:
        """Use a local file on native UI; retain byte sources for web clients."""
        if not self.native_image_sources or isinstance(source, bytes) or not source:
            return self.image_source(source)
        path = self.cached_path(source)
        return str(path.absolute()) if path is not None else source

    def artwork_uri(self, source: str) -> str:
        """Resolve artwork for an operating-system media session."""
        path = self.cached_path(source)
        return path.resolve().as_uri() if path is not None else source

    def store_bytes(self, url: str, data: bytes) -> bool:
        """Atomically retain image bytes already downloaded with the media."""
        key = _remote_key(url)
        if key is None or not data:
            return False
        try:
            _validate_image(data)
        except ValueError:
            logger.warning("Downloaded thumbnail has an unsupported image format")
            return False
        try:
            with self._write_lock:
                # Replace even a non-empty entry: a previous process or manual
                # disk edit may have left corrupt cache bytes at this key.
                atomic_write(self.directory / f"{key}.thumb", data)
        except OSError:
            logger.warning("Could not cache thumbnail: url=%s", url, exc_info=True)
            return False
        self._remember(key, data)
        return True

    def _remember(self, key: str, data: bytes) -> None:
        with self._lock:
            previous = self._memory.pop(key, None)
            if previous is not None:
                self._memory_bytes -= len(previous)
            if len(data) > _MEMORY_CACHE_BYTES:
                return
            self._memory[key] = data
            self._memory_bytes += len(data)
            self._memory.move_to_end(key)
            while (
                len(self._memory) > _MEMORY_CACHE_ENTRIES
                or self._memory_bytes > _MEMORY_CACHE_BYTES
            ):
                _, removed = self._memory.popitem(last=False)
                self._memory_bytes -= len(removed)


def _remote_key(url: str) -> str | None:
    parsed = urlsplit(str(url).strip())
    if parsed.scheme.casefold() not in {"http", "https"} or not parsed.netloc:
        return None
    return hashlib.sha256(str(url).strip().encode("utf-8")).hexdigest()


def _validate_image(data: bytes) -> None:
    if not data or len(data) > _MAX_THUMBNAIL_BYTES:
        raise ValueError("Thumbnail is empty or exceeds the size limit")
    supported = (
        data.startswith(b"\xff\xd8\xff"),
        data.startswith(b"\x89PNG\r\n\x1a\n"),
        data.startswith((b"GIF87a", b"GIF89a")),
        len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP",
        data.startswith(b"BM"),
    )
    if not any(supported):
        raise ValueError("Unsupported thumbnail format")


__all__ = ["ThumbnailCache"]
