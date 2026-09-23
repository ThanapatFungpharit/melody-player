from __future__ import annotations

from functools import partial
from typing import TYPE_CHECKING, Any

import flet as ft

from musicplayer.application.models import SearchResult
from musicplayer.core.library.models import Track
from musicplayer.core.media import is_youtube_url
from musicplayer.ui.tasks import run_io

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


class HomePage:
    """Home page UI."""

    RECOMMENDATION_LIMIT = 8
    RECOMMENDATION_FETCH_LIMIT = 16

    def __init__(self, app: MusicPlayerApp):
        self.app = app
        self.recommendations: list[SearchResult] = []
        self.recommendations_loading = False
        self.recommendations_error = ""
        self._recommendation_seed_url = ""
        self._loaded_recommendation_seed_url = ""

    def _home_view(self) -> ft.Control:
        self._ensure_recommendations()
        return self.app.views._home_view(self.app)

    def _track_shelf(
        self, title: str, tracks: list[Track], empty: str
    ) -> list[ft.Control]:
        return self.app.views._track_shelf(self.app, title, tracks, empty)

    def _track_card(self, track: Track) -> ft.Control:
        return self.app.views._track_card(self.app, track)

    def _card_hover(self, event: Any) -> None:
        return self.app.views._card_hover(self.app, event)

    def _home_collections(self):
        track_count, _ = self.app.manager.counts()
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
        favorites = list(self.app.manager.tracks_by_ids(tuple(favorite_ids), limit=6))
        return track_count, recent, favorites

    def _play_library(self, *, shuffle: bool = False) -> None:
        self.app.shared._play_collection(
            self.app.manager.list_tracks(), shuffle=shuffle
        )

    def _queue_library(self) -> None:
        self.app.shared._queue_collection(self.app.manager.list_tracks())

    def _ensure_recommendations(self, *, force: bool = False) -> None:
        """Load a related YouTube Music mix without blocking Home rendering."""
        seed_url = self._recommendation_seed()
        if not seed_url:
            self.recommendations = []
            self.recommendations_loading = False
            self.recommendations_error = ""
            self._recommendation_seed_url = ""
            self._loaded_recommendation_seed_url = ""
            return
        if not hasattr(self.app, "tasks"):
            return
        if self.recommendations_loading and seed_url == self._recommendation_seed_url:
            return
        if not force and seed_url == self._loaded_recommendation_seed_url:
            return

        self._recommendation_seed_url = seed_url
        self.recommendations_loading = True
        self.recommendations_error = ""
        submitted = run_io(
            self.app,
            partial(self._fetch_recommendations, seed_url),
            partial(self._finish_recommendations, seed_url),
            key="recommendations",
            replace=True,
            failed=partial(self._recommendations_failed, seed_url),
        )
        if not submitted:
            self.recommendations_loading = False
            self.recommendations_error = (
                "Recommendations are busy. Use refresh to try again."
            )

    def _recommendation_seed(self) -> str:
        """Prefer the current track, then recent and favorite YouTube tracks."""
        candidate_ids: list[str] = []
        playback = getattr(self.app, "playback", None)
        current_track_id = getattr(playback, "current_track_id", None)
        if current_track_id:
            candidate_ids.append(str(current_track_id))
        recent = self.app.store.get("recent_tracks", [])
        if isinstance(recent, list):
            candidate_ids.extend(str(track_id) for track_id in recent)
        candidate_ids.extend(sorted(self.app.store.favorite_track_ids()))

        seen: set[str] = set()
        for track_id in candidate_ids:
            if track_id in seen:
                continue
            seen.add(track_id)
            try:
                source = self.app.manager.get_track(track_id).source
            except KeyError, TypeError, ValueError:
                continue
            if is_youtube_url(source):
                return source
        return ""

    def _fetch_recommendations(self, seed_url: str) -> list[SearchResult]:
        fetched = self.app.providers.recommendations(
            seed_url,
            limit=self.RECOMMENDATION_FETCH_LIMIT,
        )
        recommendations: list[SearchResult] = []
        for result in fetched:
            if self.app.manager.find_track_by_source(result.url) is not None:
                continue
            recommendations.append(result)
            if len(recommendations) == self.RECOMMENDATION_LIMIT:
                break
        return recommendations

    def _finish_recommendations(
        self, seed_url: str, recommendations: list[SearchResult]
    ) -> None:
        if seed_url != self._recommendation_seed_url:
            return
        self.recommendations = recommendations
        self.recommendations_loading = False
        self.recommendations_error = ""
        self._loaded_recommendation_seed_url = seed_url
        self._refresh_home()

    def _recommendations_failed(self, seed_url: str, message: str) -> None:
        if seed_url != self._recommendation_seed_url:
            return
        self.recommendations = []
        self.recommendations_loading = False
        self.recommendations_error = message
        self._loaded_recommendation_seed_url = seed_url
        self._refresh_home()

    def _reload_recommendations(self) -> None:
        self._ensure_recommendations(force=True)
        self._refresh_home()

    def _refresh_home(self) -> None:
        if self.app.selected_navigation == 0:
            self.app.navigation.navigate(0)
