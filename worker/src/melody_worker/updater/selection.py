"""Once-per-process runtime selection, made before a package's first import."""

from __future__ import annotations

import logging
from contextlib import ExitStack
from pathlib import Path

from packaging.version import Version

from ..file_lock import exclusive_file_lock
from .constants import DEFAULT_TIMEOUT
from .package_updater import PREPARE_LOCK, PackageUpdater
from .packages import RuntimePackage
from .records import DownloadFunction, RemoteFunction, UpdateResult

logger = logging.getLogger(__name__)

_STARTUP_RESULTS: dict[str, UpdateResult] = {}
_SESSION = ExitStack()


def prepare_package(
    package: RuntimePackage,
    *,
    storage_directory: str | Path | None = None,
    bundled_version: str | Version | None = None,
    metadata_url: str | None = None,
    timeout: float = DEFAULT_TIMEOUT,
    download: DownloadFunction | None = None,
    fetch_remote: RemoteFunction | None = None,
    check_remote: bool = False,
) -> UpdateResult:
    """Select ``package`` once per process, before its first import.

    Blocking filesystem and network work: call it from a worker thread. The
    first call's result is reused for the process lifetime. Failures are
    diagnostics in the result; the bundled package always remains usable.

    Unlike :class:`PackageUpdater`, ``check_remote`` defaults to ``False``:
    startup selection only contacts PyPI when the app opts in for a launch.
    """

    updater = PackageUpdater(
        package,
        storage_directory=storage_directory,
        bundled_version=bundled_version,
        metadata_url=metadata_url,
        timeout=timeout,
        download=download,
        fetch_remote=fetch_remote,
        check_remote=check_remote,
    )
    with PREPARE_LOCK:
        if (cached := _STARTUP_RESULTS.get(package.distribution)) is not None:
            return cached
        try:
            storage = updater._storage()
            try:
                # Hold for the process lifetime so another running application
                # cannot prune a wheel that this interpreter may still import.
                _SESSION.enter_context(exclusive_file_lock(storage / "session.lock"))
            except OSError as error:
                raise RuntimeError(
                    f"{storage} is in use by another running Melody instance; "
                    f"using the bundled {package.distribution} ({error})"
                ) from error
            result = updater.prepare()
        except Exception as error:  # noqa: BLE001 - selection must never block package use
            logger.warning(
                "%s runtime selection skipped: %s", package.distribution, error
            )
            bundled = updater._bundled_version(updater.storage_directory)
            updater._record_error(f"Runtime selection skipped: {error}")
            result = updater._result(
                active_version=str(bundled or "unknown"),
                bundled_version=str(bundled or "unknown"),
                current=None,
                previous=None,
                remote=None,
                source="bundled",
            )
        _STARTUP_RESULTS[package.distribution] = result
        return result
