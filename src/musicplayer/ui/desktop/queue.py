from __future__ import annotations

from typing import TYPE_CHECKING

import flet as ft

from musicplayer.ui.components.common import (
    _artwork,
    _empty_state,
    _track_credit,
    _track_title,
)
from musicplayer.ui.components.queue_status import (
    queue_item_status,
    queue_mode_status,
)
from musicplayer.ui.components.track_pages import page_navigation
from musicplayer.ui.desktop.controls import reorder_handle

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


def _queue_view(app: MusicPlayerApp) -> ft.Control:
    queue = app.playback.queue
    mode = queue_mode_status(queue)
    start, end = app.queue_page._visible_range(len(queue.items), queue.current_index)
    queue_rows: list[ft.Control] = []
    for index in range(start, end):
        track_id = queue.items[index]
        try:
            track = app.manager.get_track(track_id)
        except KeyError, TypeError, ValueError:
            continue
        details = app.library.details(track_id)
        current = index == queue.current_index
        item_status = queue_item_status(queue, index)
        next_up = item_status.startswith("Up next")
        queue_rows.append(
            ft.Container(
                ft.Row(
                    [
                        reorder_handle(current=current),
                        _artwork(
                            details.thumbnail,
                            48,
                            cache=getattr(app, "thumbnails", None),
                        ),
                        ft.Column(
                            [
                                ft.Text(
                                    _track_title(track),
                                    weight=ft.FontWeight.BOLD
                                    if current
                                    else ft.FontWeight.W_500,
                                    max_lines=1,
                                    overflow=ft.TextOverflow.ELLIPSIS,
                                    size=14,
                                ),
                                ft.Text(
                                    _track_credit(details),
                                    max_lines=1,
                                    overflow=ft.TextOverflow.ELLIPSIS,
                                    size=12,
                                    color=ft.Colors.ON_SURFACE_VARIANT,
                                ),
                                ft.Text(
                                    item_status,
                                    size=11,
                                    weight=ft.FontWeight.W_600
                                    if current or next_up
                                    else ft.FontWeight.W_400,
                                    color=ft.Colors.PRIMARY
                                    if current or next_up
                                    else ft.Colors.ON_SURFACE_VARIANT,
                                ),
                            ],
                            spacing=3,
                            expand=True,
                        ),
                        ft.IconButton(
                            ft.Icons.PLAY_ARROW_ROUNDED,
                            tooltip="Play from here",
                            on_click=lambda _, pos=index: app.playback.play_queue_index(
                                pos
                            ),
                        ),
                        ft.PopupMenuButton(
                            icon=ft.Icons.MORE_HORIZ_ROUNDED,
                            items=[
                                ft.PopupMenuItem(
                                    content="Move up",
                                    icon=ft.Icons.ARROW_UPWARD_ROUNDED,
                                    disabled=index == 0,
                                    on_click=lambda _, pos=index: (
                                        app.playback.reorder_queue(pos, pos - 1)
                                    ),
                                ),
                                ft.PopupMenuItem(
                                    content="Move down",
                                    icon=ft.Icons.ARROW_DOWNWARD_ROUNDED,
                                    disabled=index == len(queue.items) - 1,
                                    on_click=lambda _, pos=index: (
                                        app.playback.reorder_queue(pos, pos + 2)
                                    ),
                                ),
                                ft.PopupMenuItem(
                                    content="Remove from queue",
                                    icon=ft.Icons.REMOVE_CIRCLE_OUTLINE_ROUNDED,
                                    on_click=lambda _, pos=index: (
                                        app.playback.remove_queue_item(pos)
                                    ),
                                ),
                            ],
                        ),
                    ]
                ),
                padding=10,
                margin=ft.Margin.only(bottom=6),
                border_radius=14,
                bgcolor=ft.Colors.PRIMARY_CONTAINER
                if current
                else ft.Colors.SURFACE_CONTAINER_LOW,
                key=f"queue:{index}:{track_id}",
            )
        )
    if queue_rows:
        rows: ft.Control = ft.ReorderableListView(
            controls=queue_rows,
            show_default_drag_handles=False,
            mouse_cursor=ft.MouseCursor.GRAB,
            on_reorder=lambda event: app.playback.reorder_queue(
                start + event.old_index, start + event.new_index
            ),
            expand=True,
        )
    else:
        rows = _empty_state(
            ft.Icons.QUEUE_MUSIC_ROUNDED,
            "Your temporary playback queue is empty.",
            expand=True,
        )
    pager = page_navigation(len(queue.items), start, end, app.queue_page._change_page)
    return ft.Column(
        [
            app.shared._context_header(
                "Queue", f"{len(queue.items)} tracks · {mode.label}"
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
                visible=bool(queue_rows),
            ),
            ft.Row(
                [
                    ft.TextButton(
                        "Shuffle upcoming",
                        icon=ft.Icons.SHUFFLE_ROUNDED,
                        disabled=app.playback.queue.upcoming_count < 2,
                        on_click=lambda _: app.playback.shuffle_upcoming(),
                    ),
                    ft.TextButton(
                        mode.label,
                        icon=mode.icon,
                        on_click=lambda _: app.playback.cycle_repeat(),
                    ),
                    ft.TextButton(
                        "Clear upcoming",
                        icon=ft.Icons.CLEAR_ALL_ROUNDED,
                        on_click=lambda _: app.playback.clear_queue(),
                        disabled=len(queue.items) <= 1,
                    ),
                ],
                wrap=True,
                visible=bool(queue_rows),
            ),
            rows,
            *([pager] if pager is not None else []),
        ],
        spacing=16,
        expand=True,
    )
