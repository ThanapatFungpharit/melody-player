from __future__ import annotations

import asyncio
import re
from collections import deque
from dataclasses import dataclass, field
from threading import RLock
from typing import TYPE_CHECKING, Any

import flet as ft

from musicplayer.application.models import SearchResult, TrackDetails
from musicplayer.application.providers import RemotePlaylist
from musicplayer.core.concurrency import WorkerQueueFull
from musicplayer.core.library.models import Playlist, Track
from musicplayer.core.media import (
    YOUTUBE_MUSIC_NAME,
    is_youtube_playlist_url,
    source_key,
)
from musicplayer.ui.components.common import (
    _track_credit,
    _track_title,
)
from musicplayer.ui.components.track_pages import (
    PAGE_SIZE,
    page_bounds,
    page_navigation,
)
from musicplayer.ui.tasks import page_action

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


@dataclass
class _PlaylistImportSession:
    playlist_id: str
    name: str
    pending: deque[tuple[str, SearchResult]]
    order: tuple[str, ...]
    resolved: dict[str, str] = field(default_factory=dict)
    active_downloads: dict[str, tuple[str, bool]] = field(default_factory=dict)
    reused: int = 0
    downloaded: int = 0
    failed: int = 0

    @property
    def total(self) -> int:
        return len(self.order)


class PlaylistsPage:
    """Playlists page UI and playlist-management workflows."""

    def __init__(self, app: MusicPlayerApp) -> None:
        self.app = app
        self.reset()

    def reset(self) -> None:
        self.selected_playlist_id: str | None = None
        self._page_offset = 0
        self.playlist_import_session: _PlaylistImportSession | None = None
        self.playlist_import_loading = False
        self.playlist_import_lock = RLock()
        self.playlist_import_retry = None
        self._playlist_import_generation = 0
        self._import_wakeup = asyncio.Event()

    def _playlists_view(self) -> ft.Control:
        return self.app.views._playlists_view(self.app)

    def _open_playlist(self, playlist_id: str) -> None:
        self.selected_playlist_id = playlist_id
        self._page_offset = 0
        self.app.navigation.navigate(3)

    def _visible_range(self, total: int) -> tuple[int, int]:
        start, end = page_bounds(total, self._page_offset)
        self._page_offset = start
        return start, end

    def _change_page(self, direction: int) -> None:
        self._page_offset = max(0, self._page_offset + direction * PAGE_SIZE)
        self.app.navigation.navigate(3)

    def _playlist_detail(self, playlist: Playlist) -> ft.Control:
        return self.app.views._playlist_detail(self.app, playlist)

    def _playlist_track_row(
        self,
        playlist: Playlist,
        track: Track,
        index: int,
        other_playlists: tuple[Playlist, ...],
        playlist_track_ids: tuple[str, ...],
        details: TrackDetails | None = None,
    ) -> ft.Control:
        return self.app.views._playlist_track_row(
            self.app,
            playlist,
            track,
            index,
            other_playlists,
            playlist_track_ids,
            details,
        )

    def _close_playlist(self) -> None:
        self.selected_playlist_id = None
        self._page_offset = 0
        self.app.navigation.navigate(3)

    def _play_playlist(self, playlist: Playlist) -> None:
        ids = [str(track_id) for track_id in playlist.track_ids]
        self.app.playback.play_tracks(ids)

    def _shuffle_playlist(self, playlist: Playlist) -> None:
        ids = [str(track_id) for track_id in playlist.track_ids]
        self.app.playback.play_tracks_shuffled(ids)

    @page_action
    async def _export_playlist(self, playlist: Playlist) -> None:
        contents = await self.app.tasks.io(
            self.app.library.export_playlist_m3u8, playlist.id
        )
        safe_name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", playlist.name).strip(" .")
        saved = await self.app.file_picker.save_file(
            dialog_title="Export playlist",
            file_name=f"{safe_name or 'Playlist'}.m3u8",
            file_type=ft.FilePickerFileType.CUSTOM,
            allowed_extensions=["m3u8"],
            src_bytes=contents,
        )
        if saved:
            self.app._show_message("Playlist exported.")

    def _create_playlist_dialog(self) -> None:
        field = ft.TextField(label="Playlist name", autofocus=True)

        async def create(_: Any) -> None:
            try:
                playlist_id = await self.app.tasks.io(
                    self.app.manager.create_playlist, field.value
                )
            except ValueError as error:
                self.app._show_error(str(error))
                return
            self.app.page.pop_dialog()
            self.selected_playlist_id = str(playlist_id)
            self.app.navigation.navigate(3)

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("New playlist"),
                content=field,
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button("Create", on_click=create),
                ],
            )
        )

    def _import_playlist_dialog(self) -> None:
        if self.playlist_import_loading or self.playlist_import_session is not None:
            self.app._show_error("A playlist import is already in progress.")
            return

        field = ft.TextField(
            label=f"{YOUTUBE_MUSIC_NAME} playlist URL",
            hint_text="https://music.youtube.com/playlist?list=…",
            autofocus=True,
            width=min(560, max(160, float(self.app.page.width or 360) - 80)),
        )

        def begin(_: Any) -> None:
            url = (field.value or "").strip()
            if not is_youtube_playlist_url(url):
                field.error = f"Paste a complete {YOUTUBE_MUSIC_NAME} playlist URL."
                self.app.page.update(field)
                return
            self.playlist_import_loading = True
            import_button.disabled = True
            self._load_playlist_import(url)
            self.app.page.pop_dialog()
            self.app._show_message(f"Loading the {YOUTUBE_MUSIC_NAME} playlist…")

        import_button = ft.Button(
            "Import playlist",
            icon=ft.Icons.DOWNLOAD_ROUNDED,
            on_click=begin,
        )
        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("Import playlist"),
                content=ft.Column(
                    [
                        ft.Text(
                            f"Paste a {YOUTUBE_MUSIC_NAME} playlist link. Melody will reuse tracks "
                            "already in your library and download only the missing ones."
                        ),
                        field,
                    ],
                    spacing=14,
                    tight=True,
                ),
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    import_button,
                ],
            )
        )

    @page_action
    async def _load_playlist_import(self, url: str) -> None:
        generation = self._playlist_import_generation
        try:
            remote = await self.app.tasks.io(self.app.providers.load_playlist, url)
            if generation == self._playlist_import_generation:
                await self._import_playlist(remote, generation)
        finally:
            self.playlist_import_loading = False

    @page_action
    async def _begin_playlist_import(self, remote: RemotePlaylist) -> None:
        await self._import_playlist(remote, self._playlist_import_generation)

    async def _import_playlist(self, remote: RemotePlaylist, generation: int) -> None:
        if self.playlist_import_session is not None:
            self.app._show_error("A playlist import is already in progress.")
            return
        self.playlist_import_loading = True
        name = remote.title.strip() or f"Imported {YOUTUBE_MUSIC_NAME} playlist"
        unique = {source_key(item.url): item for item in remote.tracks if item.url}
        playlist_id = str(
            await self.app.tasks.io(self.app.manager.create_playlist, name)
        )
        if generation != self._playlist_import_generation:
            return
        session = _PlaylistImportSession(
            playlist_id, name, deque(unique.items()), tuple(unique)
        )
        self.playlist_import_session = session
        self.selected_playlist_id = playlist_id
        self.app._show_message(f"Importing {session.total} tracks into “{name}”…")
        try:
            while (
                session.pending or session.active_downloads
            ) and self.playlist_import_session is session:
                playlist_changed = False
                queue_full = False

                # ``DownloadCoordinator.request`` is non-blocking: it admits one
                # independent downloader job and returns its task immediately.
                # Keep submitting until its bounded executor reports backpressure,
                # then refill the queue after terminal notifications wake us.
                while session.pending and self.playlist_import_session is session:
                    key, result = session.pending[0]
                    try:
                        if hasattr(self.app.downloads, "request_with_ownership"):
                            task, owned = await self.app.tasks.io(
                                self.app.downloads.request_with_ownership, result
                            )
                        else:
                            was_active = self.app.downloads.is_source_active(result.url)
                            task = await self.app.tasks.io(
                                self.app.downloads.request, result
                            )
                            owned = task is not None and not was_active
                    except WorkerQueueFull:
                        queue_full = True
                        break
                    except OSError, RuntimeError, ValueError:
                        session.failed += 1
                        session.pending.popleft()
                        continue
                    if self.playlist_import_session is not session:
                        if task is not None and owned:
                            await self.app.tasks.io(
                                self.app.downloads.cancel, str(task.id)
                            )
                        return
                    if task is None:
                        existing = await self.app.tasks.io(
                            self.app.downloads.available_track, result.url
                        )
                        if existing is not None:
                            session.resolved[key] = str(existing.id)
                            session.reused += 1
                            playlist_changed = True
                        else:
                            # ``None`` means the request resolved to a local track.
                            # If it disappeared before the follow-up read, do not
                            # spin forever or silently claim it was imported.
                            session.failed += 1
                        session.pending.popleft()
                        continue
                    session.active_downloads[key] = (
                        str(task.id),
                        owned,
                    )
                    session.pending.popleft()

                if self.playlist_import_session is not session:
                    return

                # Clear before reading records so a completion cannot be lost:
                # it is either visible in this snapshot or sets the event after
                # the snapshot and wakes the subsequent wait.
                self._import_wakeup.clear()
                terminal_seen = False
                for key, (task_id, _) in tuple(session.active_downloads.items()):
                    record = self.app.downloads.get(task_id)
                    if record is None or record.status not in {
                        "completed",
                        "failed",
                        "cancelled",
                    }:
                        continue
                    terminal_seen = True
                    session.active_downloads.pop(key, None)
                    if record.status == "completed" and record.track_ids:
                        session.resolved[key] = record.track_ids[0]
                        session.downloaded += 1
                        playlist_changed = True
                    else:
                        session.failed += 1

                if playlist_changed:
                    order = [
                        session.resolved[item]
                        for item in session.order
                        if item in session.resolved
                    ]
                    await self.app.tasks.io(
                        self.app.manager.merge_tracks_into_playlist, playlist_id, order
                    )
                    if (
                        self.playlist_import_session is session
                        and self.app.selected_navigation == 3
                    ):
                        self.app.navigation.navigate(3)

                if not session.pending and not session.active_downloads:
                    break
                if terminal_seen:
                    continue
                if session.active_downloads:
                    await self._import_wakeup.wait()
                elif queue_full:
                    # The bounded downloader may currently be occupied entirely
                    # by non-playlist work. Its terminal callback also wakes this
                    # session; the timeout covers lightweight test/embedding
                    # coordinators that do not publish unrelated notifications.
                    try:
                        await asyncio.wait_for(self._import_wakeup.wait(), timeout=0.2)
                    except TimeoutError:
                        pass
            self._finish_playlist_import(session)
        finally:
            self.playlist_import_loading = False
            if self.playlist_import_session is session:
                self.playlist_import_session = None

    def notify_download_changed(self) -> None:
        """Wake the importer so it can inspect coordinator-owned records."""
        self._import_wakeup.set()

    def _cancel_playlist_import_retry(self) -> None:
        self._playlist_import_generation += 1
        self._import_wakeup.set()

    def _abandon_playlist_import(self, playlist_id: str | None = None) -> bool:
        session = getattr(self, "playlist_import_session", None)
        if playlist_id is not None and (
            session is None or session.playlist_id != playlist_id
        ):
            return False
        self._playlist_import_generation = (
            getattr(self, "_playlist_import_generation", 0) + 1
        )
        self.playlist_import_session = None
        wakeup = getattr(self, "_import_wakeup", None)
        if wakeup is not None:
            wakeup.set()
        if session is not None:
            owned_task_ids = [
                task_id for task_id, owned in session.active_downloads.values() if owned
            ]
            if owned_task_ids:

                def cancel_owned_downloads() -> None:
                    for task_id in owned_task_ids:
                        self.app.downloads.cancel(task_id)

                self.app.tasks.submit(cancel_owned_downloads, lambda _: None)
        return session is not None

    def _finish_playlist_import(self, session: _PlaylistImportSession) -> None:
        if self.playlist_import_session is not session:
            return
        self.playlist_import_session = None
        self._cancel_playlist_import_retry()
        imported = session.total - session.failed
        if self.app.selected_navigation == 3:
            self.app.navigation.navigate(3)
        summary = (
            f"Imported {imported} of {session.total} tracks into “{session.name}”: "
            f"reused {session.reused}, downloaded {session.downloaded}."
        )
        if session.failed:
            self.app._show_error(f"{summary} {session.failed} could not be downloaded.")
        else:
            self.app._show_message(summary)

    def _rename_playlist_dialog(self, playlist: Playlist) -> None:
        field = ft.TextField(label="Playlist name", value=playlist.name, autofocus=True)

        async def save(_: Any) -> None:
            try:
                await self.app.tasks.io(
                    self.app.manager.rename_playlist, playlist.id, field.value
                )
            except ValueError as error:
                self.app._show_error(str(error))
                return
            self.app.page.pop_dialog()
            self.app.navigation.navigate(3)

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("Rename playlist"),
                content=field,
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button("Save", on_click=save),
                ],
            )
        )

    def _delete_playlist_dialog(self, playlist: Playlist) -> None:
        def confirm(_: Any) -> None:
            async def commit() -> None:
                await self.app.tasks.io(self.app.manager.delete_playlist, playlist.id)
                self._abandon_playlist_import(str(playlist.id))
                self.app.page.pop_dialog()
                self.selected_playlist_id = None
                self.app.navigation.navigate(3)

            self.app.tasks.start(lambda: commit())

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text("Delete playlist?"),
                content=ft.Text(
                    f"Delete “{playlist.name}”? Your downloaded tracks will stay in the library."
                ),
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button("Delete", on_click=confirm),
                ],
            )
        )

    @page_action
    async def _add_to_playlist(self, playlist_id: str, track_id: str) -> None:
        await self.app.tasks.io(self.app.manager.add_to_playlist, playlist_id, track_id)
        self.app._show_message("Added to playlist.")

    def _bulk_add_tracks_dialog(self, playlist: Playlist) -> None:
        member_ids = {str(track_id) for track_id in playlist.track_ids}
        candidates = [
            track
            for track in self.app.manager.list_tracks()
            if str(track.id) not in member_ids
        ]
        selected_ids: set[str] = set()
        offset = 0
        search = ft.TextField(label="Find a track", prefix_icon=ft.Icons.SEARCH_ROUNDED)
        select_all = ft.Checkbox(
            label="Select all tracks", value=False, disabled=not candidates
        )
        selection = ft.Text(
            "No tracks selected",
            size=12,
            color=ft.Colors.ON_SURFACE_VARIANT,
        )
        track_list = ft.Column(
            spacing=2,
            height=min(340, max(96, float(self.app.page.height or 640) * 0.35)),
            scroll=ft.ScrollMode.AUTO,
        )
        pager = ft.Container()
        add_button = ft.Button(
            "Add selected", icon=ft.Icons.PLAYLIST_ADD_ROUNDED, disabled=True
        )

        def update_selection() -> None:
            selected = len(selected_ids)
            select_all.value = bool(candidates) and selected == len(candidates)
            add_button.disabled = selected == 0
            selection.value = (
                f"{selected} track{'s' if selected != 1 else ''} selected"
                if selected
                else "No tracks selected"
            )

        def render_page(*, update: bool = True) -> None:
            nonlocal offset
            term = (search.value or "").casefold()
            matching = [
                track
                for track in candidates
                if not term or term in _track_title(track).casefold()
            ]
            start, end = page_bounds(len(matching), offset)
            offset = start
            visible = matching[start:end]
            details = self.app.library.details_many(track.id for track in visible)
            track_list.controls = [
                ft.Checkbox(
                    label=(
                        f"{_track_title(track)} — "
                        f"{_track_credit(details[str(track.id)])}"
                    ),
                    value=str(track.id) in selected_ids,
                    on_change=lambda event, tid=str(track.id): toggle_track(
                        tid, bool(event.control.value)
                    ),
                )
                for track in visible
            ]
            if not matching:
                track_list.controls = [
                    ft.Text(
                        "Every library track is already in this playlist."
                        if not candidates
                        else "No tracks match this search."
                    )
                ]
            pager.content = page_navigation(len(matching), start, end, change_page)
            update_selection()
            if update:
                self.app.page.update(
                    track_list, pager, select_all, selection, add_button
                )

        def change_page(direction: int) -> None:
            nonlocal offset
            offset += direction * PAGE_SIZE
            render_page()

        def toggle_track(track_id: str, checked: bool) -> None:
            if checked:
                selected_ids.add(track_id)
            else:
                selected_ids.discard(track_id)
            update_selection()
            self.app.page.update(select_all, selection, add_button)

        def toggle_all(_: Any) -> None:
            if select_all.value:
                selected_ids.update(str(track.id) for track in candidates)
            else:
                selected_ids.clear()
            render_page()

        def search_changed(_: Any) -> None:
            nonlocal offset
            offset = 0
            render_page()

        def add_selected(_: Any) -> None:
            track_ids = [
                str(track.id) for track in candidates if str(track.id) in selected_ids
            ]
            if not track_ids:
                return

            async def commit() -> None:
                try:
                    added = await self.app.tasks.io(
                        self.app.manager.add_tracks_to_playlist, playlist.id, track_ids
                    )
                except (KeyError, ValueError) as error:
                    self.app._show_error(str(error))
                    return
                self.app.page.pop_dialog()
                self.app.navigation.navigate(3)
                self.app._show_message(
                    f"Added {added} track{'s' if added != 1 else ''} to “{playlist.name}”."
                )

            self.app.tasks.start(lambda: commit())

        select_all.on_change = toggle_all
        search.on_change = search_changed
        add_button.on_click = add_selected
        render_page(update=False)

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                title=ft.Text(f"Add tracks to “{playlist.name}”"),
                content=ft.Column(
                    [
                        ft.Text(
                            "Choose multiple tracks from your library and add them in one action."
                        ),
                        search,
                        select_all,
                        ft.Divider(height=1),
                        track_list,
                        pager,
                        selection,
                    ],
                    spacing=10,
                    tight=True,
                    width=min(560, max(160, float(self.app.page.width or 360) - 80)),
                ),
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    add_button,
                ],
            )
        )

    @page_action
    async def _remove_from_playlist(self, playlist_id: str, track_id: str) -> None:
        await self.app.tasks.io(
            self.app.manager.remove_from_playlist, playlist_id, track_id
        )
        self.app.navigation.navigate(3)

    @page_action
    async def _reorder_playlist(
        self, playlist_id: str, old_index: int | None, new_index: int | None
    ) -> None:
        if old_index is None or new_index is None:
            return
        playlist = self.app.manager.get_playlist(playlist_id)
        ordered = [str(track_id) for track_id in playlist.track_ids]
        item = ordered.pop(old_index)
        if new_index > old_index:
            new_index -= 1
        ordered.insert(max(0, min(new_index, len(ordered))), item)
        try:
            await self.app.tasks.io(
                self.app.manager.reorder_playlist, playlist_id, ordered
            )
        except Exception:
            # The visible list moves optimistically. Rebuild from the durable
            # manager order before the page-action boundary reports the error.
            self.app.navigation.navigate(3)
            raise
        self.app.navigation.navigate(3)

    def _playlist_reordered(self, playlist_id: str, event: ft.OnReorderEvent) -> None:
        """Move the rendered row immediately, then persist off the UI loop."""
        old_index = event.old_index
        new_index = event.new_index
        view = event.control
        if (
            old_index is None
            or new_index is None
            or not isinstance(view, ft.ReorderableListView)
            or not (0 <= old_index < len(view.controls))
        ):
            return
        drop_index = new_index
        if new_index > old_index:
            new_index -= 1
        target = max(0, min(new_index, len(view.controls) - 1))
        row = view.controls.pop(old_index)
        view.controls.insert(target, row)
        self.app.page.update(view)
        self._reorder_playlist(
            playlist_id,
            self._page_offset + old_index,
            self._page_offset + drop_index,
        )

    @page_action
    async def _transfer_playlist_track(
        self, source: str, target: str, track_id: str, *, move: bool
    ) -> None:
        if move:
            await self.app.tasks.io(
                self.app.manager.move_track_between_playlists, source, target, track_id
            )
        else:
            await self.app.tasks.io(
                self.app.manager.copy_playlist_track, source, target, track_id
            )
        self.app.navigation.navigate(3)

    def _playlist_track_menu(
        self,
        playlist: Playlist,
        track: Track,
        index: int,
        other_playlists: tuple[Playlist, ...],
        playlist_track_ids: tuple[str, ...],
        details: TrackDetails | None = None,
    ) -> list[ft.PopupMenuItem]:
        details = details or self.app.library.details(track.id)
        menu: list[ft.PopupMenuItem] = [
            ft.PopupMenuItem(
                content="Play next",
                icon=ft.Icons.QUEUE_PLAY_NEXT_ROUNDED,
                on_click=lambda _, tid=str(track.id): self.app.playback.add_next(tid),
            ),
            ft.PopupMenuItem(
                content="Add to queue",
                icon=ft.Icons.ADD_TO_QUEUE_ROUNDED,
                on_click=lambda _, tid=str(track.id): self.app.playback.add_last(tid),
            ),
            ft.PopupMenuItem(
                content="Favorite" if not details.favorite else "Remove favorite",
                icon=ft.Icons.FAVORITE_BORDER_ROUNDED,
                on_click=lambda _, tid=str(track.id): (
                    self.app.library_page._toggle_favorite(tid)
                ),
            ),
            ft.PopupMenuItem(
                content="View details",
                icon=ft.Icons.INFO_OUTLINE_ROUNDED,
                on_click=lambda _, item=track: (
                    self.app.library_page._track_details_dialog(item)
                ),
            ),
        ]
        for target in other_playlists:
            menu.extend(
                [
                    ft.PopupMenuItem(
                        content=f"Copy to {target.name}",
                        icon=ft.Icons.CONTENT_COPY_ROUNDED,
                        on_click=lambda _, source=str(playlist.id), destination=str(target.id), tid=str(track.id): (
                            self._transfer_playlist_track(
                                source, destination, tid, move=False
                            )
                        ),
                    ),
                    ft.PopupMenuItem(
                        content=f"Move to {target.name}",
                        icon=ft.Icons.DRIVE_FILE_MOVE_OUTLINE,
                        on_click=lambda _, source=str(playlist.id), destination=str(target.id), tid=str(track.id): (
                            self._transfer_playlist_track(
                                source, destination, tid, move=True
                            )
                        ),
                    ),
                ]
            )
        menu.append(
            ft.PopupMenuItem(
                content="Remove from playlist",
                icon=ft.Icons.REMOVE_CIRCLE_OUTLINE_ROUNDED,
                on_click=lambda _, pid=str(playlist.id), tid=str(track.id): (
                    self._remove_from_playlist(pid, tid)
                ),
            )
        )
        return menu
