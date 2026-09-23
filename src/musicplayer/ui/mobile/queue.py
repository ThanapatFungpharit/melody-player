from __future__ import annotations

import flet as ft

from musicplayer.ui.components.common import _empty_state, _track_title
from musicplayer.ui.components.queue_status import (
    queue_item_status,
    queue_mode_status,
)
from musicplayer.ui.mobile.controls import (
    heading,
    icon_button,
    more,
    scroll_page,
    track_row,
)


def _queue_view(app) -> ft.Control:
    queue = app.playback.queue
    mode = queue_mode_status(queue)
    rows = []
    for index, track_id in enumerate(queue.items):
        try:
            track = app.manager.get_track(track_id)
            details = app.library.details(track_id)
        except KeyError, TypeError, ValueError:
            continue
        current = index == queue.current_index
        item_status = queue_item_status(queue, index)
        actions = [
            ft.PopupMenuItem(
                content="Move up",
                icon=ft.Icons.ARROW_UPWARD_ROUNDED,
                disabled=index == 0,
                on_click=lambda _, i=index: app.playback.reorder_queue(i, i - 1),
            ),
            ft.PopupMenuItem(
                content="Move down",
                icon=ft.Icons.ARROW_DOWNWARD_ROUNDED,
                disabled=index == len(queue.items) - 1,
                on_click=lambda _, i=index: app.playback.reorder_queue(i, i + 2),
            ),
            ft.PopupMenuItem(
                content="Remove from queue",
                icon=ft.Icons.REMOVE_CIRCLE_OUTLINE_ROUNDED,
                on_click=lambda _, i=index: app.playback.remove_queue_item(i),
            ),
        ]
        rows.append(
            track_row(
                _track_title(track),
                f"{item_status} · {details.uploader or 'Queued track'}",
                details.thumbnail,
                lambda _, i=index: app.playback.play_queue_index(i),
                more(app, _track_title(track), actions),
                selected=current,
                cache=getattr(app, "thumbnails", None),
            )
        )
    return scroll_page(
        [
            heading(
                "Queue",
                f"{len(rows)} tracks · {mode.label}",
                icon_button(
                    ft.Icons.ARROW_BACK_ROUNDED,
                    "Back",
                    lambda _: app.context_panel._close_context_panel(),
                ),
            ),
            ft.Container(
                ft.Row(
                    [
                        ft.Icon(mode.icon, color=ft.Colors.PRIMARY, size=22),
                        ft.Column(
                            [
                                ft.Text(mode.label, weight=ft.FontWeight.BOLD),
                                ft.Text(
                                    mode.description,
                                    size=12,
                                    color=ft.Colors.ON_SURFACE_VARIANT,
                                ),
                            ],
                            spacing=2,
                            expand=True,
                        ),
                    ],
                    spacing=12,
                    vertical_alignment=ft.CrossAxisAlignment.START,
                ),
                padding=14,
                border_radius=14,
                bgcolor=ft.Colors.SURFACE_CONTAINER_LOW,
                visible=bool(rows),
            ),
            ft.Row(
                [
                    ft.TextButton(
                        "Shuffle on" if queue.shuffle else "Shuffle off",
                        icon=ft.Icons.SHUFFLE_ROUNDED,
                        on_click=lambda _: app.playback.toggle_shuffle(),
                    ),
                    ft.TextButton(
                        mode.label,
                        icon=mode.icon,
                        on_click=lambda _: app.playback.cycle_repeat(),
                    ),
                    ft.TextButton(
                        "Clear upcoming",
                        icon=ft.Icons.CLEAR_ALL_ROUNDED,
                        disabled=len(queue.items) <= 1,
                        on_click=lambda _: app.playback.clear_queue(),
                    ),
                ],
                wrap=True,
                visible=bool(rows),
            ),
            *rows,
            *(
                []
                if rows
                else [
                    _empty_state(
                        ft.Icons.QUEUE_MUSIC_ROUNDED,
                        "Play music or add tracks to start your queue.",
                    )
                ]
            ),
        ]
    )
