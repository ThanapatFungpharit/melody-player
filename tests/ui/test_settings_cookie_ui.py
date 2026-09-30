from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import flet as ft

from musicplayer.app import MusicPlayerApp
from musicplayer.application.models import AppSettings
from musicplayer.application.yt_dlp_runtime import YtDlpStatus
from musicplayer.ui.components.common import SharedUIComponents
from musicplayer.ui.desktop.shell import DesktopShell
from musicplayer.ui.pages.settings import SettingsPage

COOKIE_FILE = b"""# Netscape HTTP Cookie File
.youtube.com\tTRUE\t/\tTRUE\t2147483647\tSID\tsecret
"""


class _Page:
    width = 1000
    height = 800
    window = type("Window", (), {"width": 1000, "height": 800})()
    theme_mode: ft.ThemeMode | None = None

    def update(self, *_: ft.Control) -> None:
        pass


class _Providers:
    pass


class _Manager:
    def list_tracks(self) -> tuple[object, ...]:
        return ()


class _Store:
    def __init__(self) -> None:
        self.saved: AppSettings | None = None
        self.fail = False

    def save_settings(self, settings: AppSettings) -> None:
        if self.fail:
            raise OSError("state write failed")
        self.saved = settings


class _FilePicker:
    def __init__(self, content: bytes) -> None:
        self.content = content
        self.arguments: dict[str, object] = {}

    async def pick_files(self, **arguments: object) -> list[ft.FilePickerFile]:
        self.arguments = arguments
        return [
            ft.FilePickerFile(
                id=1,
                name="cookies.txt",
                size=len(self.content),
                bytes=self.content,  # ty: ignore[invalid-argument-type]
            )
        ]


class _InlineTasks:
    def start(self, operation, *args, **kwargs) -> None:
        asyncio.run(operation(*args, **kwargs))

    async def io(self, operation, *args, **kwargs):
        return operation(*args, **kwargs)


class SettingsCookieUiTests(unittest.TestCase):
    def _app(self, directory: str, content: bytes) -> MusicPlayerApp:
        app = MusicPlayerApp.__new__(MusicPlayerApp)
        app.shell = DesktopShell(app)
        app.page = _Page()  # ty: ignore[invalid-assignment]
        app.data_directory = Path(directory) / "app-data"
        app.settings = AppSettings(download_directory=directory)
        app.providers = _Providers()  # ty: ignore[invalid-assignment]
        app.manager = _Manager()  # ty: ignore[invalid-assignment]
        app.store = _Store()  # ty: ignore[invalid-assignment]
        app.playback = SimpleNamespace(volume=5, previous_volume=5, muted=False)  # ty: ignore[invalid-assignment]
        app.file_picker = _FilePicker(content)  # ty: ignore[invalid-assignment]
        app.tasks = _InlineTasks()  # ty: ignore[invalid-assignment]
        app._show_error = Mock()
        app._show_message = Mock()
        app._reapply_accent = Mock()
        app.shared = SharedUIComponents(app)
        app.yt_dlp = Mock(status=Mock(return_value=YtDlpStatus(preparing=True)))
        app.settings_page = SettingsPage(app)
        app.settings_page._settings_view()
        return app

    def test_valid_upload_is_selected_with_data_and_saved_privately(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self._app(directory, COOKIE_FILE)

            asyncio.run(app.settings_page._pick_cookie_file(None))
            app.settings_page._save_settings()

            cookie_path = app.data_directory / "cookies.txt"
            self.assertTrue(app.file_picker.arguments["with_data"])  # ty: ignore[unresolved-attribute]
            self.assertEqual(app.file_picker.arguments["allow_multiple"], False)  # ty: ignore[unresolved-attribute]
            self.assertTrue(cookie_path.is_file())
            self.assertEqual(app.settings.cookie_file, str(cookie_path))
            self.assertIs(app.store.saved, app.settings)  # ty: ignore[unresolved-attribute]
            app._show_error.assert_not_called()  # ty: ignore[unresolved-attribute]

    def test_save_keeps_volume_changed_after_startup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self._app(directory, COOKIE_FILE)
            app.playback = SimpleNamespace(volume=42, previous_volume=42, muted=True)  # ty: ignore[invalid-assignment]

            app.settings_page._save_settings()

            saved = app.store.saved  # ty: ignore[unresolved-attribute]
            self.assertEqual(
                (saved.volume, saved.previous_volume, saved.muted), (42, 42, True)
            )

    def test_invalid_upload_reports_error_and_is_not_installed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self._app(directory, b'{"cookies": []}')

            asyncio.run(app.settings_page._pick_cookie_file(None))

            app._show_error.assert_called_once()  # ty: ignore[unresolved-attribute]
            self.assertIsNone(app.settings_page.pending_cookie_file)
            self.assertFalse((app.data_directory / "cookies.txt").exists())

    def test_failed_save_restores_previous_managed_cookie(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self._app(directory, COOKIE_FILE)
            cookie_path = app.data_directory / "cookies.txt"
            cookie_path.parent.mkdir(parents=True)
            previous = COOKIE_FILE.replace(b"secret", b"previous")
            cookie_path.write_bytes(previous)
            app.settings.cookie_file = str(cookie_path)
            app.store.fail = True  # ty: ignore[unresolved-attribute]

            asyncio.run(app.settings_page._pick_cookie_file(None))
            with self.assertRaisesRegex(OSError, "state write failed"):
                app.settings_page._save_settings()

            self.assertEqual(cookie_path.read_bytes(), previous)
            self.assertEqual(app.settings.cookie_file, str(cookie_path))

    def test_failed_save_restores_removed_managed_cookie(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self._app(directory, COOKIE_FILE)
            cookie_path = app.data_directory / "cookies.txt"
            cookie_path.parent.mkdir(parents=True)
            cookie_path.write_bytes(COOKIE_FILE)
            app.settings.cookie_file = str(cookie_path)
            app.store.fail = True  # ty: ignore[unresolved-attribute]
            app.settings_page._remove_cookie_file(None)

            with self.assertRaisesRegex(OSError, "state write failed"):
                app.settings_page._save_settings()

            self.assertEqual(cookie_path.read_bytes(), COOKIE_FILE)
            self.assertEqual(app.settings.cookie_file, str(cookie_path))

    def test_missing_saved_cookie_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self._app(directory, COOKIE_FILE)
            app.settings.cookie_file = str(Path(directory) / "missing-cookies.txt")

            app.settings_page._settings_view()

            self.assertIn("missing", app.settings_page.cookie_status.value.lower())


if __name__ == "__main__":
    unittest.main()
