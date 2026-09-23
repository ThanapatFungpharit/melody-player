"""Utility destinations share workflows, not a modal presentation."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


class ContextPanel:
    def __init__(self, app: MusicPlayerApp) -> None:
        self.app = app

    def _open_queue_panel(self) -> None:
        self.app.shell.open_panel("queue")

    def _open_downloads_panel(self) -> None:
        self.app.shell.open_panel("downloads")

    def _open_settings_panel(self) -> None:
        self.app.shell.open_panel("settings")

    def _panel_view(self, name: str):
        return {
            "queue": self.app.queue_page._queue_view,
            "downloads": self.app.downloads_page._downloads_view,
            "settings": self.app.settings_page._settings_view,
        }[name]()

    def _close_context_panel(self) -> None:
        self.app.shell.close_panel()

    def _refresh_context_panel(self) -> None:
        if self.app.active_panel:
            self.app.shell.refresh_panel()

    def _refresh_download_badge(self) -> None:
        if hasattr(self.app, "shell"):
            self.app.shell.refresh_downloads()
