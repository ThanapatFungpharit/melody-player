from __future__ import annotations

import flet as ft

from musicplayer.ui.components.common import _empty_state, _time_greeting
from musicplayer.ui.mobile.controls import heading, icon_button, scroll_page


def _home_view(app) -> ft.Control:
    track_count, recent, favorites = app.home_page._home_collections()
    sections = [
        heading(_time_greeting(), "Your music, ready when you are."),
        ft.Button(
            "Shuffle your library",
            icon=ft.Icons.SHUFFLE_ROUNDED,
            height=52,
            disabled=not track_count,
            on_click=lambda _: app.home_page._play_library(shuffle=True),
        ),
    ]
    for title, items, message in (
        ("Recently played", recent, "Play a track to start your listening history."),
    ):
        sections.append(heading(title))
        sections.extend(
            [
                app.library_page._library_track_row(track, i)
                for i, track in enumerate(items)
            ]
        )
        if not items:
            sections.append(_empty_state(ft.Icons.MUSIC_NOTE_ROUNDED, message))
    sections.extend(_recommendations(app))
    sections.append(heading("Favorites"))
    sections.extend(
        [
            app.library_page._library_track_row(track, i)
            for i, track in enumerate(favorites)
        ]
    )
    if not favorites:
        sections.append(
            _empty_state(
                ft.Icons.MUSIC_NOTE_ROUNDED,
                "Favorite tracks from their action menu to find them here.",
            )
        )
    return scroll_page(sections)


def _recommendations(app) -> list[ft.Control]:
    home = app.home_page
    controls: list[ft.Control] = [
        heading(
            "Recommended for you",
            "A related mix selected by YouTube Music",
            icon_button(
                ft.Icons.REFRESH_ROUNDED,
                "Refresh recommendations",
                lambda _: home._reload_recommendations(),
            ),
        )
    ]
    if home.recommendations_loading:
        controls.append(
            ft.Container(
                ft.Row(
                    [
                        ft.ProgressRing(width=22, height=22, stroke_width=3),
                        ft.Text("Building your YouTube Music mix…", expand=True),
                    ],
                    spacing=12,
                ),
                padding=16,
            )
        )
    elif home.recommendations_error:
        controls.append(
            _empty_state(ft.Icons.CLOUD_OFF_ROUNDED, home.recommendations_error)
        )
    elif home.recommendations:
        playlists = app.manager.list_playlists()
        controls.extend(
            app.search_page._search_result_row(result, playlists)
            for result in home.recommendations
        )
    else:
        controls.append(
            _empty_state(
                ft.Icons.AUTO_AWESOME_ROUNDED,
                "Play a downloaded YouTube Music track to get recommendations.",
            )
        )
    return controls
