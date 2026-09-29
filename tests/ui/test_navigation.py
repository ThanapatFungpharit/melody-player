from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch
from uuid import UUID

import flet as ft

from musicplayer.core.library.models import Playlist, Track
from musicplayer.ui.desktop.player import DesktopPlayer
from musicplayer.ui.mobile.player import MobilePlayer
from musicplayer.ui.presentation import PresentationKind, presentation_kind
from tests.ui_support import TestPage, make_app, walk


class NavigationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.apps = []

    def tearDown(self):
        for app in self.apps:
            app._close(None)
        self.temporary.cleanup()

    def app(
        self,
        *,
        mobile=True,
        width=390,
        height=844,
        populated=True,
        startup_transition=False,
    ):
        page = TestPage(
            width,
            height,
            ft.PagePlatform.ANDROID if mobile else ft.PagePlatform.WINDOWS,
        )
        app = make_app(
            page,
            self.root / str(len(self.apps)),
            mobile=mobile,
            populated=populated,
            startup_transition=startup_transition,
        )
        self.apps.append(app)
        return app

    def test_startup_shells_mount_hidden_for_reveal(self):
        for mobile in (True, False):
            app = self.app(mobile=mobile, startup_transition=True)
            self.assertEqual(app.shell.root.opacity, 0)
            self.assertIsNotNone(app.shell.root.animate_opacity)

    def test_library_returns_to_last_page_after_collection_shrinks(self):
        app = self.app(mobile=False)
        app.library_page._library_view()
        app.library_page._page_offset = 150

        self.assertTrue(app.library_page._refresh_library_list(update=False))
        self.assertEqual(app.library_page._page_offset, 0)

    def test_platform_selection_is_not_a_width_breakpoint(self):
        self.assertEqual(
            presentation_kind(ft.PagePlatform.IOS), PresentationKind.MOBILE
        )
        self.assertEqual(
            presentation_kind(ft.PagePlatform.WINDOWS), PresentationKind.DESKTOP
        )
        self.assertEqual(
            presentation_kind("linux", native_mobile=True), PresentationKind.MOBILE
        )
        app = self.app(mobile=True, width=900, height=390)
        asyncio.run(app._page_resized(SimpleNamespace(width=1200, height=800)))
        self.assertIsInstance(app.player, MobilePlayer)
        desktop = self.app(mobile=False, width=1040)
        asyncio.run(desktop._page_resized(SimpleNamespace(width=720, height=700)))
        self.assertIsInstance(desktop.player, DesktopPlayer)

    def test_browser_disconnect_uses_idempotent_app_shutdown(self):
        app = self.app(mobile=False)

        self.assertEqual(app.page.on_disconnect, app._close)
        app._close(None)
        app._close(None)

        app.backend.close.assert_called_once()

    def test_mobile_navigation_uses_all_edge_safe_areas(self):
        app = self.app()
        controls = list(walk(app.page.views[0]))
        self.assertEqual(sum(isinstance(c, ft.NavigationBar) for c in controls), 1)
        self.assertFalse(
            any(
                isinstance(c, (ft.NavigationRail, ft.NavigationDrawer))
                for c in controls
            )
        )
        safe = next(c for c in controls if isinstance(c, ft.SafeArea))
        for edge in ("left", "top", "right", "bottom"):
            self.assertTrue(getattr(safe, f"avoid_intrusions_{edge}"))
        self.assertTrue(safe.maintain_bottom_view_padding)

        for panel in ("player", "queue", "downloads", "settings"):
            app.shell.open_panel(panel)
            view_controls = list(walk(app.page.views[-1]))
            panel_safe = next(c for c in view_controls if isinstance(c, ft.SafeArea))
            self.assertTrue(panel_safe.avoid_intrusions_top)
            self.assertTrue(panel_safe.avoid_intrusions_bottom)
            self.assertTrue(panel_safe.maintain_bottom_view_padding)
            app.shell.close_panel()

    def test_mobile_settings_keeps_save_actions_outside_scroll(self):
        app = self.app()

        settings = app.settings_page._settings_view()

        self.assertIsInstance(settings, ft.Column)
        self.assertIsInstance(settings.controls[0], ft.ListView)
        self.assertIsInstance(settings.controls[1], ft.Container)
        actions = settings.controls[1].content.controls
        self.assertEqual(
            [button.content for button in actions], ["Cancel", "Save settings"]
        )
        tiles = [
            control
            for control in settings.controls[0].controls
            if isinstance(control, ft.ExpansionTile)
        ]
        self.assertEqual(len(tiles), 4)
        self.assertEqual(tiles[0].title.value, "Appearance")
        self.assertFalse(tiles[0].expanded)

    def test_now_playing_queue_and_native_back_preserve_playback(self):
        app = self.app()
        before = app.playback.queue.to_dict(position_ms=app.playback.position_ms)
        app.shell.open_panel("player")
        app.context_panel._open_queue_panel()
        self.assertEqual(len(app.page.views), 3)
        app.page.on_view_pop(None)
        self.assertEqual(app.active_panel, "player")
        app.page.on_view_pop(None)
        self.assertIsNone(app.active_panel)
        self.assertEqual(
            before, app.playback.queue.to_dict(position_ms=app.playback.position_ms)
        )

    def test_phone_back_returns_from_playlist_and_then_to_home(self):
        app = self.app()
        app.playlists_page._open_playlist(str(app.manager.list_playlists()[0].id))
        event = SimpleNamespace(control=SimpleNamespace(confirm_pop=AsyncMock()))
        asyncio.run(app.shell._confirm_back(event))
        self.assertIsNone(app.playlists_page.selected_playlist_id)
        self.assertEqual(app.selected_navigation, 3)
        asyncio.run(app.shell._confirm_back(event))
        self.assertEqual(app.selected_navigation, 0)

    def test_desktop_queue_docks_and_settings_uses_workspace(self):
        app = self.app(mobile=False, width=1540)
        app.context_panel._open_queue_panel()
        self.assertTrue(app.content.visible)
        self.assertEqual(app.shell.panel.width, 430)
        app.context_panel._open_settings_panel()
        self.assertFalse(app.content.visible)
        self.assertTrue(app.shell.panel.expand)
        app.context_panel._close_context_panel()
        self.assertTrue(app.content.visible)

    def test_search_and_library_drafts_survive_navigation(self):
        for mobile in (True, False):
            app = self.app(mobile=mobile, width=390 if mobile else 1540)
            app.navigation.navigate(1)
            app.search_page.query.value = "Unsubmitted search"
            app.search_page._search_draft_changed(
                SimpleNamespace(control=app.search_page.query)
            )
            app.navigation.navigate(2)
            app.library_page.query.value = "Ocean"
            app.library_page._library_query_changed(
                SimpleNamespace(control=app.library_page.query)
            )
            app.library_page._set_library_sort("title")
            app.navigation.navigate(0)
            app.navigation.navigate(1)
            self.assertEqual(app.search_page.query.value, "Unsubmitted search")
            app.navigation.navigate(2)
            self.assertEqual(app.library_page.query.value, "Ocean")
            self.assertEqual(app.library_page.sort_key, "title")

    def test_desktop_search_shortcut_focuses_composed_search_field(self):
        app = self.app(mobile=False, width=1540)
        app.page.run_task = Mock()

        app.shell.keyboard(SimpleNamespace(key="L", ctrl=True, meta=False))

        self.assertEqual(app.selected_navigation, 1)
        app.page.run_task.assert_called_once_with(app.search_page.query.focus)

    def test_desktop_sidebar_actions_preserve_queue_and_restore_navigation(self):
        app = self.app(mobile=False, width=1540)
        queue = app.playback.queue.to_dict(position_ms=app.playback.position_ms)
        for index, button in enumerate(app.shell.nav_buttons):
            button.on_click(None)
            self.assertEqual(app.selected_navigation, index)
            self.assertIsNone(app.active_panel)
        for name, button in app.shell.utility_buttons.items():
            button.on_click(None)
            self.assertEqual(app.active_panel, name)
            self.assertFalse(app.content.visible)
            app.shell.close_panel()
            self.assertEqual(app.selected_navigation, 3)
            self.assertTrue(app.content.visible)
        app.player.queue_button.on_click(None)
        self.assertEqual(app.active_panel, "queue")
        self.assertTrue(app.content.visible)
        app.shell.nav_buttons[2].on_click(None)
        self.assertEqual(app.selected_navigation, 2)
        self.assertEqual(app.active_panel, "queue")
        self.assertEqual(
            app.playback.queue.to_dict(position_ms=app.playback.position_ms), queue
        )

    def test_desktop_resize_keeps_settings_and_seek_drafts(self):
        app = self.app(mobile=False, width=1540)
        app.shell.utility_buttons["settings"].on_click(None)
        field = app.settings_page.path
        field.value = "An unsaved music folder"
        app.player.seeking = True
        app.player.seek.value = 45000
        for width in (1040, 1540):
            app.page.width = width
            asyncio.run(app._page_resized(SimpleNamespace(width=width, height=700)))
            self.assertIs(app.settings_page.path, field)
            self.assertEqual(field.value, "An unsaved music folder")
            self.assertEqual(app.player.seek.value, 45000)
            self.assertFalse(app.content.visible)
            self.assertEqual(app.shell.nav_labels[0].visible, width == 1540)
        app.shell.nav_buttons[1].on_click(None)
        self.assertEqual(app.selected_navigation, 1)
        self.assertIsNone(app.active_panel)

    def test_desktop_custom_handles_keep_queue_and_playlist_reordering(self):
        app = self.app(mobile=False, width=1540)
        app.context_panel._open_queue_panel()
        queue_view = next(
            c for c in walk(app.shell.panel) if isinstance(c, ft.ReorderableListView)
        )
        before = list(app.playback.queue.items)
        self.assertFalse(queue_view.show_default_drag_handles)
        self.assertTrue(
            all(
                any(isinstance(c, ft.ReorderableDragHandle) for c in walk(row))
                for row in queue_view.controls
            )
        )
        queue_view.on_reorder(SimpleNamespace(old_index=0, new_index=2))
        self.assertEqual(app.playback.queue.items, [before[1], before[0], before[2]])
        app.shell.close_panel()
        playlist = app.manager.list_playlists()[0]
        before = list(playlist.track_ids)
        app.playlists_page._open_playlist(str(playlist.id))
        playlist_view = next(
            c for c in walk(app.content) if isinstance(c, ft.ReorderableListView)
        )
        self.assertFalse(playlist_view.show_default_drag_handles)
        self.assertTrue(
            all(
                any(isinstance(c, ft.ReorderableDragHandle) for c in walk(row))
                for row in playlist_view.controls
            )
        )
        rendered_before = list(playlist_view.controls)
        playlist_view.on_reorder(
            SimpleNamespace(old_index=0, new_index=2, control=playlist_view)
        )
        self.assertEqual(
            playlist_view.controls,
            [rendered_before[1], rendered_before[0], rendered_before[2]],
        )
        self.assertEqual(
            list(app.manager.get_playlist(playlist.id).track_ids),
            [before[1], before[0], before[2]],
        )

    def test_large_queue_renders_only_current_page_with_absolute_actions(self):
        app = self.app(mobile=False, width=1540)
        ids = [str(track.id) for track in app.manager.list_tracks()]
        app.playback.queue.items = [ids[index % len(ids)] for index in range(125)]
        app.playback.queue.current_index = 65
        with patch.object(app.library, "details", wraps=app.library.details) as details:
            view = app.queue_page._queue_view()
        rows = next(c for c in walk(view) if isinstance(c, ft.ReorderableListView))
        self.assertEqual(len(rows.controls), 50)
        self.assertEqual(details.call_count, 50)
        self.assertTrue(rows.controls[15].key.startswith("queue:65:"))
        with patch.object(app.playback, "reorder_queue") as reorder:
            rows.on_reorder(SimpleNamespace(old_index=0, new_index=2))
        reorder.assert_called_once_with(50, 52)

    def test_large_playlist_renders_one_page_and_reorders_absolute_positions(self):
        app = self.app(mobile=False, width=1540)
        playlist = app.manager.list_playlists()[0]
        tracks = tuple(
            Track(UUID(int=index + 1), f"track-{index}.mp3", title=f"Track {index}")
            for index in range(125)
        )
        large_playlist = Playlist(playlist.id, playlist.name, [t.id for t in tracks])
        app.playlists_page._page_offset = 50
        requested_ids: list[str] = []
        details_many = app.library.details_many

        def collect_details(track_ids):
            batch = tuple(track_ids)
            requested_ids.extend(str(track_id) for track_id in batch)
            return details_many(batch)

        with (
            patch.object(app.manager, "playlist_tracks", return_value=tracks),
            patch.object(app.library, "details_many", side_effect=collect_details),
        ):
            view = app.playlists_page._playlist_detail(large_playlist)
        rows = next(c for c in walk(view) if isinstance(c, ft.ReorderableListView))
        self.assertEqual(len(rows.controls), 50)
        self.assertEqual(len(requested_ids), 50)
        with patch.object(app.playlists_page, "_reorder_playlist") as reorder:
            app.playlists_page._playlist_reordered(
                str(playlist.id),
                SimpleNamespace(old_index=0, new_index=2, control=rows),
            )
        reorder.assert_called_once_with(str(playlist.id), 50, 52)

    def test_bulk_add_dialog_keeps_selection_across_bounded_pages(self):
        app = self.app(mobile=True)
        tracks = tuple(
            Track(UUID(int=index + 1), f"track-{index}.mp3", title=f"Track {index}")
            for index in range(125)
        )
        playlist = Playlist(UUID(int=1000), "New playlist")
        with patch.object(app.manager, "list_tracks", return_value=tracks):
            app.playlists_page._bulk_add_tracks_dialog(playlist)
        dialog = app.page.dialogs[-1]
        checkboxes = [c for c in walk(dialog) if isinstance(c, ft.Checkbox)]
        self.assertEqual(len(checkboxes), 51)
        first_track = checkboxes[1]
        first_track.value = True
        first_track.on_change(SimpleNamespace(control=first_track))
        next_button = next(
            c
            for c in walk(dialog)
            if isinstance(c, ft.TextButton) and c.content == "Next"
        )
        next_button.on_click(None)
        checkboxes = [c for c in walk(dialog) if isinstance(c, ft.Checkbox)]
        self.assertEqual(len(checkboxes), 51)
        self.assertIn(
            "1 track selected",
            [c.value for c in walk(dialog) if isinstance(c, ft.Text)],
        )
        previous_button = next(
            c
            for c in walk(dialog)
            if isinstance(c, ft.TextButton) and c.content == "Previous"
        )
        previous_button.on_click(None)
        checkboxes = [c for c in walk(dialog) if isinstance(c, ft.Checkbox)]
        self.assertTrue(checkboxes[1].value)

    def test_orientation_keeps_settings_draft_and_cookie_selection(self):
        app = self.app()
        app.context_panel._open_settings_panel()
        field = app.settings_page.theme
        field.value = "light"
        app.settings_page.pending_cookie_name = "cookies.txt"
        asyncio.run(app._page_resized(SimpleNamespace(width=844, height=390)))
        self.assertIs(app.settings_page.theme, field)
        self.assertEqual(field.value, "light")
        self.assertEqual(app.settings_page.pending_cookie_name, "cookies.txt")

    def test_live_notification_focal_setting_saves_both_modes(self):
        app = self.app()
        app.context_panel._open_settings_panel()
        switch = app.settings_page.auto_focal_point_live_notifications
        self.assertFalse(switch.value)
        switch.value = True
        asyncio.run(app.settings_page._save_settings.__wrapped__(app.settings_page))
        self.assertTrue(app.store.settings.auto_focal_point_live_notifications)
        switch.value = False
        asyncio.run(app.settings_page._save_settings.__wrapped__(app.settings_page))
        self.assertFalse(app.store.settings.auto_focal_point_live_notifications)

    def test_startup_loading_delay_setting_saves_both_modes(self):
        app = self.app()
        app.context_panel._open_settings_panel()
        switch = app.settings_page.skip_loading_delay
        self.assertFalse(switch.value)
        switch.value = True
        asyncio.run(app.settings_page._save_settings.__wrapped__(app.settings_page))
        self.assertTrue(app.store.settings.skip_loading_delay)
        switch.value = False
        asyncio.run(app.settings_page._save_settings.__wrapped__(app.settings_page))
        self.assertFalse(app.store.settings.skip_loading_delay)

    def test_now_playing_artwork_uses_available_phone_space(self):
        app = self.app()
        app.shell.open_panel("player")
        self.assertEqual(app.player.art.width, 326)
        self.assertEqual(app.player.art.height, 326)

        asyncio.run(app._page_resized(SimpleNamespace(width=844, height=390)))
        self.assertEqual(app.player.art.width, 176)
        self.assertEqual(app.player.art.height, 176)

        asyncio.run(app._page_resized(SimpleNamespace(width=390, height=844)))
        self.assertEqual(app.player.art.width, 326)
        self.assertEqual(app.player.art.height, 326)

    def test_mobile_player_actions_share_playback_state_without_volume_slider(self):
        app = self.app()
        app.shell.open_panel("player")
        player = app.player
        desktop = DesktopPlayer(app)
        player.shuffle.on_click(None)
        player.repeat.on_click(None)
        player.mute.on_click(None)
        desktop.refresh()
        self.assertEqual(player.shuffle.icon_color, desktop.shuffle.icon_color)
        self.assertEqual(player.repeat.tooltip, desktop.repeat.tooltip)
        self.assertEqual(player.mute.icon, desktop.mute.icon)
        self.assertEqual(
            sum(isinstance(c, ft.Slider) for c in walk(player.full_player)), 1
        )
        self.assertEqual(sum(isinstance(c, ft.Slider) for c in walk(desktop.root)), 2)
        player.shuffle.on_click(None)
        original_ids = list(app.playback.queue.items)
        player.next.on_click(None)
        self.assertEqual(app.playback.current_track_id, original_ids[1])
        player.previous.on_click(None)
        self.assertEqual(app.playback.current_track_id, original_ids[0])

    def test_main_player_shuffle_button_is_a_repeatable_action(self):
        app = self.app()
        player = app.player
        original = list(app.playback.queue.items)

        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ) as shuffle:
            player.shuffle.on_click(None)
            self.assertEqual(
                app.playback.queue.items, [original[0], *reversed(original[1:])]
            )
            self.assertEqual(player.shuffle.tooltip, "Shuffle upcoming tracks")
            self.assertIsNone(player.shuffle.icon_color)
            player.shuffle.on_click(None)

        self.assertEqual(app.playback.queue.items, original)
        self.assertEqual(player.shuffle.tooltip, "Shuffle upcoming tracks")
        self.assertIsNone(player.shuffle.icon_color)
        self.assertEqual(shuffle.call_count, 2)

    def test_stop_is_available_in_player_and_keeps_app_open(self):
        app = self.app()
        app.shell.open_panel("player")
        player = app.player
        desktop = DesktopPlayer(app)

        self.assertIn(player.stop, list(walk(player.full_player)))
        self.assertIn(desktop.stop, list(walk(desktop.root)))
        app.playback.toggle()
        self.assertTrue(app.playback.media_session_active)

        player.stop.on_click(None)

        self.assertFalse(app.playback.media_session_active)
        self.assertFalse(app._closing)
        player.refresh()
        self.assertTrue(player.stop.disabled)

    def test_favoriting_current_track_refreshes_media_notification(self):
        app = self.app()
        app.playback.toggle()
        track_id = app.playback.current_track_id
        assert track_id is not None
        before = app.library.details(track_id).favorite

        with patch.object(app, "_sync_system_media") as sync_media:
            asyncio.run(
                app.library_page._toggle_favorite.__wrapped__(
                    app.library_page, track_id
                )
            )

        self.assertNotEqual(app.library.details(track_id).favorite, before)
        sync_media.assert_called_once_with(refresh_metadata=True)

    def test_collection_shuffle_reorders_visible_queue_once(self):
        app = self.app()
        tracks = app.manager.list_tracks()
        ordered_ids = [str(track.id) for track in tracks]

        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ):
            app.shared._shuffle_collection(tracks)

        self.assertEqual(app.playback.queue.items, list(reversed(ordered_ids)))
        self.assertEqual(app.playback.current_track_id, ordered_ids[-1])
        self.assertNotIn("shuffle", app.playback.queue.to_dict())

    def test_progress_does_not_replace_screen_or_override_a_seek_drag(self):
        app = self.app()
        app.shell.open_panel("player")
        app.playback.duration_ms = 180000
        app.player.seek.value = 60000
        app.player.seeking = True
        view = app.page.views[-1]
        app.playback.on_position(3000)
        self.assertEqual(app.player.seek.value, 60000)
        self.assertIs(app.page.views[-1], view)
        self.assertNotIn(app.content, app.page.updated[-1])
        app.player._seek_end(SimpleNamespace(control=SimpleNamespace(value=60000)))
        self.assertEqual(app.playback.position_ms, 60000)

    def test_player_updates_only_changed_controls(self):
        app = self.app(mobile=False)
        artwork = app.player.art.content
        app.page.updated.clear()

        app.player_bar._refresh_player()
        self.assertEqual(app.page.updated, [])
        self.assertIs(app.player.art.content, artwork)

        app.playback.duration_ms = 10000
        app.playback.position_ms = 1000
        app.player_bar._refresh_player_progress()
        app.page.updated.clear()
        app.playback.position_ms = 1200
        app.player_bar._refresh_player_progress()
        self.assertEqual(app.page.updated[-1], (app.player.seek,))

    def test_download_badge_updates_without_patching_content(self):
        for mobile in (True, False):
            app = self.app(mobile=mobile)
            app.page.updated.clear()
            app.shell.refresh_downloads()
            self.assertEqual(app.page.updated, [])
            app.downloads.active_count = Mock(return_value=2)
            app.shell.refresh_downloads()
            self.assertNotIn(app.content, app.page.updated[-1])
            self.assertTrue(app.page.updated[-1])

    def test_recommendation_page_updates_only_its_section(self):
        for mobile in (True, False):
            app = self.app(mobile=mobile)
            section = app.home_page._recommendation_section
            home_view = app.content.content
            self.assertIsNotNone(section)
            app.page.updated.clear()

            app.home_page._change_recommendation_page(1)

            self.assertIs(app.content.content, home_view)
            self.assertEqual(app.page.updated, [(section,)])

    def test_mobile_actions_close_sheet_then_reorder_or_await_file_picker(self):
        from musicplayer.ui.mobile.controls import action_sheet

        app = self.app()
        queue = list(app.playback.queue.items)
        action_sheet(
            app,
            "Track",
            [
                ft.PopupMenuItem(
                    content="Move down",
                    on_click=lambda _: app.playback.reorder_queue(0, 2),
                )
            ],
        )
        sheet = app.page.dialogs[-1]
        self.assertTrue(sheet.use_safe_area)
        self.assertTrue(sheet.scrollable)
        self.assertTrue(sheet.maintain_bottom_view_insets_padding)
        tile = next(c for c in walk(app.page.dialogs[-1]) if isinstance(c, ft.ListTile))
        asyncio.run(tile.on_click(None))
        self.assertFalse(app.page.dialogs)
        self.assertEqual(app.playback.queue.items, [queue[1], queue[0], queue[2]])
        pick = AsyncMock()
        action_sheet(
            app, "Library", [ft.PopupMenuItem(content="Add files", on_click=pick)]
        )
        tile = next(c for c in walk(app.page.dialogs[-1]) if isinstance(c, ft.ListTile))
        asyncio.run(tile.on_click(None))
        pick.assert_awaited_once()

    def test_mobile_search_ignores_desktop_grid_preference(self):
        app = self.app()
        app.search_page.view_mode = "grid"
        app.navigation.navigate(1)
        self.assertEqual(len(app.search_page.result_list.controls), 1)
        self.assertFalse(
            any(
                isinstance(c, ft.PopupMenuButton)
                for c in walk(app.search_page.result_list)
            )
        )

    def test_all_screens_build_for_phone_orientations_and_desktop(self):
        for mobile, width, height in (
            (True, 320, 568),
            (True, 390, 844),
            (True, 844, 390),
            (False, 1040, 700),
            (False, 1540, 960),
        ):
            for populated in (False, True):
                with self.subTest(mobile=mobile, width=width, populated=populated):
                    app = self.app(
                        mobile=mobile, width=width, height=height, populated=populated
                    )
                    for index in range(4):
                        app.navigation.navigate(index)
                        controls = list(walk(app.content.content))
                        if mobile:
                            self.assertFalse(
                                any(
                                    isinstance(
                                        c, (ft.PopupMenuButton, ft.ReorderableListView)
                                    )
                                    for c in controls
                                )
                            )
                            for c in controls:
                                if isinstance(c, ft.IconButton):
                                    self.assertGreaterEqual(c.width or 0, 48)
                                    self.assertGreaterEqual(c.height or 0, 48)
                    for panel in ("queue", "downloads", "settings"):
                        app.shell.open_panel(panel)
                        app.context_panel._close_context_panel()


if __name__ == "__main__":
    unittest.main()
