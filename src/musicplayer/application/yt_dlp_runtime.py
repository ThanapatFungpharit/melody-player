"""Application view of the runtime-selected yt-dlp package.

``musicplayer.yt_dlp_updater`` owns wheel validation, locking, recovery,
rollback, and bundled fallback. This service decides when it runs and exposes
only a small status value to the presentation. Selection happens once per
process before the first ``import yt_dlp``, so an update checked while Melody
is running is installed and verified at the next launch.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from concurrent.futures import Future
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from musicplayer.core.runtime_gate import (
    YT_DLP_PREPARATION,
    start_runtime_preparation,
)

from .store import ApplicationStore

logger = logging.getLogger(__name__)
_UPDATE_REQUEST = "yt_dlp_update_request"


class YtDlpUpdateError(RuntimeError):
    """A user-initiated update action failed; the active package is unchanged."""


@dataclass(frozen=True)
class YtDlpStatus:
    preparing: bool
    active_version: str = ""
    bundled: bool = True
    # This launch activated a release installed at the user's request.
    updated: bool = False
    # A newer compatible release found by the last check.
    available_version: str = ""
    # A release that will be installed when Melody next starts.
    scheduled_version: str = ""
    # The latest non-fatal selection problem, if any.
    problem: str = ""


class YtDlpRuntime:
    def __init__(
        self,
        store: ApplicationStore,
        storage_directory: Path,
        **updater_options: Any,
    ) -> None:
        self._store = store
        self._storage_directory = storage_directory
        # Test seams forwarded to the updater (release source, bundled version).
        self._updater_options = updater_options
        self._preparation: Future[Any] | None = None
        self._available = ""

    def start(self) -> None:
        """Select yt-dlp in the background; importers wait on the runtime gate."""
        self._preparation = start_runtime_preparation(
            self._prepare, key=YT_DLP_PREPARATION
        )

    def when_ready(self, callback: Callable[[], None]) -> None:
        """Call ``callback`` once selection finishes, from the selecting thread.

        It runs immediately if selection has already finished.
        """
        if self._preparation is not None:
            self._preparation.add_done_callback(lambda _: callback())

    def status(self) -> YtDlpStatus:
        scheduled = self._scheduled_version()
        preparation = self._preparation
        if preparation is None or not preparation.done():
            return YtDlpStatus(preparing=True, scheduled_version=scheduled)
        if (error := preparation.exception()) is not None:
            return YtDlpStatus(
                preparing=False, scheduled_version=scheduled, problem=str(error)
            )
        result = preparation.result()
        return YtDlpStatus(
            preparing=False,
            active_version=result.active_version,
            bundled=result.active_source == "bundled",
            updated=result.updated,
            available_version=self._available,
            scheduled_version=scheduled,
            problem=result.errors[-1] if result.errors else "",
        )

    def check_for_update(self) -> YtDlpStatus:
        """Read release metadata only. Blocking network I/O for a worker thread."""
        from packaging.version import InvalidVersion, Version

        from musicplayer.yt_dlp_updater import YtDlpUpdater

        if self._preparation is not None:
            self._preparation.exception()  # compare with the selected version
        active = self.status().active_version
        try:
            release = YtDlpUpdater(
                storage_directory=self._storage_directory, **self._updater_options
            ).latest_release()
        except Exception as error:
            raise YtDlpUpdateError(f"Could not check for updates: {error}") from error
        try:
            newer = release is not None and release.version > Version(active)
        except InvalidVersion:
            newer = release is not None
        self._available = str(release.version) if release and newer else ""
        return self.status()

    def request_update(self) -> YtDlpStatus:
        """Install the checked release at the next launch, before yt-dlp loads."""
        if not self._available:
            raise YtDlpUpdateError("Check for updates before installing one.")
        try:
            self._store.set(_UPDATE_REQUEST, self._available)
        except OSError as error:
            raise YtDlpUpdateError(f"Could not schedule the update: {error}") from error
        return self.status()

    def _prepare(self) -> Any:
        from musicplayer.yt_dlp_updater import prepare_yt_dlp

        # Consume the request exactly once. The updater records a failed
        # release itself, so a bad update cannot be retried on every launch.
        install = bool(self._scheduled_version())
        if install:
            try:
                self._store.set(_UPDATE_REQUEST, None)
            except OSError:
                logger.warning("Could not clear the yt-dlp update request")
        return prepare_yt_dlp(
            storage_directory=self._storage_directory,
            check_remote=install,
            **self._updater_options,
        )

    def _scheduled_version(self) -> str:
        value = self._store.get(_UPDATE_REQUEST)
        return value if isinstance(value, str) else ""
