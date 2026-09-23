from __future__ import annotations

import flet as ft

from musicplayer.core.media import YOUTUBE_MUSIC_NAME
from musicplayer.ui.components.common import _empty_state, _format_duration
from musicplayer.ui.mobile.controls import (
    heading,
    icon_button,
    more,
    scroll_page,
    track_row,
)


def _search_view(app) -> ft.Control:
    app.search_page.query = ft.TextField(
        value=app.search_page.draft,
        hint_text=f"Song, artist or {YOUTUBE_MUSIC_NAME} link",
        on_change=app.search_page._search_draft_changed,
        on_submit=lambda _: app.search_page._start_search(),
        expand=True,
        text_size=14,
    )
    app.search_page.button = icon_button(
        ft.Icons.SEARCH_ROUNDED,
        f"Search {YOUTUBE_MUSIC_NAME}",
        lambda _: app.search_page._start_search(),
    )
    app.search_page.button.disabled = app.search_page.busy
    app.search_page.status = ft.Text(
        f"Search {YOUTUBE_MUSIC_NAME} or paste a playlist link.",
        size=12,
        color=ft.Colors.ON_SURFACE_VARIANT,
    )
    app.search_page.result_list = ft.Column(spacing=8)
    app.search_page.first_button = ft.TextButton(
        "First page", height=48, on_click=lambda _: app.search_page._load_search_page(1)
    )
    app.search_page.previous_button = icon_button(
        ft.Icons.CHEVRON_LEFT_ROUNDED,
        "Previous results",
        lambda _: app.search_page._load_search_page(app.search_page.page_number - 1),
    )
    app.search_page.next_button = icon_button(
        ft.Icons.CHEVRON_RIGHT_ROUNDED,
        "Next results",
        lambda _: app.search_page._load_search_page(app.search_page.page_number + 1),
    )
    app.search_page.page_number_label = ft.Text()
    app.search_page.pagination = ft.Row(
        [
            app.search_page.first_button,
            app.search_page.previous_button,
            app.search_page.page_number_label,
            app.search_page.next_button,
        ],
        alignment=ft.MainAxisAlignment.CENTER,
        spacing=0,
    )
    if app.search_page.results:
        app.search_page._render_search_results(update=False)
    else:
        app.search_page.result_list.controls = [
            _empty_state(
                ft.Icons.SEARCH_ROUNDED,
                "Find a song, then tap it to listen. Use its actions to download or organize it.",
            )
        ]
    app.search_page._update_search_navigation(
        update_status=bool(app.search_page.results)
    )
    return scroll_page(
        [
            heading(
                "Search",
                "",
                more(
                    app,
                    "Search actions",
                    [
                        ft.PopupMenuItem(
                            content="Download multiple links",
                            icon=ft.Icons.DOWNLOAD_ROUNDED,
                            on_click=lambda _: app.search_page._batch_download_dialog(),
                        )
                    ],
                ),
            ),
            ft.Row([app.search_page.query, app.search_page.button], spacing=4),
            app.search_page.status,
            app.search_page.result_list,
            app.search_page.pagination,
        ]
    )


def _search_result_row(app, result, playlists) -> ft.Control:
    title = result.title
    detail = (
        f"{result.entry_count or 'Multiple'} tracks"
        if result.is_playlist
        else _format_duration(result.duration)
    )
    return track_row(
        title,
        f"{result.uploader} · {detail}",
        result.thumbnail,
        lambda _: app.search_page._play_search_result(result),
        more(
            app,
            title,
            app.search_page._search_result_menu(
                result, playlists, include_primary_actions=True
            ),
        ),
        cache=getattr(app, "thumbnails", None),
    )


def _search_results(app) -> list[ft.Control]:
    playlists = app.manager.list_playlists()
    return [
        _search_result_row(app, item, playlists) for item in app.search_page.results
    ]
