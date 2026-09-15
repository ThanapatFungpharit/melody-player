from __future__ import annotations

from typing import TYPE_CHECKING

import flet as ft

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp

    _Base = object
else:
    _Base = object


class QueuePage:
    def __init__(self, app: MusicPlayerApp):
        self.app = app

    """Playback queue page UI."""

    def _queue_view(self) -> ft.Control:
        return self.app.views._queue_view(self)
