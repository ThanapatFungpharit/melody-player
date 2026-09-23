from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest.mock import Mock

import flet as ft

from musicplayer.app import MusicPlayerApp
from musicplayer.application.models import AppSettings
from musicplayer.ui.pages.settings import SettingsPage


class ThemeTests(unittest.TestCase):
    def test_theme_selector_previews_mode_and_keeps_draft_when_settings_refresh(
        self,
    ) -> None:
        app = MusicPlayerApp.__new__(MusicPlayerApp)
        app.page = SimpleNamespace(  # ty: ignore[invalid-assignment]
            theme_mode=None,
            update=Mock(),
        )
        app.settings = AppSettings(theme="dark", accent_color="violet")
        app.context_panel = SimpleNamespace(  # ty: ignore[invalid-assignment]
            _refresh_context_panel=Mock()
        )
        app._reapply_accent = Mock()
        settings_page = SettingsPage(app)

        settings_page._build_appearance_settings()
        settings_page.theme.value = "light"
        settings_page._theme_changed(SimpleNamespace(control=settings_page.theme))

        self.assertEqual(app.page.theme_mode, ft.ThemeMode.LIGHT)
        self.assertEqual(settings_page.theme_draft, "light")
        settings_page._build_appearance_settings()
        self.assertEqual(settings_page.theme.value, "light")

    def test_accent_selection_survives_panel_rebuild_and_is_applied(self) -> None:
        app = MusicPlayerApp.__new__(MusicPlayerApp)
        app.page = SimpleNamespace(update=Mock())  # ty: ignore[invalid-assignment]
        app.settings = AppSettings(accent_color="violet")
        app.context_panel = SimpleNamespace(  # ty: ignore[invalid-assignment]
            _refresh_context_panel=Mock()
        )
        app._reapply_accent = Mock()
        settings_page = SettingsPage(app)

        settings_page._build_appearance_settings()
        settings_page._select_accent("ocean")
        settings_page._build_appearance_settings()

        self.assertEqual(settings_page.accent_draft, "ocean")
        self.assertEqual(settings_page.theme.value, "dark")
        self.assertEqual(settings_page.selected_accent, "ocean")
        app._reapply_accent.assert_called_once()


if __name__ == "__main__":
    unittest.main()
