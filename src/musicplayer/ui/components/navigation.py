"""Shared destination dispatch. Each shell owns its navigation controls."""

from __future__ import annotations

from typing import TYPE_CHECKING

import flet as ft

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp

NAVIGATION = (
    ("Home", ft.Icons.HOME_ROUNDED, ft.Icons.HOME_OUTLINED),
    ("Search", ft.Icons.SEARCH_ROUNDED, ft.Icons.SEARCH_ROUNDED),
    ("Library", ft.Icons.LIBRARY_MUSIC_ROUNDED, ft.Icons.LIBRARY_MUSIC_OUTLINED),
    ("Playlists", ft.Icons.ALBUM_ROUNDED, ft.Icons.ALBUM_OUTLINED),
)


class NavigationShell:
    def __init__(self, app: MusicPlayerApp) -> None:
        self.app = app

    def _build_shell(self) -> None:
        self.app.shell.build()
        self.navigate(self.app.selected_navigation)
        self.app.player_bar._refresh_player()
        self.app.context_panel._refresh_download_badge()

    def navigate(self, index: int) -> None:
        self.app.selected_navigation = max(0, min(index, len(NAVIGATION) - 1))
        builders = (
            self.app.home_page._home_view,
            self.app.search_page._search_view,
            self.app.library_page._library_view,
            self.app.playlists_page._playlists_view,
        )
        self.app.content.content = builders[self.app.selected_navigation]()
        self.app.shell.select(self.app.selected_navigation)
        self.app.page.update()
