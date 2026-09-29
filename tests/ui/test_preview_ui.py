from __future__ import annotations

import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import flet as ft

from tools.preview_ui import _parser, preview


class PreviewTests(unittest.TestCase):
    @staticmethod
    def _page() -> SimpleNamespace:
        page = SimpleNamespace(
            controls=[],
            window=SimpleNamespace(),
            update=Mock(),
        )
        page.add = page.controls.append
        return page

    def test_preview_shows_loading_before_building_demo(self) -> None:
        page = self._page()
        app = SimpleNamespace(
            navigation=SimpleNamespace(navigate=Mock()),
            shell=SimpleNamespace(root=ft.Container(opacity=0)),
            _close=Mock(),
        )
        options = _parser().parse_args(["--mobile"])
        delays: list[float] = []

        async def observe_loading(seconds: float) -> None:
            delays.append(seconds)
            if len(delays) == 1:
                self.assertEqual(seconds, 3.0)
                self.assertEqual(make_app.call_count, 0)
                self.assertIsInstance(page.controls[0], ft.SafeArea)

        with (
            patch("tools.preview_ui.make_app", return_value=app) as make_app,
            patch(
                "tools.preview_ui.asyncio.sleep",
                new_callable=AsyncMock,
                side_effect=observe_loading,
            ),
        ):
            asyncio.run(preview(page, options))  # ty: ignore[invalid-argument-type]

        make_app.assert_called_once()
        self.assertTrue(make_app.call_args.kwargs["startup_transition"])
        self.assertEqual(delays, [3.0, 0.22, 0.05])
        self.assertEqual(app.shell.root.opacity, 1)
        app.navigation.navigate.assert_called_once_with(0)
        page.on_close(None)

    def test_loading_screen_can_stay_open_for_inspection(self) -> None:
        page = self._page()
        options = _parser().parse_args(
            ["--mobile", "--screen", "loading", "--accent", "ocean"]
        )

        with (
            patch("tools.preview_ui.make_app") as make_app,
            patch("tools.preview_ui.asyncio.sleep", new_callable=AsyncMock) as sleep,
        ):
            asyncio.run(preview(page, options))  # ty: ignore[invalid-argument-type]

        self.assertIsInstance(page.controls[0], ft.SafeArea)
        mark = page.controls[0].content.content.controls[1].controls[0]
        self.assertIsInstance(mark, ft.Stack)
        self.assertEqual(mark.width, 172)
        self.assertEqual(page.theme.color_scheme_seed, "#0EA5E9")
        make_app.assert_not_called()
        sleep.assert_not_awaited()
        page.on_close(None)

    def test_preview_can_skip_minimum_loading_wait(self) -> None:
        page = self._page()
        options = _parser().parse_args(["--mobile", "--skip-loading-wait"])
        app = SimpleNamespace(
            navigation=SimpleNamespace(navigate=Mock()),
            shell=SimpleNamespace(root=ft.Container(opacity=0)),
            _close=Mock(),
        )
        with (
            patch("tools.preview_ui.make_app", return_value=app),
            patch("tools.preview_ui.asyncio.sleep", new_callable=AsyncMock) as sleep,
        ):
            asyncio.run(preview(page, options))  # ty: ignore[invalid-argument-type]

        self.assertEqual(
            [awaited.args[0] for awaited in sleep.await_args_list], [0.22, 0.05]
        )
        page.on_close(None)


if __name__ == "__main__":
    unittest.main()
