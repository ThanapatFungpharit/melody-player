from __future__ import annotations

import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import Mock

import flet as ft

from musicplayer.app import MusicPlayerApp
from musicplayer.application.library_service import LibraryReconciliation
from musicplayer.application.models import AppSettings
from musicplayer.application.yt_dlp_runtime import YtDlpStatus, YtDlpUpdateError
from musicplayer.ui.components.common import SharedUIComponents
from musicplayer.ui.pages.settings import SettingsPage


class _Page:
    def __init__(self) -> None:
        self.dialogs: list[ft.AlertDialog] = []

    def update(self, *_: ft.Control) -> None:
        pass

    def show_dialog(self, dialog: ft.AlertDialog) -> None:
        self.dialogs.append(dialog)


class _InlineTasks:
    def start(self, operation, *args, **kwargs) -> None:
        asyncio.run(operation(*args, **kwargs))

    async def io(self, operation, *args, **kwargs):
        return operation(*args, **kwargs)

    def dispatch(self, callback, *args) -> None:
        callback(*args)


class _YtDlp:
    def __init__(self, status: YtDlpStatus) -> None:
        self.current = status
        self.check_error: Exception | None = None
        self.ready_callbacks: list = []

    def status(self) -> YtDlpStatus:
        return self.current

    def when_ready(self, callback) -> None:
        self.ready_callbacks.append(callback)

    def finish(self, status: YtDlpStatus) -> None:
        self.current = status
        callbacks, self.ready_callbacks = self.ready_callbacks, []
        for callback in callbacks:
            callback()

    def check_for_update(self) -> YtDlpStatus:
        if self.check_error is not None:
            raise self.check_error
        self.current = YtDlpStatus(
            preparing=False, active_version="2026.8.19", available_version="2026.9.12"
        )
        return self.current

    def request_update(self) -> YtDlpStatus:
        self.current = YtDlpStatus(
            preparing=False,
            active_version="2026.8.19",
            available_version="2026.9.12",
            scheduled_version="2026.9.12",
        )
        return self.current


def _text(control: ft.Control) -> str:
    return str(getattr(control, "value", ""))


class SettingsMaintenanceUiTests(unittest.TestCase):
    def setUp(self) -> None:
        app = MusicPlayerApp.__new__(MusicPlayerApp)
        app.page = _Page()  # ty: ignore[invalid-assignment]
        app.settings = AppSettings()
        app.tasks = _InlineTasks()  # ty: ignore[invalid-assignment]
        self.library = Mock()
        app.library = self.library
        app.navigation = SimpleNamespace(navigate=Mock())  # ty: ignore[invalid-assignment]
        app.selected_navigation = 0
        app.yt_dlp = _YtDlp(  # ty: ignore[invalid-assignment]
            YtDlpStatus(preparing=False, active_version="2026.8.19")
        )
        app._show_error = Mock()
        app._show_message = Mock()
        app.shared = SharedUIComponents(app)
        app.settings_page = SettingsPage(app)
        app.settings_page._build_maintenance_settings()
        self.app = app
        self.page = app.settings_page

    def test_cleanup_reports_removed_references_and_stray_files(self) -> None:
        self.library.reconcile.return_value = LibraryReconciliation(
            2, ("missing",), ("/music/a.mp3", "/music/b.mp3")
        )

        self.page._clean_up_library()

        (dialog,) = self.app.page.dialogs  # ty: ignore[unresolved-attribute]
        lines = [_text(control) for control in dialog.content.controls]
        self.assertIn("Removed references to 2 deleted tracks.", lines)
        self.assertTrue(any("1 library track has no audio file" in x for x in lines))
        self.assertTrue(any("Found 2 audio files" in x for x in lines))
        self.assertEqual(lines[-2:], ["/music/a.mp3", "/music/b.mp3"])
        self.app.navigation.navigate.assert_called_once_with(0)  # ty: ignore[unresolved-attribute]
        self.assertFalse(self.page.library_cleanup.disabled)

    def test_cleanup_lists_a_bounded_number_of_stray_files(self) -> None:
        stray = tuple(f"/music/{index}.mp3" for index in range(55))
        self.library.reconcile.return_value = LibraryReconciliation(0, (), stray)

        self.page._clean_up_library()

        (dialog,) = self.app.page.dialogs  # ty: ignore[unresolved-attribute]
        lines = [_text(control) for control in dialog.content.controls]
        self.assertEqual(lines[0], "No stale references were found.")
        self.assertEqual(lines[-1], "…and 5 more.")
        self.app.navigation.navigate.assert_not_called()  # ty: ignore[unresolved-attribute]

    def test_clean_library_reports_nothing_to_fix(self) -> None:
        self.library.reconcile.return_value = LibraryReconciliation(0, (), ())

        self.page._clean_up_library()

        self.assertEqual(self.app.page.dialogs, [])  # ty: ignore[unresolved-attribute]
        self.assertIn("nothing to fix", self.app._show_message.call_args.args[0])  # ty: ignore[unresolved-attribute]

    def test_cleanup_failure_is_reported_and_retryable(self) -> None:
        self.library.reconcile.side_effect = OSError("music folder unavailable")

        self.page._clean_up_library()

        self.assertIn(
            "music folder unavailable",
            self.app._show_error.call_args.args[0],  # ty: ignore[unresolved-attribute]
        )
        self.assertFalse(self.page.library_cleanup.disabled)

    def test_status_describes_selected_package(self) -> None:
        self.assertEqual(
            self.page.yt_dlp_status.value,
            "Using yt-dlp 2026.8.19 (bundled with Melody).",
        )
        self.assertFalse(self.page.yt_dlp_install.visible)
        self.page._show_yt_dlp_status(YtDlpStatus(preparing=True), update=False)
        self.assertEqual(self.page.yt_dlp_status.value, "Preparing yt-dlp…")

    def test_preparing_status_refreshes_once_selection_finishes(self) -> None:
        runtime = self.app.yt_dlp
        runtime.current = YtDlpStatus(preparing=True)  # ty: ignore[unresolved-attribute]
        # Navigating back to Settings rebuilds the card while still preparing.
        self.page._build_maintenance_settings()
        self.page._build_maintenance_settings()
        self.assertEqual(self.page.yt_dlp_status.value, "Preparing yt-dlp…")
        self.assertEqual(len(runtime.ready_callbacks), 1)  # ty: ignore[unresolved-attribute]

        runtime.finish(  # ty: ignore[unresolved-attribute]
            YtDlpStatus(
                preparing=False,
                active_version="2026.9.12",
                bundled=False,
                updated=True,
            )
        )

        self.assertEqual(self.page.yt_dlp_status.value, "Updated to yt-dlp 2026.9.12.")

    def test_status_refresh_tolerates_a_replaced_settings_view(self) -> None:
        self.app.yt_dlp.current = YtDlpStatus(preparing=True)  # ty: ignore[unresolved-attribute]
        self.page._build_maintenance_settings()
        self.app.page.update = Mock(side_effect=RuntimeError("not mounted"))

        self.app.yt_dlp.finish(  # ty: ignore[unresolved-attribute]
            YtDlpStatus(preparing=False, active_version="2026.8.19")
        )

        self.app._show_error.assert_not_called()  # ty: ignore[unresolved-attribute]
        self.assertFalse(self.page._yt_dlp_refresh_pending)

    def test_check_then_install_schedules_update_for_next_launch(self) -> None:
        self.page._check_yt_dlp_update()

        self.assertTrue(self.page.yt_dlp_install.visible)
        self.assertIn("2026.9.12 is available", self.page.yt_dlp_status.value)
        self.assertFalse(self.page.yt_dlp_check.disabled)

        self.page._install_yt_dlp_update()

        self.assertFalse(self.page.yt_dlp_install.visible)
        self.assertIn("next time Melody starts", self.page.yt_dlp_status.value)
        self.assertIn("Restart Melody", self.app._show_message.call_args.args[0])  # ty: ignore[unresolved-attribute]

    def test_failed_check_keeps_current_status(self) -> None:
        self.app.yt_dlp.check_error = YtDlpUpdateError("Could not check: offline")  # ty: ignore[unresolved-attribute]

        self.page._check_yt_dlp_update()

        self.app._show_error.assert_called_once_with("Could not check: offline")  # ty: ignore[unresolved-attribute]
        self.assertEqual(
            self.page.yt_dlp_status.value,
            "Using yt-dlp 2026.8.19 (bundled with Melody).",
        )
        self.assertFalse(self.page.yt_dlp_check.disabled)
        self.assertFalse(self.page.yt_dlp_install.visible)


if __name__ == "__main__":
    unittest.main()
