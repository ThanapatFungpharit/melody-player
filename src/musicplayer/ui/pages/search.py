from __future__ import annotations

import logging
from functools import partial
from typing import TYPE_CHECKING

import flet as ft

from musicplayer.application.downloads import (
    extract_download_urls,
)
from musicplayer.application.models import SearchResult
from musicplayer.core.library.models import Playlist
from musicplayer.core.media import YOUTUBE_MUSIC_NAME, YOUTUBE_PROVIDER_ID
from musicplayer.ui.components.common import (
    _empty_state,
    _format_duration,
)
from musicplayer.ui.tasks import page_action, run_io

logger = logging.getLogger(__name__)

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


class SearchPage:
    query: ft.TextField
    button: ft.Button
    batch_download_button: ft.Button
    status: ft.Text
    view_selector: ft.SegmentedButton
    previous_button: ft.IconButton
    first_button: ft.TextButton
    next_button: ft.IconButton
    page_number_label: ft.Text
    pagination: ft.Row
    result_list: ft.Column

    def __init__(self, app: MusicPlayerApp):
        self.app = app
        self.reset()

    """Search page UI and provider-search workflow."""

    SEARCH_PAGE_SIZE = 24

    def reset(self) -> None:
        self.local_tracks = {}
        self.draft = ""
        self.results: list[SearchResult] = []
        self.busy = False
        self.page_number = 1
        self.has_next = False
        self.query_text = ""
        self.playlist_title = ""
        self.view_mode = "list"

    def _search_view(self) -> ft.Control:
        return self.app.views._search_view(self.app)

    def _start_search(self) -> None:
        query = self.query.value.strip()
        if not query:
            self.app._show_error(f"Enter a search term or {YOUTUBE_MUSIC_NAME} URL.")
            return
        urls = extract_download_urls(query)
        if len(urls) > 1:
            self.query_text = query
            self._start_url_batch(urls)
            return
        self.query_text = query
        self._begin_search(query, page=1, remember=True)

    def _batch_download_dialog(self) -> None:
        urls_field = ft.TextField(
            label=f"{YOUTUBE_MUSIC_NAME} URLs",
            hint_text=(
                f"Paste one {YOUTUBE_MUSIC_NAME} track or playlist URL per line"
            ),
            multiline=True,
            min_lines=7,
            max_lines=12,
            autofocus=True,
        )
        validation = ft.Text("", color=ft.Colors.ERROR, size=12)

        async def start_batch(_: object) -> None:
            urls = extract_download_urls(urls_field.value or "")
            if len(urls) < 2:
                validation.value = (
                    f"Paste at least two complete {YOUTUBE_MUSIC_NAME} URLs."
                )
                self.app.page.update(validation)
                return
            try:
                batch = await self.app.tasks.io(self.app.downloads.start_urls, urls)
            except (ValueError, OSError, RuntimeError) as error:
                validation.value = str(error)
                self.app.page.update(validation)
                return
            self.app.page.pop_dialog()
            self.app._show_message(self._batch_download_message(batch))
            self.app.context_panel._open_downloads_panel()

        self.app.page.show_dialog(
            ft.AlertDialog(
                modal=True,
                title=ft.Text("Batch download"),
                content=ft.Column(
                    [
                        ft.Text(
                            f"Add multiple {YOUTUBE_MUSIC_NAME} URLs. Melody will "
                            "queue them together and show progress for each song.",
                            color=ft.Colors.ON_SURFACE_VARIANT,
                        ),
                        urls_field,
                        validation,
                    ],
                    tight=True,
                    spacing=12,
                ),
                scrollable=True,
                inset_padding=ft.Padding.symmetric(horizontal=16, vertical=24),
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button(
                        "Start batch",
                        icon=ft.Icons.DOWNLOAD_ROUNDED,
                        on_click=start_batch,
                    ),
                ],
            )
        )

    @page_action
    async def _start_url_batch(self, urls: tuple[str, ...]) -> None:
        try:
            batch = await self.app.tasks.io(self.app.downloads.start_urls, urls)
        except (ValueError, OSError, RuntimeError) as error:
            self.app._show_error(str(error))
            return
        self.app._show_message(self._batch_download_message(batch))
        self.app.context_panel._open_downloads_panel()

    @staticmethod
    def _batch_download_message(batch) -> str:
        scheduled = len(batch.tasks)
        if scheduled == batch.size:
            return f"Started a batch of {batch.size} songs. Each song will continue independently."
        if scheduled:
            return (
                f"Queued {scheduled} of {batch.size} songs. Existing files and active "
                "downloads were reused."
            )
        return "All requested songs are already in the library or downloading."

    def _load_search_page(self, page: int) -> None:
        if self.busy or page < 1:
            return
        if page > self.page_number and not self.has_next:
            return
        if not self.query_text:
            return
        self._begin_search(
            self.query_text,
            page=page,
            remember=False,
        )

    def _begin_search(
        self,
        query: str,
        *,
        page: int,
        remember: bool,
    ) -> None:
        self.busy = True
        self.button.disabled = True
        self.previous_button.disabled = True
        self.first_button.disabled = True
        self.next_button.disabled = True
        self.status.value = f"Searching page {page}…"
        self.result_list.controls = [
            ft.Container(ft.ProgressRing(), alignment=ft.Alignment.CENTER, padding=40)
        ]
        self.app.page.update(
            self.button,
            self.status,
            self.result_list,
            self.pagination,
        )
        if not run_io(
            self.app,
            partial(self._fetch_search, query, page, remember),
            partial(self._finish_search, page),
            key="search",
            replace=True,
            failed=self._search_failed,
        ):
            self.busy = False
            self.button.disabled = False
            self.status.value = "Background workers are busy. Retry shortly."
            self._update_search_navigation(update_status=False)
            self.app.page.update(
                self.button,
                self.status,
                self.result_list,
                self.pagination,
            )

    def _fetch_search(self, query: str, page: int, remember: bool):
        offset = (page - 1) * self.SEARCH_PAGE_SIZE
        fetched = self.app.providers.search(
            YOUTUBE_PROVIDER_ID,
            query,
            limit=self.SEARCH_PAGE_SIZE + 1,
            offset=offset,
        )
        local = {
            item.url: self.app.downloads.available_track(item.url)
            for item in fetched
            if not item.is_playlist
        }
        if remember:
            self.app.store.add_recent("search_history", query, limit=20)
        return fetched, local

    def _finish_search(self, page: int, value) -> None:
        fetched, self.local_tracks = value
        self.results = fetched[: self.SEARCH_PAGE_SIZE]
        self.page_number = page
        self.has_next = len(fetched) > self.SEARCH_PAGE_SIZE
        self.playlist_title = next(
            (item.playlist_title for item in self.results if item.playlist_title),
            "",
        )
        self.busy = False
        self.button.disabled = False
        self._render_search_results(update=False)
        self._update_search_navigation()
        self.app.page.update(
            self.button,
            self.status,
            self.result_list,
            self.pagination,
        )

    def _search_failed(self, message: str) -> None:
        self.busy = False
        self.button.disabled = False
        self.results = []
        self.has_next = False
        self.status.value = message
        self.result_list.controls = [_empty_state(ft.Icons.CLOUD_OFF_ROUNDED, message)]
        self._update_search_navigation(update_status=False)
        self.app.page.update(
            self.button,
            self.status,
            self.result_list,
            self.pagination,
        )

    def _render_search_results(self, *, update: bool = True) -> None:
        if not self.results:
            self.result_list.controls = [
                _empty_state(
                    ft.Icons.SEARCH_OFF_ROUNDED, "No matching music was found."
                )
            ]
        else:
            self.result_list.controls = self.app.views._search_results(self.app)
        if update:
            self.app.page.update(self.result_list)

    def _set_search_view(self, selected: list[str]) -> None:
        self.view_mode = selected[0] if selected else "list"
        self._render_search_results()

    def _update_search_navigation(self, *, update_status: bool = True) -> None:
        result_count = len(self.results)
        result_word = "result" if result_count == 1 else "results"
        if update_status:
            if result_count:
                playlist = f"{self.playlist_title} • " if self.playlist_title else ""
                self.status.value = (
                    f"{playlist}Page {self.page_number} • {result_count} {result_word}"
                )
            else:
                self.status.value = "No matching music was found."
        self.page_number_label.value = f"Page {self.page_number}"
        self.pagination.visible = bool(self.results) or self.page_number > 1
        self.first_button.disabled = self.busy or self.page_number <= 1
        self.previous_button.disabled = self.busy or self.page_number <= 1
        self.next_button.disabled = self.busy or not self.has_next

    def _search_result_row(
        self, result: SearchResult, playlists: tuple[Playlist, ...]
    ) -> ft.Control:
        return self.app.views._search_result_row(self.app, result, playlists)

    def _search_result_card(
        self, result: SearchResult, playlists: tuple[Playlist, ...]
    ) -> ft.Control:
        return self.app.views._search_result_card(self.app, result, playlists)

    def _available_search_track(self, result: SearchResult):
        """Read the result-page cache; rendering must never hash audio files."""
        return self.local_tracks.get(result.url)

    def _search_result_menu(
        self,
        result: SearchResult,
        playlists: tuple[Playlist, ...],
        *,
        include_primary_actions: bool = False,
    ) -> list[ft.PopupMenuItem]:
        menu_items: list[ft.PopupMenuItem] = []
        local_track = self._available_search_track(result)
        if include_primary_actions and local_track is None:
            menu_items.append(
                ft.PopupMenuItem(
                    content=("Download playlist" if result.is_playlist else "Download"),
                    icon=ft.Icons.DOWNLOAD_ROUNDED,
                    on_click=lambda _, item=result: self._download_result(item),
                )
            )
        known_track = local_track or (
            None
            if result.is_playlist
            else self.app.manager.find_track_by_source(result.url)
        )
        favorite = bool(
            known_track and self.app.library.details(known_track.id).favorite
        )
        menu_items.extend(
            [
                ft.PopupMenuItem(
                    content="Play next",
                    icon=ft.Icons.QUEUE_PLAY_NEXT_ROUNDED,
                    on_click=lambda _, item=result: self._act_on_search_result(
                        item, "next"
                    ),
                ),
                ft.PopupMenuItem(
                    content="Add to queue",
                    icon=ft.Icons.ADD_TO_QUEUE_ROUNDED,
                    on_click=lambda _, item=result: self._act_on_search_result(
                        item, "queue"
                    ),
                ),
                ft.PopupMenuItem(
                    content="Remove favorite" if favorite else "Favorite",
                    icon=ft.Icons.FAVORITE_BORDER_ROUNDED,
                    on_click=lambda _, item=result: self._act_on_search_result(
                        item, "favorite"
                    ),
                ),
            ]
        )
        menu_items.extend(
            ft.PopupMenuItem(
                content=f"Add to {playlist.name}",
                icon=ft.Icons.PLAYLIST_ADD_ROUNDED,
                on_click=lambda _, item=result, pid=str(playlist.id): (
                    self._act_on_search_result(item, "playlist", pid)
                ),
            )
            for playlist in playlists
        )
        menu_items.append(
            ft.PopupMenuItem(
                content="View details",
                icon=ft.Icons.INFO_OUTLINE_ROUNDED,
                on_click=lambda _, item=result: self._search_result_details(item),
            )
        )
        return menu_items

    def _download_result(
        self,
        result: SearchResult,
        *,
        after: str = "",
        playlist_id: str | None = None,
        request_generation: int | None = None,
    ) -> None:
        def prepare():
            was_active = self.app.downloads.is_source_active(result.url)
            task = self.app.downloads.request(result)
            existing = (
                self.app.downloads.available_track(result.url) if task is None else None
            )
            return was_active, task, existing

        def finish(value):
            was_active, task, existing = value
            relevant = after != "play" or (
                request_generation is not None
                and self.app.playback.is_current_request(request_generation)
            )
            if existing:
                self.local_tracks[result.url] = existing
                if after and relevant:
                    self._apply_track_action([str(existing.id)], after, playlist_id)
                elif not after:
                    self.app._show_message("This track is already in your library.")
                return
            if task is None:
                return
            if after and relevant:
                self.app.pending_download_actions[str(task.id)] = (after, playlist_id)
                if request_generation is not None:
                    self.app._download_play_requests[str(task.id)] = request_generation
                record = self.app.downloads.get(str(task.id))
                if record and record.status in {"completed", "failed", "cancelled"}:
                    self.app._download_changed(record)
            self.app._show_message(
                "Download already in progress." if was_active else "Downloading…"
            )

        def failed(message):
            if after == "play" and request_generation is not None:
                if not self.app.playback.is_current_request(request_generation):
                    return
                self.app.playback.on_backend_error(message)
            else:
                self.app._show_error(message)

        run_io(
            self.app,
            prepare,
            finish,
            key=("download", result.url, after),
            replace=True,
            failed=failed,
        )

    def _act_on_search_result(
        self, result: SearchResult, action: str, playlist_id: str | None = None
    ) -> None:
        existing = self._available_search_track(result)
        if existing is None and action == "favorite" and not result.is_playlist:
            # Favoriting is metadata-only, so it remains useful for a known
            # record even while its managed file is awaiting repair.
            existing = self.app.manager.find_track_by_source(result.url)
        if existing:
            if action == "favorite":
                self.app.library_page._toggle_favorite(str(existing.id))
            else:
                self._apply_track_action([str(existing.id)], action, playlist_id)
            return
        self._download_result(result, after=action, playlist_id=playlist_id)

    def _apply_track_action(
        self, track_ids: list[str], action: str, playlist_id: str | None = None
    ) -> None:
        available = [
            track_id for track_id in track_ids if self.app.manager.has_track(track_id)
        ]
        if not available:
            return
        if action == "next":
            self.app.playback.add_next_many(available)
            message = "Ready to play next."
        elif action == "queue":
            self.app.playback.add_last_many(available)
            message = "Added to the queue."
        elif action == "playlist" and playlist_id:
            run_io(
                self.app,
                lambda: self.app.manager.add_tracks_to_playlist(playlist_id, available),
                lambda _: self.app._show_message("Added to playlist."),
            )
            return
        elif action == "favorite":
            run_io(
                self.app,
                lambda: self.app.library.favorite_tracks(available),
                lambda _: self.app._show_message("Added to favorites."),
            )
            return
        elif action == "play":
            autoplay = (
                self.app.playback.playing
                if self.app.playback.snapshot.loading
                else True
            )
            self.app.playback.play_tracks(available)
            if not autoplay:
                self.app.playback.toggle()
            message = "Preparing track…"
        else:
            return
        self.app._show_message(message)

    def _search_result_details(self, result: SearchResult) -> None:
        detail_rows = [
            ("Uploader / channel", result.uploader or "Unknown uploader"),
            ("Source", result.source),
            ("Type", "Playlist" if result.is_playlist else "Track"),
        ]
        if result.duration:
            detail_rows.append(("Duration", _format_duration(result.duration)))
        if result.entry_count:
            detail_rows.append(("Tracks", str(result.entry_count)))
        self.app.page.show_dialog(
            ft.AlertDialog(
                modal=True,
                title=ft.Text(result.title),
                content=ft.Column(
                    [
                        ft.Row(
                            [
                                ft.Text(
                                    label,
                                    width=130,
                                    color=ft.Colors.ON_SURFACE_VARIANT,
                                ),
                                ft.Text(value, selectable=True, expand=True),
                            ]
                        )
                        for label, value in detail_rows
                    ]
                    + [ft.Text(result.url, size=11, selectable=True)],
                    tight=True,
                ),
                scrollable=True,
                inset_padding=ft.Padding.symmetric(horizontal=16, vertical=24),
                actions=[
                    ft.TextButton(
                        "Close", on_click=lambda _: self.app.page.pop_dialog()
                    )
                ],
            )
        )

    def _play_search_result(self, result: SearchResult) -> None:
        if (
            self.app.playback.snapshot.loading
            and self.app.playback.external_title == result.title
        ):
            return
        generation = self.app.playback.begin_pending_track(result.title)
        if not result.is_playlist:
            self._download_result(result, after="play", request_generation=generation)
            return

        def finish(stream):
            if self.app.playback.is_current_request(generation):
                autoplay = self.app.playback.playing
                self.app.playback.play_stream(
                    stream,
                    title=result.title,
                    uploader=result.uploader,
                    thumbnail=result.thumbnail,
                )
                if not autoplay:
                    self.app.playback.toggle()

        def failed(message):
            if self.app.playback.is_current_request(generation):
                self.app.playback.on_backend_error(message)

        run_io(
            self.app,
            lambda: self.app.providers.get(result.provider_id).resolve_stream(
                result.url
            ),
            finish,
            key="preview",
            replace=True,
            failed=failed,
        )

    def _search_draft_changed(self, event) -> None:
        self.draft = event.control.value or ""
