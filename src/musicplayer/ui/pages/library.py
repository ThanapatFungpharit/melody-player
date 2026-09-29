from __future__ import annotations

import asyncio
from pathlib import Path
from typing import TYPE_CHECKING, Any

import flet as ft

from musicplayer.application.models import TrackDetails
from musicplayer.core.library.models import Playlist, Track
from musicplayer.ui.components.common import (
    _empty_state,
    _format_duration,
    _track_title,
)
from musicplayer.ui.components.track_pages import PAGE_SIZE
from musicplayer.ui.tasks import page_action

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


class LibraryPage:
    RENDER_BATCH_SIZE = PAGE_SIZE
    QUERY_DEBOUNCE_SECONDS = 0.15

    query: ft.TextField
    sort: ft.Dropdown
    track_list: ft.Column | ft.ListView

    def __init__(self, app: MusicPlayerApp):
        self.app = app
        self.reset()

    """Library page UI and local-track workflows."""

    def reset(self) -> None:
        pending = getattr(self, "_query_task", None)
        if pending is not None:
            pending.cancel()
        self._query_task = None
        self._query_generation = 0
        self._page_offset = 0
        self.mode = "tracks"
        self.query_text = ""
        self.sort_key = "recent"

    def _library_view(self) -> ft.Control:
        return self.app.views._library_view(self.app)

    def _refresh_library_list(self, *, update: bool = True) -> bool:
        if self.mode not in {"tracks", "playlists"}:
            self.mode = "tracks"
        if self.mode == "tracks":
            fetched = self.app.library.tracks(
                query=self.query_text,
                sort=self.sort_key,
                offset=self._page_offset,
                limit=self.RENDER_BATCH_SIZE + 1,
            )
            while not fetched and self._page_offset:
                self._page_offset = max(0, self._page_offset - self.RENDER_BATCH_SIZE)
                fetched = self.app.library.tracks(
                    query=self.query_text,
                    sort=self.sort_key,
                    offset=self._page_offset,
                    limit=self.RENDER_BATCH_SIZE + 1,
                )
            has_more = len(fetched) > self.RENDER_BATCH_SIZE
            tracks = fetched[: self.RENDER_BATCH_SIZE]
            # Playlist menus share one immutable snapshot for the whole render;
            # fetching and copying the same collection once per row made large
            # libraries increasingly expensive to display.
            playlists = self.app.manager.list_playlists()
            details = (
                self.app.library.details_many(track.id for track in tracks)
                if tracks
                else {}
            )
            controls = [
                self._library_track_row(
                    track, index, playlists, details.get(str(track.id))
                )
                for index, track in enumerate(tracks, start=self._page_offset)
            ]
            has_items = bool(tracks)
            if tracks and (self._page_offset or has_more):
                controls.append(
                    ft.Row(
                        [
                            ft.TextButton(
                                "Previous",
                                icon=ft.Icons.CHEVRON_LEFT_ROUNDED,
                                disabled=self._page_offset == 0,
                                on_click=lambda _: self._change_library_page(-1),
                            ),
                            ft.Text(
                                f"{self._page_offset + 1}–{self._page_offset + len(tracks)}",
                                expand=True,
                                text_align=ft.TextAlign.CENTER,
                            ),
                            ft.TextButton(
                                "Next",
                                icon=ft.Icons.CHEVRON_RIGHT_ROUNDED,
                                disabled=not has_more,
                                on_click=lambda _: self._change_library_page(1),
                            ),
                        ],
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    )
                )
        elif self.mode == "playlists":
            search_term = self.query_text.casefold()
            controls: list[ft.Control] = [
                self.app.shared._playlist_card(playlist)
                for playlist in self.app.manager.list_playlists()
                if not search_term or search_term in playlist.name.casefold()
            ]
            has_items = bool(controls)
            if controls:
                controls = [ft.Row(controls, wrap=True, spacing=14, run_spacing=14)]
        self.track_list.controls = controls
        if not controls:
            self.track_list.controls = [
                _empty_state(
                    ft.Icons.LIBRARY_MUSIC_ROUNDED,
                    "Nothing matches this view. Search for music or add local files.",
                )
            ]
        if update:
            self.app.page.update(self.track_list)
        return has_items

    def _change_library_page(self, direction: int) -> None:
        self._page_offset = max(
            0, self._page_offset + direction * self.RENDER_BATCH_SIZE
        )
        self._refresh_library_list()

    def _set_library_mode(self, selected: list[str]) -> None:
        self.mode = selected[0] if selected else "tracks"
        self._page_offset = 0
        self._refresh_library_list()

    def _visible_library_tracks(self) -> tuple[Track, ...]:
        return self.app.library.tracks(query=self.query_text, sort=self.sort_key)

    def _play_visible_library(self) -> None:
        self.app.shared._play_collection(self._visible_library_tracks())

    def _shuffle_visible_library(self) -> None:
        self.app.shared._shuffle_collection(self._visible_library_tracks())

    def _queue_visible_library(self) -> None:
        self.app.shared._queue_collection(self._visible_library_tracks())

    @page_action
    async def _export_library(self, _: Any = None) -> None:
        contents = await self.app.tasks.io(self.app.library.export_library_m3u8)
        saved = await self.app.file_picker.save_file(
            dialog_title="Export library playlist",
            file_name="Melody Library.m3u8",
            file_type=ft.FilePickerFileType.CUSTOM,
            allowed_extensions=["m3u8"],
            src_bytes=contents,
        )
        if saved:
            self.app._show_message("Library playlist exported.")

    async def _pick_local_files(self, _: Any) -> None:
        files = await self.app.file_picker.pick_files(
            dialog_title="Add music to Melody",
            file_type=ft.FilePickerFileType.CUSTOM,
            allowed_extensions=["mp3", "m4a", "opus", "wav", "flac", "ogg", "aac"],
            allow_multiple=True,
        )
        paths = [item.path for item in (files or []) if item.path]
        if paths:
            self._import_local_files(paths)
            self.app._show_message(
                f"Importing {len(paths)} local file{'s' if len(paths) != 1 else ''}…"
            )

    @page_action
    async def _import_local_files(self, paths: list[str]) -> None:
        imported = 0
        imported_track_ids: list[str] = []
        failures: list[str] = []
        for path in paths:
            try:
                track_id = await self.app.tasks.io(
                    self.app.library.import_local_file, path
                )
            except (OSError, ValueError) as error:
                failures.append(f"{Path(path).name}: {error}")
            else:
                imported += 1
                imported_track_ids.append(str(track_id))
        if imported_track_ids and self.app._is_android_platform():
            self.app._pending_music_exports.update(imported_track_ids)
            self.app.tasks.start(self.app._drain_music_exports)
        if self.app.selected_navigation == 2:
            self._refresh_library_list()
        if failures:
            self.app._show_error(
                f"Imported {imported} file{'s' if imported != 1 else ''}. "
                + " • ".join(failures[:3])
            )
        else:
            self.app._show_message(
                f"Added {imported} local file{'s' if imported != 1 else ''} to the library."
            )

    def _library_track_row(
        self,
        track: Track,
        index: int,
        playlists: tuple[Playlist, ...] | None = None,
        details: TrackDetails | None = None,
    ) -> ft.Control:
        return self.app.views._library_track_row(
            self.app, track, index, playlists, details
        )

    @page_action
    async def _toggle_favorite(self, track_id: str) -> None:
        await self.app.tasks.io(self.app.library.toggle_favorite, track_id)
        if self.app.selected_navigation == 2:
            self._refresh_library_list()
        elif self.app.selected_navigation == 0:
            self.app.navigation.navigate(0)
        elif self.app.selected_navigation == 3:
            self.app.navigation.navigate(3)
        self.app.player_bar._refresh_player()
        if (
            track_id == self.app.playback.current_track_id
            and not self.app.playback.external_title
        ):
            self.app._sync_system_media(refresh_metadata=True)

    def _toggle_current_favorite(self, event: Any) -> None:
        if self.app.playback.current_track_id:
            self._toggle_favorite(self.app.playback.current_track_id)

    def _rename_track_dialog(self, track: Track) -> None:
        field = ft.TextField(
            value=_track_title(track), label="Track title", autofocus=True
        )

        async def save(_: Any) -> None:
            try:
                await self.app.tasks.io(
                    self.app.library.rename_track, track.id, field.value
                )
            except ValueError as error:
                self.app._show_error(str(error))
                return
            self.app.page.pop_dialog()
            if self.app.selected_navigation == 2:
                self._refresh_library_list()
            else:
                self.app.navigation.navigate(self.app.selected_navigation)
            self.app.player_bar._refresh_player()
            if self.app.playback.current_track_id == str(track.id):
                self.app._sync_system_media()

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("Edit track title"),
                content=field,
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button("Save", on_click=save),
                ],
            )
        )

    def _track_details_dialog(self, track: Track) -> None:
        details = self.app.library.details(track.id)
        try:
            path = str(self.app.manager.track_path(track.id))
        except KeyError, ValueError:
            path = "Unavailable"
        rows = [
            ("Title", _track_title(track)),
            ("Uploader / channel", details.uploader or "—"),
            ("Duration", _format_duration(details.duration)),
            ("Source", details.source_name or track.source or "Local"),
            ("File", path),
        ]
        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("Track details"),
                content=ft.Column(
                    [
                        ft.Row(
                            [
                                ft.Text(
                                    label,
                                    width=130,
                                    color=ft.Colors.ON_SURFACE_VARIANT,
                                ),
                                ft.Text(
                                    value, selectable=True, expand=True, max_lines=3
                                ),
                            ],
                            vertical_alignment=ft.CrossAxisAlignment.START,
                        )
                        for label, value in rows
                    ],
                    tight=True,
                ),
                inset_padding=ft.Padding.symmetric(horizontal=16, vertical=24),
                actions=[
                    ft.TextButton(
                        "Close", on_click=lambda _: self.app.page.pop_dialog()
                    )
                ],
            )
        )

    def _delete_track_dialog(self, track: Track) -> None:
        async def confirm(_: Any) -> None:
            queue_indexes = [
                index
                for index, track_id in enumerate(self.app.playback.queue.items)
                if track_id == str(track.id)
            ]
            # Detach the file from the active player before deleting it. The
            # queue controller pauses or advances the backend as needed.
            for index in reversed(queue_indexes):
                self.app.playback.remove_queue_item(index)
            try:
                await self.app.tasks.io(
                    self.app.library.delete_track_and_file, track.id
                )
            except OSError as error:
                self.app._show_error(
                    f"The track could not be deleted completely: {error}"
                )
                return
            self.app.page.pop_dialog()
            self.app.navigation.navigate(2)

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("Delete track?"),
                content=ft.Column(
                    [
                        ft.Text(
                            f"“{_track_title(track)}” will be deleted from the library, every playlist, and managed local storage."
                        ),
                    ],
                    tight=True,
                ),
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button(
                        "Delete track",
                        icon=ft.Icons.DELETE_FOREVER_ROUNDED,
                        on_click=confirm,
                    ),
                ],
            )
        )

    def _library_track_menu(
        self,
        track: Track,
        index: int,
        playlists: tuple[Playlist, ...] | None = None,
        details: TrackDetails | None = None,
    ) -> list[ft.PopupMenuItem]:
        details = details or self.app.library.details(track.id)
        playlists = (
            playlists if playlists is not None else self.app.manager.list_playlists()
        )
        menu_items: list[ft.PopupMenuItem] = [
            ft.PopupMenuItem(
                content="Play next",
                icon=ft.Icons.QUEUE_PLAY_NEXT_ROUNDED,
                on_click=lambda _, item=str(track.id): self.app.playback.add_next(item),
            ),
            ft.PopupMenuItem(
                content="Add to queue",
                icon=ft.Icons.ADD_TO_QUEUE_ROUNDED,
                on_click=lambda _, item=str(track.id): self.app.playback.add_last(item),
            ),
        ]
        menu_items.extend(
            ft.PopupMenuItem(
                content=f"Add to {playlist.name}",
                icon=ft.Icons.PLAYLIST_ADD_ROUNDED,
                on_click=lambda _, pid=str(playlist.id), tid=str(track.id): (
                    self.app.playlists_page._add_to_playlist(pid, tid)
                ),
            )
            for playlist in playlists
        )
        menu_items.extend(
            [
                ft.PopupMenuItem(
                    content="Remove favorite" if details.favorite else "Favorite",
                    icon=ft.Icons.FAVORITE_BORDER_ROUNDED,
                    on_click=lambda _, item=str(track.id): self._toggle_favorite(item),
                ),
                ft.PopupMenuItem(
                    content="Edit title",
                    icon=ft.Icons.EDIT_ROUNDED,
                    on_click=lambda _, item=track: self._rename_track_dialog(item),
                ),
                ft.PopupMenuItem(
                    content="View details",
                    icon=ft.Icons.INFO_OUTLINE_ROUNDED,
                    on_click=lambda _, item=track: self._track_details_dialog(item),
                ),
                ft.PopupMenuItem(
                    content="Delete track and file…",
                    icon=ft.Icons.DELETE_FOREVER_ROUNDED,
                    on_click=lambda _, item=track: self._delete_track_dialog(item),
                ),
            ]
        )
        return menu_items

    def _library_query_changed(self, event) -> None:
        self.query_text = event.control.value or ""
        self._page_offset = 0
        self._query_generation += 1
        generation = self._query_generation
        pending = self._query_task
        if pending is not None:
            pending.cancel()
        if not hasattr(self.app.page, "run_task"):
            self._refresh_library_list()
            return
        try:
            self._query_task = self.app.page.run_task(
                self._apply_query_after_delay, generation
            )
        except RuntimeError:
            self._refresh_library_list()

    async def _apply_query_after_delay(self, generation: int) -> None:
        try:
            await asyncio.sleep(self.QUERY_DEBOUNCE_SECONDS)
        except asyncio.CancelledError:
            return
        if (
            generation == self._query_generation
            and self.app.selected_navigation == 2
            and hasattr(self, "track_list")
        ):
            self._refresh_library_list()

    def _library_sort_changed(self, event) -> None:
        self._set_library_sort(event.control.value or "recent")

    def _set_library_sort(self, value: str) -> None:
        self.sort_key = value
        self._page_offset = 0
        sort_control = getattr(self, "library_sort", None)
        if sort_control is not None:
            sort_control.value = value
        self._refresh_library_list()
