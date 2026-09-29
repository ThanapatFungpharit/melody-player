from __future__ import annotations

import unittest
from types import SimpleNamespace
from typing import cast
from unittest.mock import Mock

import flet as ft

from musicplayer.app import MusicPlayerApp
from musicplayer.application.models import AppSettings
from musicplayer.ui.pages.settings import SettingsPage


class ThemeTests(unittest.TestCase):
    def test_new_settings_follow_system_theme(self) -> None:
        app = MusicPlayerApp.__new__(MusicPlayerApp)
        app.settings = AppSettings()
        settings_page = SettingsPage(app)

        settings_page._build_appearance_settings()

        self.assertEqual(app.settings.theme, "system")
        self.assertEqual(AppSettings.from_dict({}).theme, "system")
        self.assertEqual(settings_page.theme.value, "system")

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
        picker = settings_page.accent_picker
        theme = settings_page.theme
        settings_page._select_accent("coral")
        self.assertIs(settings_page.accent_picker, picker)
        self.assertIs(settings_page.theme, theme)
        cast(Mock, app.context_panel._refresh_context_panel).assert_not_called()
        cast(Mock, app.page.update).assert_called_once()
        settings_page._build_appearance_settings()

        self.assertEqual(settings_page.accent_draft, "coral")
        self.assertEqual(settings_page.theme.value, "system")
        self.assertEqual(settings_page.selected_accent, "coral")
        self.assertTrue(settings_page.accent_picker.wrap)
        app._reapply_accent.assert_called_once()


if __name__ == "__main__":
    unittest.main()
