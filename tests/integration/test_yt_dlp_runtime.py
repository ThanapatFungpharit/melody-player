from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

from musicplayer import yt_dlp_updater
from musicplayer.application.store import ApplicationStore
from musicplayer.application.yt_dlp_runtime import YtDlpRuntime, YtDlpUpdateError
from musicplayer.core import runtime_gate
from tests.integration.test_yt_dlp_updater import (
    _make_wheel,
    _record,
    _remote,
    _write_state,
)

BUNDLED = "2026.8.19"


def _offline(_url: str):
    raise OSError("network unavailable")


class YtDlpRuntimeTests(unittest.TestCase):
    """One simulated process per ``_runtime().start()``: fresh gate and globals."""

    def setUp(self) -> None:
        imported = {
            name: module
            for name, module in sys.modules.items()
            if name == "yt_dlp" or name.startswith("yt_dlp.")
        }
        for name in imported:
            sys.modules.pop(name)
        self.addCleanup(sys.modules.update, imported)
        original_path = sys.path[:]
        self.addCleanup(sys.path.__setitem__, slice(None), original_path)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.storage = root / "yt-dlp-runtime"
        self.sources = root / "sources"
        self.store = ApplicationStore(root / "state.json")
        self.session = ExitStack()
        self.addCleanup(lambda: self.session.close())
        self._new_process()

    def _new_process(self, *, release_previous: bool = True) -> None:
        """Forget process-lifetime selection; optionally keep the old one running."""
        if release_previous:
            self.session.close()
        self.session = ExitStack()
        if not release_previous:
            self.addCleanup(self.session.close)
        for name, value in (
            ("_STARTUP_RESULT", None),
            ("_SESSION", self.session),
        ):
            patcher = patch.object(yt_dlp_updater, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(runtime_gate, "_PREPARATIONS", {})
        patcher.start()
        self.addCleanup(patcher.stop)

    def _runtime(self, **options) -> YtDlpRuntime:
        options.setdefault("bundled_version", BUNDLED)
        options.setdefault("fetch_remote", _offline)
        return YtDlpRuntime(self.store, self.storage, **options)

    def _started(self, runtime: YtDlpRuntime) -> YtDlpRuntime:
        runtime.start()
        runtime_gate.wait_for_runtime_preparation(key=runtime_gate.YT_DLP_PREPARATION)
        return runtime

    def test_startup_selects_installed_runtime_without_network(self) -> None:
        wheel = _make_wheel(self.storage, "2026.9.8")
        _write_state(self.storage, _record(wheel, "2026.9.8"), None)
        checked: list[str] = []

        runtime = self._started(
            self._runtime(fetch_remote=lambda url: checked.append(url))
        )

        status = runtime.status()
        self.assertFalse(status.preparing)
        self.assertEqual(status.active_version, "2026.9.8")
        self.assertFalse(status.bundled)
        self.assertEqual(checked, [])
        self.assertEqual(Path(sys.path[0]), wheel)

    def test_startup_without_runtime_uses_bundled_package(self) -> None:
        status = self._started(self._runtime()).status()

        self.assertEqual(status.active_version, BUNDLED)
        self.assertTrue(status.bundled)
        self.assertEqual(status.problem, "")

    def test_status_reports_preparing_until_selection_finishes(self) -> None:
        self.assertTrue(self._runtime().status().preparing)

    def test_ready_callbacks_run_after_selection_and_when_already_selected(
        self,
    ) -> None:
        runtime = self._runtime()
        observed: list[bool] = []
        runtime.when_ready(lambda: observed.append(runtime.status().preparing))
        self.assertEqual(observed, [])  # not started: nothing to wait for

        self._started(runtime)
        runtime.when_ready(lambda: observed.append(runtime.status().preparing))

        self.assertEqual(observed, [False])

    def test_check_reports_only_newer_releases(self) -> None:
        source = _make_wheel(self.sources, "2026.9.12")
        runtime = self._started(
            self._runtime(fetch_remote=lambda _: _remote(source, "2026.9.12"))
        )
        self.assertEqual(runtime.check_for_update().available_version, "2026.9.12")
        current = _make_wheel(self.sources, BUNDLED)

        runtime = self._started(
            self._runtime(fetch_remote=lambda _: _remote(current, BUNDLED))
        )
        self.assertEqual(runtime.check_for_update().available_version, "")

    def test_offline_check_is_non_fatal(self) -> None:
        runtime = self._started(self._runtime())

        with self.assertRaisesRegex(YtDlpUpdateError, "network unavailable"):
            runtime.check_for_update()
        status = runtime.status()
        self.assertEqual(status.active_version, BUNDLED)
        self.assertEqual(status.available_version, "")

    def test_install_requires_a_checked_release(self) -> None:
        with self.assertRaisesRegex(YtDlpUpdateError, "Check for updates"):
            self._started(self._runtime()).request_update()

    def test_scheduled_update_is_installed_and_activated_at_next_launch(self) -> None:
        source = _make_wheel(self.sources, "2026.9.12")
        options = {
            "fetch_remote": lambda _: _remote(source, "2026.9.12"),
            "download": lambda _, destination: shutil.copyfile(source, destination),
        }
        runtime = self._started(self._runtime(**options))
        runtime.check_for_update()
        scheduled = runtime.request_update()
        self.assertEqual(scheduled.scheduled_version, "2026.9.12")
        # The running process keeps the package it already selected.
        self.assertEqual(scheduled.active_version, BUNDLED)

        self._new_process()
        status = self._started(self._runtime(**options)).status()

        self.assertTrue(status.updated, status)
        self.assertEqual(status.active_version, "2026.9.12")
        self.assertEqual(status.scheduled_version, "")
        self.assertEqual(Path(sys.path[0]), self.storage / source.name)

    def test_failed_scheduled_update_keeps_previous_runtime(self) -> None:
        old = _make_wheel(self.storage, "2026.9.8")
        _write_state(self.storage, _record(old, "2026.9.8"), None)
        source = _make_wheel(self.sources, "2026.9.12")
        self.store.set("yt_dlp_update_request", "2026.9.12")

        def fail_download(_url: str, _destination: Path) -> None:
            raise OSError("connection reset")

        status = self._started(
            self._runtime(
                fetch_remote=lambda _: _remote(source, "2026.9.12"),
                download=fail_download,
            )
        ).status()

        self.assertFalse(status.updated)
        self.assertEqual(status.active_version, "2026.9.8")
        self.assertIn("connection reset", status.problem)
        # One attempt per request; the next launch is offline again.
        self.assertEqual(status.scheduled_version, "")
        self.assertEqual(Path(sys.path[0]), old)

    def test_second_running_instance_uses_bundled_package(self) -> None:
        wheel = _make_wheel(self.storage, "2026.9.8")
        _write_state(self.storage, _record(wheel, "2026.9.8"), None)
        self._started(self._runtime())

        self._new_process(release_previous=False)
        status = self._started(self._runtime()).status()

        self.assertEqual(status.active_version, BUNDLED)
        self.assertTrue(status.bundled)
        self.assertTrue(status.problem)
        self.assertTrue(wheel.is_file())

    def test_selection_after_an_early_import_falls_back_without_raising(self) -> None:
        with patch.dict(sys.modules, {"yt_dlp": ModuleType("yt_dlp")}):
            status = self._started(self._runtime()).status()

        self.assertEqual(status.active_version, BUNDLED)
        self.assertTrue(status.bundled)
        self.assertIn("first import", status.problem)

    def test_yt_dlp_importers_wait_for_selection(self) -> None:
        from musicplayer.application import providers

        with (
            patch.object(providers, "wait_for_runtime_preparation") as wait,
            patch.dict(providers.__dict__, {}, clear=False),
        ):
            providers.__dict__.pop("YoutubeDL", None)
            providers._yt_dlp_symbols()
        wait.assert_called_once_with(key=runtime_gate.YT_DLP_PREPARATION)


if __name__ == "__main__":
    unittest.main()
