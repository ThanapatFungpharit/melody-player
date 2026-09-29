from __future__ import annotations

from typing import TYPE_CHECKING

import flet as ft

from musicplayer.ui.components.track_pages import PAGE_SIZE, page_bounds

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


class QueuePage:
    """Playback queue page UI."""

    def __init__(self, app: MusicPlayerApp):
        self.app = app
        self._page_offset: int | None = None

    def _visible_range(self, total: int, current_index: int) -> tuple[int, int]:
        if self._page_offset is None:
            self._page_offset = max(0, current_index) // PAGE_SIZE * PAGE_SIZE
        start, end = page_bounds(total, self._page_offset)
        self._page_offset = start
        return start, end

    def _change_page(self, direction: int) -> None:
        self._page_offset = max(0, (self._page_offset or 0) + direction * PAGE_SIZE)
        self.app.context_panel._refresh_context_panel()

    def _queue_view(self) -> ft.Control:
        return self.app.views._queue_view(self.app)
