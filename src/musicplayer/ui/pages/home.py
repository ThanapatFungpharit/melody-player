from __future__ import annotations

import random
from collections.abc import Callable
from functools import partial
from typing import TYPE_CHECKING, Any

import flet as ft

from musicplayer.application.models import SearchResult
from musicplayer.application.providers import ProviderError
from musicplayer.core.library.models import Track
from musicplayer.core.media import is_youtube_url
from musicplayer.ui.tasks import run_io

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


class HomePage:
    """Home page UI."""

    RECOMMENDATION_LIMIT = 8
    RECOMMENDATION_FETCH_LIMITS = (24, 48, 96)
    RECOMMENDATION_TARGET = 32
    RECOMMENDATION_SEED_LIMIT = 2

    def __init__(self, app: MusicPlayerApp):
        self.app = app
        self.recommendations: list[SearchResult] = []
        self.recommendations_loading = False
        self.recommendations_error = ""
        self._recommendation_seed_urls: tuple[str, ...] = ()
        self._recommendation_sources: tuple[str, ...] = ()
        self._recommendation_request = 0
        self.recommendation_page = 0
        self._recommendation_section: ft.Column | None = None
        self._recommendation_builder: Callable[[], list[ft.Control]] | None = None

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

    def _play_library(self) -> None:
        self.app.shared._play_collection(self.app.manager.list_tracks())

    def _shuffle_library(self) -> None:
        self.app.shared._shuffle_collection(self.app.manager.list_tracks())

    def _queue_library(self) -> None:
        self.app.shared._queue_collection(self.app.manager.list_tracks())

    def _ensure_recommendations(self, *, force: bool = False) -> None:
        """Load a related YouTube Music mix without blocking Home rendering."""
        sources = self._recommendation_candidates()
        if not sources:
            self._recommendation_request += 1
            self.recommendations = []
            self.recommendations_loading = False
            self.recommendations_error = ""
            self._recommendation_seed_urls = ()
            self._recommendation_sources = ()
            self.recommendation_page = 0
            return
        if not hasattr(self.app, "tasks"):
            return
        if not force and sources == self._recommendation_sources:
            return

        choices = list(sources)
        random.shuffle(choices)
        if len(choices) > 1 and self._recommendation_seed_urls:
            previous_first = self._recommendation_seed_urls[0]
            if choices[0] == previous_first:
                choices.append(choices.pop(0))
        seed_urls = tuple(choices[: self.RECOMMENDATION_SEED_LIMIT])

        self._recommendation_request += 1
        request = self._recommendation_request
        self._recommendation_sources = sources
        self._recommendation_seed_urls = seed_urls
        self.recommendations_loading = True
        self.recommendations_error = ""
        self.recommendation_page = 0
        submitted = run_io(
            self.app,
            partial(self._fetch_recommendations, seed_urls),
            partial(self._finish_recommendations, request),
            key="recommendations",
            replace=True,
            failed=partial(self._recommendations_failed, request),
        )
        if not submitted:
            self.recommendations_loading = False
            self.recommendations_error = (
                "Recommendations are busy. Use refresh to try again."
            )

    def _recommendation_candidates(self) -> tuple[str, ...]:
        """Collect distinct playable sources from current, recent, and favorites."""
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
        sources: list[str] = []
        for track_id in candidate_ids:
            if track_id in seen:
                continue
            seen.add(track_id)
            try:
                source = self.app.manager.get_track(track_id).source
            except KeyError, TypeError, ValueError:
                continue
            if is_youtube_url(source) and source not in sources:
                sources.append(source)
        return tuple(sources)

    def _fetch_recommendations(self, seed_urls: tuple[str, ...]) -> list[SearchResult]:
        """Expand radio mixes when duplicates leave too few new tracks."""
        recommendations: list[SearchResult] = []
        seen: set[str] = set()
        errors: list[ProviderError] = []
        active_seeds = list(seed_urls)
        for limit in self.RECOMMENDATION_FETCH_LIMITS:
            next_seeds: list[str] = []
            for seed_url in active_seeds:
                try:
                    fetched = self.app.providers.recommendations(seed_url, limit=limit)
                except ProviderError as error:
                    errors.append(error)
                    continue
                before = len(recommendations)
                for result in fetched:
                    identity = result.identity
                    key = identity.key if identity is not None else result.url
                    if (
                        result.is_playlist
                        or not key
                        or key in seen
                        or self.app.manager.find_track_by_source(result.url) is not None
                    ):
                        continue
                    seen.add(key)
                    recommendations.append(result)
                # A short provider result can still conceal later entries
                # filtered by the provider. Probe once at a larger limit.
                if (
                    limit == self.RECOMMENDATION_FETCH_LIMITS[0]
                    or len(fetched) >= limit
                    or len(recommendations) > before
                ):
                    next_seeds.append(seed_url)
                if len(recommendations) >= self.RECOMMENDATION_TARGET:
                    break
            if len(recommendations) >= self.RECOMMENDATION_TARGET or not next_seeds:
                break
            active_seeds = next_seeds
        if not recommendations and errors:
            raise errors[0]
        random.shuffle(recommendations)
        return recommendations

    def _visible_recommendations(self) -> list[SearchResult]:
        start = self.recommendation_page * self.RECOMMENDATION_LIMIT
        return self.recommendations[start : start + self.RECOMMENDATION_LIMIT]

    def _change_recommendation_page(self, direction: int) -> None:
        last_page = max(0, (len(self.recommendations) - 1) // self.RECOMMENDATION_LIMIT)
        self.recommendation_page = min(
            last_page, max(0, self.recommendation_page + direction)
        )
        self._refresh_home()

    def _recommendation_navigation(self) -> ft.Control | None:
        total = len(self.recommendations)
        if total <= self.RECOMMENDATION_LIMIT:
            return None
        start = self.recommendation_page * self.RECOMMENDATION_LIMIT
        end = min(total, start + self.RECOMMENDATION_LIMIT)
        return ft.Row(
            [
                ft.TextButton(
                    "Previous",
                    icon=ft.Icons.CHEVRON_LEFT_ROUNDED,
                    disabled=start == 0,
                    on_click=lambda _: self._change_recommendation_page(-1),
                ),
                ft.Text(
                    f"{start + 1}–{end} of {total}",
                    expand=True,
                    text_align=ft.TextAlign.CENTER,
                ),
                ft.TextButton(
                    "Next",
                    icon=ft.Icons.CHEVRON_RIGHT_ROUNDED,
                    disabled=end >= total,
                    on_click=lambda _: self._change_recommendation_page(1),
                ),
            ],
            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
        )

    def _finish_recommendations(
        self, request: int, recommendations: list[SearchResult]
    ) -> None:
        if request != self._recommendation_request:
            return
        self.recommendations = recommendations
        self.recommendations_loading = False
        self.recommendations_error = ""
        self._refresh_home()

    def _recommendations_failed(self, request: int, message: str) -> None:
        if request != self._recommendation_request:
            return
        self.recommendations = []
        self.recommendations_loading = False
        self.recommendations_error = message
        self._refresh_home()

    def _reload_recommendations(self) -> None:
        self._ensure_recommendations(force=True)
        self._refresh_home()

    def _build_recommendation_section(
        self, builder: Callable[[], list[ft.Control]], *, spacing: int
    ) -> ft.Column:
        section = ft.Column(builder(), spacing=spacing)
        self._recommendation_section = section
        self._recommendation_builder = builder
        return section

    def _refresh_home(self) -> None:
        if (
            self.app.selected_navigation == 0
            and self._recommendation_section is not None
            and self._recommendation_builder is not None
        ):
            self._recommendation_section.controls = self._recommendation_builder()
            self.app.page.update(self._recommendation_section)
