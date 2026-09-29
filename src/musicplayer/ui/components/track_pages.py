"""Keep large track views bounded without changing collection positions."""

from __future__ import annotations

from collections.abc import Callable

import flet as ft

PAGE_SIZE = 50


def page_bounds(total: int, offset: int) -> tuple[int, int]:
    """Return a full page, clamping stale offsets after collection changes."""
    start = min(max(0, offset), max(0, (total - 1) // PAGE_SIZE * PAGE_SIZE))
    return start, min(total, start + PAGE_SIZE)


def page_navigation(
    total: int, start: int, end: int, change: Callable[[int], None]
) -> ft.Control | None:
    if total <= PAGE_SIZE:
        return None
    return ft.Row(
        [
            ft.TextButton(
                "Previous",
                icon=ft.Icons.CHEVRON_LEFT_ROUNDED,
                disabled=start == 0,
                on_click=lambda _: change(-1),
            ),
            ft.Text(
                f"{start + 1}–{end} of {total}",
                expand=True,
                text_align=ft.TextAlign.CENTER,
            ),
            ft.TextButton(
                "Next",
                icon=ft.Icons.CHEVRON_RIGHT_ROUNDED,
                disabled=end >= total,
                on_click=lambda _: change(1),
            ),
        ],
        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
    )
