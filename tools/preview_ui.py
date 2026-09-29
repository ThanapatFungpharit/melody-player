"""Render isolated presentation fixtures: python tools/preview_ui.py --mobile.

Shows the three-second startup screen first unless --skip-loading-wait is set.
Uses a temporary library and a silent backend; never opens the user's data.
"""

import argparse
import asyncio
import sys
import tempfile
from pathlib import Path

import flet as ft

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from musicplayer.app import (
    _MINIMUM_LOADING_SECONDS,
    _apply_startup_appearance,
    _cycle_startup_quotes,
    _fade_out_startup_loading,
    _reveal_startup_app,
    _show_startup_loading,
    _stop_startup_quotes,
)
from musicplayer.application.models import AppSettings
from musicplayer.ui.theme import palette_names
from tests.ui_support import make_app


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mobile", action="store_true")
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument(
        "--theme", choices=("light", "dark", "system"), default="system"
    )
    parser.add_argument("--accent", choices=palette_names(), default="violet")
    parser.add_argument("--empty", action="store_true")
    parser.add_argument("--skip-loading-wait", action="store_true")
    parser.add_argument(
        "--screen",
        choices=(
            "loading",
            "home",
            "search",
            "library",
            "playlists",
            "playlist",
            "queue",
            "downloads",
            "settings",
            "player",
        ),
        default="home",
    )
    return parser


async def preview(page: ft.Page, args: argparse.Namespace) -> None:
    temporary = tempfile.TemporaryDirectory(prefix="melody-ui-preview-")
    _apply_startup_appearance(
        page, AppSettings(theme=args.theme, accent_color=args.accent)
    )
    page.window.min_width = 0
    page.window.min_height = 0
    page.window.width = args.width or (390 if args.mobile else 1540)
    page.window.height = args.height or (844 if args.mobile else 960)
    page.title = "Melody — Loading library"
    loading, quote = _show_startup_loading(
        page,
        viewport_width=page.window.width,
        viewport_height=page.window.height,
    )
    quote_stop = asyncio.Event()
    quote_task = asyncio.create_task(_cycle_startup_quotes(page, quote, quote_stop))
    if args.screen == "loading":
        page.on_close = lambda _: (quote_stop.set(), temporary.cleanup())
        return
    if not args.skip_loading_wait:
        await asyncio.sleep(_MINIMUM_LOADING_SECONDS)
    await _stop_startup_quotes(quote_stop, quote_task)
    await _fade_out_startup_loading(page, loading)
    page.on_resize = None
    page.controls.clear()
    page.vertical_alignment = ft.MainAxisAlignment.START
    page.horizontal_alignment = ft.CrossAxisAlignment.START
    app = make_app(
        page,
        Path(temporary.name),
        mobile=args.mobile,
        populated=not args.empty,
        startup_transition=True,
        theme=args.theme,
        accent=args.accent,
    )
    page.theme_mode = ft.ThemeMode(args.theme)
    page.title = f"Melody UI Preview — {args.screen}"
    if args.screen in ("home", "search", "library", "playlists"):
        app.navigation.navigate(
            ("home", "search", "library", "playlists").index(args.screen)
        )
    elif args.screen == "playlist":
        playlists = app.manager.list_playlists()
        if playlists:
            app.playlists_page._open_playlist(str(playlists[0].id))
        else:
            app.navigation.navigate(3)
    else:
        app.shell.open_panel(args.screen)
    page.on_close = lambda _: (app._close(None), temporary.cleanup())
    page.update()
    await _reveal_startup_app(page, app)


if __name__ == "__main__":
    options = _parser().parse_args()

    async def main(page: ft.Page) -> None:
        await preview(page, options)

    ft.run(main)
