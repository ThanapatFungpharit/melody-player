from __future__ import annotations

import asyncio
import itertools
import threading
import unittest
from types import SimpleNamespace
from typing import cast
from unittest.mock import AsyncMock, Mock, patch
from uuid import UUID

import flet as ft

from musicplayer.app import (
    _STARTUP_QUOTES,
    MusicPlayerApp,
    _apply_startup_appearance,
    _cycle_startup_quotes,
    _next_startup_quote,
    _quote_display_seconds,
    _show_startup_loading,
    main,
)
from musicplayer.application.models import (
    AppSettings,
    DownloadRecord,
    SearchResult,
    TrackDetails,
)
from musicplayer.application.yt_dlp_runtime import YtDlpStatus
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
    def test_startup_loading_fills_safe_area_and_centers_content(self) -> None:
        snapshot: dict[str, object] = {}
        page = SimpleNamespace(controls=[], update=Mock())

        def add(control: ft.Control) -> None:
            snapshot["control"] = control
            snapshot["vertical_alignment"] = page.vertical_alignment
            snapshot["horizontal_alignment"] = page.horizontal_alignment
            page.controls.append(control)

        page.add = add
        services = SimpleNamespace(
            store=SimpleNamespace(settings=AppSettings()), yt_dlp=Mock()
        )
        with (
            patch(
                "musicplayer.app.AppServices.load",
                return_value=services,
            ),
            patch("musicplayer.app.MusicPlayerApp") as app_class,
            patch("musicplayer.app.asyncio.sleep", new_callable=AsyncMock) as sleep,
        ):
            app_class.return_value.backend.reattach_native_state = AsyncMock()
            asyncio.run(main(page))  # ty: ignore[invalid-argument-type]

        delays = [awaited.args[0] for awaited in sleep.await_args_list]
        self.assertEqual(len(delays), 3)
        self.assertGreater(delays[0], 2.5)
        self.assertLessEqual(delays[0], 3.0)
        self.assertEqual(delays[1:], [0.22, 0.05])
        services.yt_dlp.start.assert_called_once_with()

        loading = cast(ft.SafeArea, snapshot["control"])
        self.assertIsInstance(loading, ft.SafeArea)
        self.assertTrue(loading.expand)
        self.assertTrue(loading.avoid_intrusions_top)
        self.assertTrue(loading.avoid_intrusions_bottom)
        self.assertEqual(snapshot["vertical_alignment"], ft.MainAxisAlignment.CENTER)
        self.assertEqual(snapshot["horizontal_alignment"], ft.CrossAxisAlignment.CENTER)
        content = cast(ft.Container, loading.content)
        self.assertIsInstance(content, ft.Container)
        self.assertEqual(content.alignment, ft.Alignment.CENTER)
        self.assertTrue(content.expand)
        layout = cast(ft.Column, content.content)
        self.assertEqual(len(layout.controls), 3)
        self.assertEqual(cast(ft.Container, layout.controls[0]).expand, 1)
        centerpiece = cast(ft.Column, layout.controls[1])
        mark = cast(ft.Stack, centerpiece.controls[0])
        self.assertIsInstance(mark, ft.Stack)
        self.assertEqual(mark.width, 280)
        glow = cast(ft.Container, mark.controls[0])
        self.assertEqual(glow.bgcolor, ft.Colors.PRIMARY_CONTAINER)
        ring = cast(ft.ProgressRing, mark.controls[1])
        self.assertIsInstance(ring, ft.ProgressRing)
        self.assertEqual(ring.color, ft.Colors.PRIMARY)
        lines = cast(ft.Row, mark.controls[2])
        self.assertEqual(len(lines.controls), 4)
        self.assertTrue(
            all(
                cast(ft.Container, bar).bgcolor == ft.Colors.PRIMARY
                for bar in lines.controls
            )
        )
        caption = cast(ft.Column, cast(ft.Container, centerpiece.controls[1]).content)
        self.assertEqual(cast(ft.Text, caption.controls[0]).value, "Melody")
        quote = cast(ft.Container, layout.controls[2])
        self.assertEqual(quote.alignment, ft.Alignment.BOTTOM_CENTER)
        self.assertEqual(quote.expand, 1)
        self.assertIn(cast(ft.Text, quote.content).value, _STARTUP_QUOTES)
        self.assertEqual(page.vertical_alignment, ft.MainAxisAlignment.START)
        self.assertEqual(loading.opacity, 0)
        self.assertIsNone(page.on_resize)

    def test_startup_loading_mark_scales_with_viewport(self) -> None:
        page = SimpleNamespace(
            width=390,
            height=844,
            controls=[],
            update=Mock(),
        )
        page.add = page.controls.append
        loading, _ = _show_startup_loading(page)  # ty: ignore[invalid-argument-type]
        layout = cast(ft.Column, cast(ft.Container, loading.content).content)
        centerpiece = cast(ft.Column, layout.controls[1])
        mark = cast(ft.Stack, centerpiece.controls[0])

        self.assertEqual(mark.width, 172)
        page.on_resize(SimpleNamespace(width=900, height=650))
        self.assertEqual(mark.width, 280)
        self.assertEqual(mark.height, 280)
        page.on_resize(SimpleNamespace(width=320, height=568))
        self.assertEqual(mark.width, 141)
        self.assertEqual(mark.height, 141)
        ring = cast(ft.ProgressRing, mark.controls[1])
        self.assertEqual(ring.width, 141)
        lines = cast(ft.Row, mark.controls[2])
        self.assertEqual(lines.width, round(141 * 0.78))

    def test_startup_quotes_allow_more_time_for_more_words_and_do_not_repeat(
        self,
    ) -> None:
        self.assertGreater(
            _quote_display_seconds("“A longer quote takes more time to read.”"),
            _quote_display_seconds("“Short quote.”"),
        )
        for previous in _STARTUP_QUOTES:
            self.assertNotEqual(_next_startup_quote(previous), previous)

    def test_startup_quotes_stop_updating_after_loading(self) -> None:
        async def run_cycle() -> tuple[list[str], int]:
            updates: list[str] = []
            quote = ft.Text(_STARTUP_QUOTES[0])
            page = SimpleNamespace(update=lambda control: updates.append(control.value))
            stop = asyncio.Event()
            with patch("musicplayer.app._quote_display_seconds", return_value=0.01):
                task = asyncio.create_task(
                    _cycle_startup_quotes(page, quote, stop)  # ty: ignore[invalid-argument-type]
                )
                await asyncio.sleep(0.04)
                stop.set()
                await task
            before = len(updates)
            await asyncio.sleep(0.02)
            return updates, before

        updates, before = asyncio.run(run_cycle())
        self.assertGreaterEqual(before, 1)
        self.assertEqual(len(updates), before)
        self.assertTrue(all(a != b for a, b in itertools.pairwise(updates)))

    def test_startup_opens_immediately_after_load_when_delay_is_disabled(self) -> None:
        page = SimpleNamespace(controls=[], update=Mock())
        page.add = page.controls.append
        services = SimpleNamespace(
            store=SimpleNamespace(settings=AppSettings(skip_loading_delay=True)),
            yt_dlp=Mock(),
        )
        with (
            patch("musicplayer.app.AppServices.load", return_value=services),
            patch("musicplayer.app.MusicPlayerApp") as app_class,
            patch("musicplayer.app.asyncio.sleep", new_callable=AsyncMock) as sleep,
        ):
            reattach = app_class.return_value.backend.reattach_native_state
            reattach.side_effect = AsyncMock()
            asyncio.run(main(page))  # ty: ignore[invalid-argument-type]

        self.assertEqual(
            [awaited.args[0] for awaited in sleep.await_args_list], [0.22, 0.05]
        )
        reattach.assert_called_once_with()

    def test_loading_view_uses_saved_accent_while_library_loads(self) -> None:
        page = SimpleNamespace(controls=[], update=Mock())
        page.add = page.controls.append
        settings = AppSettings(
            accent_color="ocean", theme="dark", skip_loading_delay=True
        )
        services = SimpleNamespace(
            store=SimpleNamespace(settings=settings), yt_dlp=Mock()
        )
        finish_load = threading.Event()

        def load(*, on_settings_loaded):
            on_settings_loaded(settings)
            finish_load.wait(timeout=3)
            return services

        async def check() -> None:
            applied = asyncio.Event()

            def observe_appearance(page, settings) -> None:
                _apply_startup_appearance(page, settings)
                applied.set()

            with (
                patch("musicplayer.app.AppServices.load", side_effect=load),
                patch("musicplayer.app.MusicPlayerApp") as app_class,
                patch(
                    "musicplayer.app._apply_startup_appearance",
                    side_effect=observe_appearance,
                ),
            ):
                reattach = app_class.return_value.backend.reattach_native_state
                reattach.side_effect = AsyncMock()
                task = asyncio.create_task(main(page))  # ty: ignore[invalid-argument-type]
                try:
                    await asyncio.wait_for(applied.wait(), timeout=3)
                    self.assertFalse(task.done())
                    self.assertIsInstance(page.controls[0], ft.SafeArea)
                    self.assertEqual(page.theme_mode, ft.ThemeMode.DARK)
                    self.assertEqual(page.theme.color_scheme_seed, "#0EA5E9")
                finally:
                    finish_load.set()
                    await task
                reattach.assert_called_once_with()

        asyncio.run(check())

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
        app.yt_dlp = Mock(status=Mock(return_value=YtDlpStatus(preparing=True)))
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
                items=["track"],
                upcoming_count=2,
                repeat=SimpleNamespace(value="none"),
                peek_next=lambda **_: "next",
            ),
        )
        app.manager = Mock()
        app.manager.get_track.return_value = SimpleNamespace(
            title="Cached title", filename="cached.mp3"
        )
        app.library = Mock()
        app.library.details.return_value = SimpleNamespace(
            uploader="Artist", thumbnail="artwork", source_name="YouTube", favorite=True
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
        self.assertTrue(
            app.backend.sync_media_session.call_args_list[-1].kwargs["keep_alive"]
        )
        self.assertTrue(
            app.backend.sync_media_session.call_args_list[-1].kwargs["can_repeat"]
        )
        self.assertTrue(
            app.backend.sync_media_session.call_args_list[-1].kwargs["can_shuffle"]
        )
        self.assertTrue(
            app.backend.sync_media_session.call_args_list[-1].kwargs["can_favorite"]
        )
        self.assertTrue(
            app.backend.sync_media_session.call_args_list[-1].kwargs["favorite"]
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
        app.backend.refresh_state.assert_not_called()
        app.backend.invalidate_media_session.assert_not_called()
        app._sync_system_media.assert_called_once_with(refresh_metadata=False)

        app._app_lifecycle_changed(
            cast(
                ft.AppLifecycleStateChangeEvent,
                SimpleNamespace(state=ft.AppLifecycleState.RESUME),
            )
        )

        app.backend.refresh_state.assert_called_once_with()
        app.backend.invalidate_media_session.assert_called_once_with()
        self.assertEqual(app._sync_system_media.call_count, 2)

    def test_settings_uses_responsive_sections_and_fixed_footer(self) -> None:
        app = self._app()

        view = app.settings_page._settings_view()
        header = view.controls[0]  # ty: ignore[unresolved-attribute]
        sections = view.controls[1]  # ty: ignore[unresolved-attribute]
        footer = view.controls[-1]  # ty: ignore[unresolved-attribute]

        self.assertIsInstance(header, ft.Container)
        self.assertIsInstance(header.content, ft.Row)
        self.assertIsNotNone(header.gradient)
        self.assertIsInstance(sections, ft.ResponsiveRow)
        self.assertEqual(sections.columns, 12)
        self.assertEqual(len(sections.controls), 2)
        self.assertEqual(sections.controls[0].col, {"xs": 12, "lg": 5})
        self.assertEqual(sections.controls[1].col, {"xs": 12, "lg": 7})
        self.assertIsInstance(sections.controls[0], ft.Column)
        self.assertIsInstance(sections.controls[1], ft.Column)
        self.assertEqual(len(sections.controls[0].controls), 3)
        self.assertEqual(len(sections.controls[1].controls), 2)
        maintenance_header = sections.controls[0].controls[2].content.controls[0]
        self.assertEqual(
            maintenance_header.controls[1].controls[0].value, "Maintenance"
        )
        youtube_access = sections.controls[0].controls[1]
        youtube_access_header = youtube_access.content.controls[0]
        self.assertEqual(
            youtube_access_header.controls[1].controls[0].value,
            "YouTube Music access",
        )
        self.assertFalse(self._contains_control(youtube_access, ft.Checkbox))
        data_management = sections.controls[1].controls[1]
        reset_everything = data_management.content.controls[-1]
        self.assertEqual(reset_everything.bgcolor, ft.Colors.ERROR_CONTAINER)
        reset_button = reset_everything.content.controls[-1].content
        self.assertEqual(reset_button.bgcolor, ft.Colors.ERROR)
        self.assertTrue(sections.expand)
        self.assertIsInstance(footer, ft.Container)
        self.assertIsInstance(footer.content, ft.ResponsiveRow)
        self.assertEqual(footer.content.columns, 12)
        self.assertEqual(
            footer.content.controls[-1].content.controls[-1].content,
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

    def test_long_lists_build_offscreen_controls_on_demand(self) -> None:
        from musicplayer.ui.mobile.controls import scroll_page
        from musicplayer.ui.mobile.library import _library_view as mobile_library_view

        app = self._app()
        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        app.library = _Library()  # ty: ignore[invalid-assignment]
        app.store = _Store()  # ty: ignore[invalid-assignment]

        desktop_home = app.home_page._home_view()
        app.search_page._search_view()
        app.library_page._library_view()
        desktop_library_list = app.library_page.track_list
        mobile_page = scroll_page([ft.Text("First"), ft.Text("Later")])
        mobile_library_view(app)

        for control in (
            desktop_home,
            app.search_page.result_list,
            desktop_library_list,
            app.library_page.track_list,
            mobile_page,
        ):
            self.assertIsInstance(control, ft.ListView)
            if isinstance(control, ft.ListView):
                self.assertTrue(control.build_controls_on_demand)

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

    def test_library_paging_keeps_rendered_tracks_bounded(self) -> None:
        app = self._app()
        app.manager = _PlaylistManager(())  # ty: ignore[invalid-assignment]
        tracks = tuple(
            Track(UUID(int=index + 1), f"track-{index}.mp3", title=f"Track {index}")
            for index in range(125)
        )
        library = _Library(tracks)
        app.library = library  # ty: ignore[invalid-assignment]
        app.library_page.reset()
        app.library_page.track_list = ft.Column()

        has_tracks = app.library_page._refresh_library_list(update=False)

        self.assertTrue(has_tracks)
        self.assertEqual(library.last_limit, 51)
        self.assertEqual(library.details_requested, 50)
        self.assertEqual(len(app.library_page.track_list.controls), 51)

        app.library_page._change_library_page(1)

        self.assertEqual(library.last_limit, 51)
        self.assertEqual(library.last_offset, 50)
        self.assertEqual(library.details_requested, 100)
        self.assertEqual(len(app.library_page.track_list.controls), 51)

        app.library_page._change_library_page(1)
        self.assertEqual(library.last_offset, 100)
        self.assertEqual(library.details_requested, 125)
        self.assertEqual(len(app.library_page.track_list.controls), 26)

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
