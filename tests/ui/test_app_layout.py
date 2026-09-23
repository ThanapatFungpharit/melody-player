from __future__ import annotations

import unittest
from types import SimpleNamespace
from typing import cast
from unittest.mock import Mock, call
from uuid import UUID

import flet as ft

from musicplayer.app import MusicPlayerApp
from musicplayer.application.models import (
    AppSettings,
    DownloadRecord,
    SearchResult,
    TrackDetails,
)
from musicplayer.core.library.models import Playlist, Track
from musicplayer.ui.components import ContextPanel, SharedUIComponents
from musicplayer.ui.desktop.shell import DesktopShell
from musicplayer.ui.pages import (
    DownloadsPage,
    HomePage,
    LibraryPage,
    PlaylistsPage,
    SearchPage,
    SettingsPage,
)


class _Page:
    width = 1540
    height = 960
    window = type("Window", (), {"width": 1540, "height": 960})()

    def update(self, *controls: ft.Control) -> None:
        pass


class _Providers:
    pass


class _Downloads:
    def __init__(self, records: tuple[DownloadRecord, ...]) -> None:
        self.records = records

    def list(self) -> tuple[DownloadRecord, ...]:
        return self.records


class _PlaylistManager:
    def __init__(self, playlists: tuple[Playlist, ...]) -> None:
        self.playlists = playlists

    def list_playlists(self) -> tuple[Playlist, ...]:
        return self.playlists

    def has_playlist(self, playlist_id: str) -> bool:
        return False

    def playlist_tracks(self, playlist_id: UUID) -> tuple[object, ...]:
        return ()

    def list_tracks(self) -> tuple[object, ...]:
        return ()

    def counts(self) -> tuple[int, int]:
        return 0, len(self.playlists)

    def tracks_by_ids(
        self, track_ids: object, *, limit: int | None = None
    ) -> tuple[object, ...]:
        return ()

    def find_track_by_source(self, _: str) -> None:
        return None


class _Library:
    def __init__(self, tracks: tuple[Track, ...] = ()) -> None:
        self.items = tracks
        self.last_limit: int | None = None
        self.last_offset = 0
        self.details_requested = 0

    def tracks(self, **options: object) -> tuple[Track, ...]:
        limit = options.get("limit")
        offset = options.get("offset")
        self.last_limit = limit if isinstance(limit, int) else None
        self.last_offset = offset if isinstance(offset, int) else 0
        items = self.items[self.last_offset :]
        return items if self.last_limit is None else items[: self.last_limit]

    def details_many(self, track_ids: object) -> dict[str, TrackDetails]:
        ids = [str(track_id) for track_id in track_ids]  # ty: ignore[not-iterable]
        self.details_requested += len(ids)
        return {track_id: TrackDetails() for track_id in ids}

    def details(self, track_id: object) -> TrackDetails:
        return TrackDetails()


class _Store:
    def get(self, _: str, default: object = None) -> object:
        return default

    def favorite_track_ids(self) -> frozenset[str]:
        return frozenset()


class AppLayoutTests(unittest.TestCase):
    def _app(self) -> MusicPlayerApp:
        app = MusicPlayerApp.__new__(MusicPlayerApp)
        app.shell = DesktopShell(app)
        app.page = _Page()  # ty: ignore[invalid-assignment]
        app.settings = AppSettings()
        app.providers = _Providers()  # ty: ignore[invalid-assignment]
        app.shared = SharedUIComponents(app)
        app.context_panel = ContextPanel(app)
        app.home_page = HomePage(app)
        app.search_page = SearchPage(app)
        app.library_page = LibraryPage(app)
        app.playlists_page = PlaylistsPage(app)
        app.downloads_page = DownloadsPage(app)
        app.settings_page = SettingsPage(app)
        app.navigation = SimpleNamespace(navigate=Mock())  # ty: ignore[invalid-assignment]
        app.selected_navigation = 0
        app.active_panel = None
        return app

    def test_progress_media_sync_reuses_resolved_track_metadata(self) -> None:
        app = self._app()
        app.playback = SimpleNamespace(  # ty: ignore[invalid-assignment]
            external_title="",
            external_uploader="",
            external_thumbnail="",
            current_track_id="track",
            duration_ms=3000,
            position_ms=1000,
            playing=True,
            media_session_active=True,
            snapshot=SimpleNamespace(loading=False),
            queue=SimpleNamespace(
                repeat=SimpleNamespace(value="none"),
                shuffle=False,
                peek_next=lambda **_: "next",
            ),
        )
        app.manager = Mock()
        app.manager.get_track.return_value = SimpleNamespace(
            title="Cached title", filename="cached.mp3"
        )
        app.library = Mock()
        app.library.details.return_value = SimpleNamespace(
            uploader="Artist", thumbnail="artwork", source_name="YouTube"
        )
        app.backend = Mock()
        app._system_media_key = None
        app._system_media_metadata = ("", "", "", "")

        app._sync_system_media()
        app.playback.position_ms = 2000
        app._sync_system_media(refresh_metadata=False)

        app.manager.get_track.assert_called_once_with("track")
        app.library.details.assert_called_once_with("track")
        self.assertEqual(app.backend.sync_media_session.call_count, 2)
        self.assertEqual(
            app.backend.sync_media_session.call_args_list[-1].kwargs["position_ms"],
            2000,
        )

    def test_foreground_resume_reconciles_native_playback_state(self) -> None:
        app = self._app()
        app.backend = Mock()
        app._sync_system_media = Mock()

        app._app_lifecycle_changed(
            cast(
                ft.AppLifecycleStateChangeEvent,
                SimpleNamespace(state=ft.AppLifecycleState.PAUSE),
            )
        )
        app.backend.set_foreground.assert_called_once_with(False)
        app.backend.refresh_state.assert_not_called()
        app.backend.invalidate_media_session.assert_not_called()
        app._sync_system_media.assert_not_called()

        app._app_lifecycle_changed(
            cast(
                ft.AppLifecycleStateChangeEvent,
                SimpleNamespace(state=ft.AppLifecycleState.RESUME),
            )
        )

        self.assertEqual(
            app.backend.set_foreground.call_args_list,
            [call(False), call(True)],
        )
        app.backend.refresh_state.assert_called_once_with()
        app.backend.invalidate_media_session.assert_called_once_with()
        app._sync_system_media.assert_called_once_with(refresh_metadata=False)

    def test_settings_uses_responsive_sections_and_fixed_footer(self) -> None:
        app = self._app()

        view = app.settings_page._settings_view()
        header = view.controls[0]  # ty: ignore[unresolved-attribute]
        sections = view.controls[1]  # ty: ignore[unresolved-attribute]
        footer = view.controls[-1]  # ty: ignore[unresolved-attribute]

        self.assertIsInstance(header, ft.Row)
        self.assertIsInstance(sections, ft.ResponsiveRow)
        self.assertEqual(sections.columns, 12)
        self.assertEqual(len(sections.controls), 4)
        self.assertEqual(sections.controls[0].col, {"xs": 12, "lg": 6, "xl": 4})
        self.assertEqual(sections.controls[2].col, {"xs": 12, "lg": 12, "xl": 4})
        youtube_access_header = sections.controls[2].content.controls[0]
        self.assertEqual(
            youtube_access_header.controls[1].controls[0].value,
            "YouTube Music access",
        )
        self.assertFalse(self._contains_control(sections.controls[2], ft.Checkbox))
        self.assertEqual(sections.controls[3].col, {"xs": 12})
        reset_everything = sections.controls[3].content.controls[-1]
        self.assertEqual(reset_everything.bgcolor, ft.Colors.ERROR_CONTAINER)
        reset_button = reset_everything.content.controls[-1].content
        self.assertEqual(reset_button.bgcolor, ft.Colors.ERROR)
        self.assertTrue(sections.expand)
        self.assertIsInstance(footer, ft.ResponsiveRow)
        self.assertEqual(footer.columns, 12)
        self.assertEqual(
            footer.controls[-1].content.controls[-1].content,
            "Save settings",
        )

    def test_downloads_use_summary_and_responsive_activity_cards(self) -> None:
        app = self._app()
        app.downloads = _Downloads(  # ty: ignore[invalid-assignment]
            (
                DownloadRecord(
                    id="active",
                    url="https://example.test/active",
                    title="Active track",
                    uploader="Channel",
                    status="downloading",
                ),
                DownloadRecord(
                    id="done",
                    url="https://example.test/done",
                    title="Completed track",
                    status="completed",
                ),
            )
        )

        view = app.downloads_page._downloads_view()
        summary = view.controls[1]  # ty: ignore[unresolved-attribute]
        activity = view.controls[-1]  # ty: ignore[unresolved-attribute]

        self.assertIsInstance(summary, ft.ResponsiveRow)
        self.assertEqual(summary.columns, 12)
        self.assertEqual(len(summary.controls), 4)
        self.assertEqual(
            summary.controls[0].col,
            {"xs": 12, "sm": 6, "lg": 3},
        )
        self.assertIsInstance(activity, ft.ResponsiveRow)
        self.assertEqual(len(activity.controls), 2)
        self.assertEqual(activity.controls[0].col, {"xs": 12, "lg": 6})

    def test_downloads_show_batch_summary_and_per_song_context(self) -> None:
        app = self._app()
        app.downloads = _Downloads(  # ty: ignore[invalid-assignment]
            (
                DownloadRecord(
                    id="batch-active",
                    url="https://example.test/active",
                    title="Active track",
                    status="downloading",
                    progress=0.5,
                    batch_id="batch",
                    batch_position=1,
                    batch_size=2,
                ),
                DownloadRecord(
                    id="batch-done",
                    url="https://example.test/done",
                    title="Completed track",
                    status="completed",
                    progress=1.0,
                    batch_id="batch",
                    batch_position=2,
                    batch_size=2,
                ),
            )
        )

        view = app.downloads_page._downloads_view()
        batch_heading = view.controls[2]  # ty: ignore[unresolved-attribute]
        batch_grid = view.controls[3]  # ty: ignore[unresolved-attribute]
        activity = view.controls[-1]  # ty: ignore[unresolved-attribute]
        first_song_credit = activity.controls[0].content.controls[0].controls[1]

        self.assertEqual(batch_heading.value, "Recent batches")
        self.assertEqual(len(batch_grid.controls), 1)
        self.assertEqual(batch_grid.controls[0].col, {"xs": 12, "lg": 6})
        self.assertIn("Batch song 1 of 2", first_song_credit.controls[1].value)

    def test_playlists_empty_state_uses_a_bounded_flex_child(self) -> None:
        app = self._app()
        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        app.library = object()  # ty: ignore[invalid-assignment]
        app.playlists_page.reset()

        view = app.playlists_page._playlists_view()
        body = view.controls[1]  # ty: ignore[unresolved-attribute]

        self.assertIsInstance(body, ft.Container)
        self.assertTrue(body.expand)
        self.assertIsInstance(body.content, ft.Container)
        self.assertIsNone(body.content.expand)
        self.assertEqual(
            body.content.content.controls[1].value,
            "Create a playlist or import one from YouTube Music to get started.",
        )
        actions = view.controls[0].controls[1].content  # ty: ignore[unresolved-attribute]
        self.assertEqual(actions.controls[0].content, "Import playlist")
        self.assertEqual(actions.controls[1].content, "New playlist")

    def test_all_responsive_page_wraps_have_non_expanding_direct_children(self) -> None:
        app = self._app()
        app.manager = _PlaylistManager(  # ty: ignore[invalid-assignment]
            (Playlist(id=UUID(int=1), name="Existing playlist"),)
        )
        app.library = _Library()  # ty: ignore[invalid-assignment]
        app.store = _Store()  # ty: ignore[invalid-assignment]
        app.search_page.reset()
        app.library_page.reset()
        app.playlists_page.reset()
        app.search_page.results = [
            SearchResult(
                id="result",
                title="Result",
                uploader="Uploader",
                duration=1,
                thumbnail="",
                url="https://example.test/result",
                source="YouTube",
            )
        ]
        app.search_page.view_mode = "grid"

        views = (
            app.home_page._home_view(),
            app.search_page._search_view(),
            app.library_page._library_view(),
            app.playlists_page._playlists_view(),
        )

        for view in views:
            self._assert_wrapping_rows_are_flex_safe(view)

        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        self._assert_wrapping_rows_are_flex_safe(app.playlists_page._playlists_view())

    def test_search_has_no_source_selector_and_uses_youtube(self) -> None:
        app = self._app()
        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        app.store = _Store()  # ty: ignore[invalid-assignment]
        app.search_page.reset()

        view = app.search_page._search_view()
        search_controls = view.controls[1].controls  # ty: ignore[unresolved-attribute]

        self.assertEqual(len(search_controls), 3)
        self.assertFalse(
            any(isinstance(control, ft.Dropdown) for control in search_controls)
        )
        self.assertEqual(app.search_page.query.col, {"xs": 12, "md": 8})
        self.assertIn("YouTube", view.controls[0].controls[1].value)  # ty: ignore[unresolved-attribute]

    def test_loaded_playlist_title_is_shown_above_its_tracks(self) -> None:
        app = self._app()
        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        app.store = _Store()  # ty: ignore[invalid-assignment]
        app.search_page.reset()
        app.search_page.results = [
            SearchResult(
                id="track",
                title="Playlist track",
                uploader="Channel",
                duration=120,
                thumbnail="",
                url="https://youtu.be/track",
                source="YouTube",
                playlist_title="Focus playlist",
            )
        ]
        app.search_page.playlist_title = "Focus playlist"

        app.search_page._search_view()

        self.assertIn("Focus playlist", app.search_page.status.value)
        self.assertIn("1 result", app.search_page.status.value)

    def test_library_auto_loads_bounded_batches_near_scroll_end(self) -> None:
        app = self._app()
        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        tracks = tuple(
            Track(UUID(int=index + 1), f"track-{index}.mp3", title=f"Track {index}")
            for index in range(75)
        )
        library = _Library(tracks)
        app.library = library  # ty: ignore[invalid-assignment]
        app.library_page.reset()
        app.library_page.track_list = ft.Column()

        has_tracks = app.library_page._refresh_library_list(update=False)

        self.assertTrue(has_tracks)
        self.assertEqual(library.last_limit, 51)
        self.assertEqual(library.details_requested, 50)
        self.assertEqual(len(app.library_page.track_list.controls), 50)

        app.library_page._library_scrolled(
            cast(
                ft.OnScrollEvent,
                SimpleNamespace(pixels=700, max_scroll_extent=1000),
            )
        )

        self.assertEqual(library.last_limit, 51)
        self.assertEqual(library.last_offset, 50)
        self.assertEqual(library.details_requested, 75)
        self.assertEqual(len(app.library_page.track_list.controls), 75)

    def test_search_submits_background_work_through_app_tasks(self) -> None:
        app = self._app()
        app.tasks = Mock()
        app.tasks.submit.return_value = True
        search = app.search_page
        search.query = ft.TextField(value="focus music")
        search.button = ft.Button("Search")
        search.previous_button = ft.IconButton()
        search.first_button = ft.TextButton("First")
        search.next_button = ft.IconButton()
        search.status = ft.Text()
        search.result_list = ft.Column()
        search.pagination = ft.Row()

        search._start_search()

        app.tasks.submit.assert_called_once()
        self.assertEqual(app.tasks.submit.call_args.kwargs["key"], "search")
        self.assertTrue(app.tasks.submit.call_args.kwargs["replace"])

    def _assert_wrapping_rows_are_flex_safe(self, control: ft.Control) -> None:
        if isinstance(control, ft.Row) and control.wrap:
            for child in control.controls:
                self.assertIsNone(
                    child.expand,
                    f"{type(child).__name__} expands directly inside a wrapping Row",
                )
        children: list[ft.Control] = []
        controls = getattr(control, "controls", None)
        if controls:
            children.extend(controls)
        content = getattr(control, "content", None)
        if isinstance(content, ft.Control):
            children.append(content)
        for child in children:
            self._assert_wrapping_rows_are_flex_safe(child)

    def _contains_control(
        self, control: ft.Control, control_type: type[ft.Control]
    ) -> bool:
        if isinstance(control, control_type):
            return True
        children = list(getattr(control, "controls", None) or [])
        content = getattr(control, "content", None)
        if isinstance(content, ft.Control):
            children.append(content)
        return any(self._contains_control(child, control_type) for child in children)


if __name__ == "__main__":
    unittest.main()
