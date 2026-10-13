"""PyPI release discovery and wheel downloads over verified HTTPS."""

from __future__ import annotations

import functools
import json
import logging
import os
import ssl
import time
import urllib.request
import zlib
from pathlib import Path
from urllib.parse import urljoin, urlsplit

from .constants import (
    MAX_DOWNLOAD_SECONDS,
    MAX_INDEX_BYTES,
    MAX_WHEEL_BYTES,
    SHA256_HEX,
    SIMPLE_JSON,
)
from .packages import RuntimePackage
from .records import RemoteRelease
from .wheels import parse_wheel_name, python_compatible

logger = logging.getLogger(__name__)


@functools.cache
def ssl_context() -> ssl.SSLContext:
    """A verifying TLS context that works inside the embedded interpreter.

    ``ssl.create_default_context()`` relies on OpenSSL's compiled-in CA
    paths, which do not exist in Melody's embedded Python on Android, iOS,
    and some desktop builds, so every HTTPS request fails certificate
    verification there. certifi's bundle (shipped for ``requests``) is added
    on top of the system store; it is loaded from memory because Android
    imports site-packages from a zip.
    """
    context = ssl.create_default_context()
    try:
        import certifi

        context.load_verify_locations(cadata=certifi.contents())
    except Exception as error:  # noqa: BLE001 - fall back to the system store
        logger.warning("Could not load certifi CA certificates: %s", error)
    return context


def fetch_remote_release(
    url: str, timeout: float, package: RuntimePackage
) -> RemoteRelease | None:
    """The newest allowed, non-yanked ``py3-none-any`` wheel in PyPI's JSON
    simple index, or ``None`` when no release qualifies.

    The index lists every release, so a newer release outside
    ``package.allowed`` never hides the newest compatible one.
    """
    request = urllib.request.Request(
        url,
        headers={
            "Accept": SIMPLE_JSON,
            # urllib never asks for compression; gzip makes yt-dlp's index
            # (every release it ever published) about a quarter of the size.
            "Accept-Encoding": "gzip",
            "User-Agent": "Melody/package-updater",
        },
    )
    with urllib.request.urlopen(
        request, timeout=timeout, context=ssl_context()
    ) as response:
        index_url = response.geturl()
        if not index_url.startswith("https://"):
            raise ValueError("Update metadata requires HTTPS")
        encoded = response.read(MAX_INDEX_BYTES + 1)
        compressed = response.headers.get("Content-Encoding") == "gzip"
    if compressed:
        # Bounded, so a small compressed body cannot expand without limit.
        decompressor = zlib.decompressobj(wbits=zlib.MAX_WBITS | 16)
        encoded = decompressor.decompress(encoded, MAX_INDEX_BYTES + 1)
    if len(encoded) > MAX_INDEX_BYTES:
        raise ValueError("Update metadata exceeds the size limit")
    payload = json.loads(encoded)
    files = payload.get("files") if isinstance(payload, dict) else None
    if not isinstance(files, list):
        raise ValueError("PyPI returned an unexpected package index")  # noqa: TRY004 - bad remote data
    best: RemoteRelease | None = None
    for item in files:
        release = _release_from_index_file(item, index_url, package)
        if release is not None and (best is None or release.version > best.version):
            best = release
    return best


def _release_from_index_file(
    item: object, index_url: str, package: RuntimePackage
) -> RemoteRelease | None:
    """One file entry of a PEP 691 index, if Melody could install it."""
    if not isinstance(item, dict):
        return None
    filename = item.get("filename")
    if not isinstance(filename, str):
        return None
    parsed = parse_wheel_name(filename, package)
    if parsed is None or not package.permits(parsed[0]):
        return None
    if item.get("yanked") not in (None, False):
        return None
    requires_python = item.get("requires-python")
    if (
        isinstance(requires_python, str)
        and requires_python.strip()
        and not python_compatible(requires_python)
    ):
        return None
    hashes = item.get("hashes")
    sha256 = hashes.get("sha256") if isinstance(hashes, dict) else None
    if not isinstance(sha256, str) or SHA256_HEX.fullmatch(sha256) is None:
        return None
    raw_url = item.get("url")
    if not isinstance(raw_url, str):
        return None
    # PEP 691 allows URLs relative to the index.
    wheel_url = urljoin(index_url, raw_url)
    parsed_url = urlsplit(wheel_url)
    if parsed_url.scheme != "https" or parsed_url.hostname != "files.pythonhosted.org":
        return None
    return RemoteRelease(parsed[0], filename, wheel_url, sha256)


def download_file(url: str, destination: Path, timeout: float) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Melody/package-updater"},
    )
    with (
        urllib.request.urlopen(
            request, timeout=timeout, context=ssl_context()
        ) as response,
        destination.open("wb") as stream,
    ):
        if not response.geturl().startswith("https://"):
            raise ValueError("Wheel download requires HTTPS")
        size = 0
        deadline = time.monotonic() + MAX_DOWNLOAD_SECONDS
        # read1 returns after one socket read, so a trickling server cannot
        # hold a single call open past the deadline check.
        while chunk := response.read1(1024 * 1024):
            size += len(chunk)
            if size > MAX_WHEEL_BYTES:
                raise ValueError("Wheel download exceeds the size limit")
            if time.monotonic() > deadline:
                raise TimeoutError(
                    f"Wheel download took longer than {MAX_DOWNLOAD_SECONDS:.0f} seconds"
                )
            stream.write(chunk)
        stream.flush()
        os.fsync(stream.fileno())
