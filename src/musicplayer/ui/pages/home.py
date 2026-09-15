from __future__ import annotations

from typing import TYPE_CHECKING, Any

import flet as ft

from musicplayer.core.library.models import Track

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp

    _Base = object
else:
    _Base = object


class HomePage:
    def __init__(self, app: MusicPlayerApp):
        self.app = app

    """Home page UI."""

    def _home_view(self) -> ft.Control:
        return self.app.views._home_view(self)

    def _track_shelf(
        self, title: str, tracks: list[Track], empty: str
    ) -> list[ft.Control]:
        return self.app.views._track_shelf(self, title, tracks, empty)

    def _track_card(self, track: Track) -> ft.Control:
        return self.app.views._track_card(self, track)

    def _card_hover(self, event: Any) -> None:
        return self.app.views._card_hover(self, event)

    def _home_collections(self):
        tracks = self.app.manager.list_tracks()
        recent_ids = self.app.store.get("recent_tracks", [])
        recent: list[Track] = []
        for track_id in recent_ids:
            try:
                recent.append(self.app.manager.get_track(track_id))
            except KeyError, TypeError, ValueError:
                continue
            if len(recent) == 6:
                break
        favorite_ids = self.app.store.favorite_track_ids()
        favorites: list[Track] = []
        for track in tracks:
            if str(track.id) in favorite_ids:
                favorites.append(track)
                if len(favorites) == 6:
                    break
        return tracks, recent, favorites
