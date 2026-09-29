from __future__ import annotations

import flet as ft

from musicplayer.ui.components.common import _track_credit, _track_title
from musicplayer.ui.mobile.controls import (
    heading,
    icon_button,
    more,
    track_row,
)


def _library_view(app) -> ft.Control:
    app.library_page.mode = "tracks"
    app.library_page.query = ft.TextField(
        value=app.library_page.query_text,
        hint_text="Find in your library",
        prefix_icon=ft.Icons.SEARCH_ROUNDED,
        on_change=app.library_page._library_query_changed,
        expand=True,
    )
    app.library_page.track_list = ft.ListView(
        spacing=6, build_controls_on_demand=True, cache_extent=300, expand=True
    )
    has_visible_tracks = app.library_page._refresh_library_list(update=False)
    actions = [
        ft.PopupMenuItem(
            content="Add local audio files",
            icon=ft.Icons.LIBRARY_ADD_ROUNDED,
            on_click=app.library_page._pick_local_files,
        ),
        ft.PopupMenuItem(
            content="Add these tracks to queue",
            icon=ft.Icons.ADD_TO_QUEUE_ROUNDED,
            disabled=not has_visible_tracks,
            on_click=lambda _: app.library_page._queue_visible_library(),
        ),
        ft.PopupMenuItem(
            content="Export library playlist",
            icon=ft.Icons.IOS_SHARE_ROUNDED,
            disabled=app.manager.counts()[0] == 0,
            on_click=app.library_page._export_library,
        ),
    ]
    sort_actions = [
        ft.PopupMenuItem(
            content=label,
            on_click=lambda _, value=key: app.library_page._set_library_sort(value),
        )
        for key, label in (
            ("recent", "Recently added"),
            ("oldest", "Oldest first"),
            ("title", "Title"),
        )
    ]
    shuffle_button = icon_button(
        ft.Icons.SHUFFLE_ROUNDED,
        "Shuffle visible tracks",
        lambda _: app.library_page._shuffle_visible_library(),
    )
    shuffle_button.disabled = not has_visible_tracks
    return ft.Column(
        [
            heading(
                "Library",
                "Music saved on this device",
                more(app, "Library actions", actions),
            ),
            ft.Row(
                [app.library_page.query, more(app, "Sort tracks", sort_actions)],
                spacing=4,
            ),
            ft.Row(
                [
                    ft.Button(
                        "Play all",
                        icon=ft.Icons.PLAY_ARROW_ROUNDED,
                        height=48,
                        expand=True,
                        disabled=not has_visible_tracks,
                        on_click=lambda _: app.library_page._play_visible_library(),
                    ),
                    shuffle_button,
                ]
            ),
            app.library_page.track_list,
        ],
        spacing=14,
        expand=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )


def _library_track_row(app, track, index, playlists=None, details=None) -> ft.Control:
    details = details or app.library.details(track.id)
    title = _track_title(track)
    return track_row(
        title,
        _track_credit(details),
        details.thumbnail,
        lambda _: app.playback.play_track(str(track.id)),
        more(
            app,
            title,
            app.library_page._library_track_menu(track, index, playlists, details),
        ),
        cache=getattr(app, "thumbnails", None),
    )
