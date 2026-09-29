from __future__ import annotations

import flet as ft

from musicplayer.ui.components.navigation import NAVIGATION
from musicplayer.ui.mobile.insets import safe_area
from musicplayer.ui.mobile.player import MobilePlayer


class MobileShell:
    def __init__(self, app) -> None:
        self.app = app
        self.panel_history: list[tuple[str, ft.View, ft.Container]] = []

    def build(self) -> None:
        app = self.app
        app.content = ft.Container(
            expand=True, padding=ft.Padding.symmetric(horizontal=16, vertical=12)
        )
        app.player = MobilePlayer(app)
        self.downloads = ft.IconButton(
            ft.Icons.DOWNLOAD_ROUNDED,
            tooltip="Downloads",
            width=48,
            height=48,
            on_click=lambda _: app.context_panel._open_downloads_panel(),
        )
        self.bottom_nav = ft.NavigationBar(
            selected_index=0,
            height=64,
            bgcolor=ft.Colors.SURFACE_CONTAINER_LOW,
            indicator_color=ft.Colors.PRIMARY_CONTAINER,
            label_behavior=ft.NavigationBarLabelBehavior.ALWAYS_SHOW,
            destinations=[
                ft.NavigationBarDestination(icon=o, selected_icon=f, label=n)
                for n, f, o in NAVIGATION
            ],
            on_change=lambda e: app.navigation.navigate(int(e.control.selected_index)),
        )
        header = ft.Row(
            [
                ft.Container(
                    ft.Icon(ft.Icons.GRAPHIC_EQ_ROUNDED, color=ft.Colors.PRIMARY),
                    width=40,
                    height=40,
                    border_radius=12,
                    bgcolor=ft.Colors.PRIMARY_CONTAINER,
                    alignment=ft.Alignment.CENTER,
                ),
                ft.Text(
                    "Melody",
                    size=18,
                    weight=ft.FontWeight.BOLD,
                    color=ft.Colors.PRIMARY,
                    expand=True,
                ),
                self.downloads,
                ft.IconButton(
                    ft.Icons.SETTINGS_ROUNDED,
                    tooltip="Settings",
                    width=48,
                    height=48,
                    on_click=lambda _: app.context_panel._open_settings_panel(),
                ),
            ],
            spacing=4,
        )
        self.root = safe_area(
            ft.Column(
                [
                    ft.Container(header, padding=ft.Padding.symmetric(horizontal=16)),
                    app.content,
                    app.player.root,
                    self.bottom_nav,
                ],
                spacing=0,
                expand=True,
            ),
            expand=True,
        )
        self.root.opacity = 0 if getattr(app, "startup_transition", False) else 1
        self.root.animate_opacity = ft.Animation(300, ft.AnimationCurve.EASE_OUT)
        self.root_view = ft.View(
            route="/",
            padding=0,
            spacing=0,
            controls=[self.root],
        )
        app.page.views.clear()
        app.page.views.append(self.root_view)
        app.page.on_view_pop = self._back
        self.root_view.on_confirm_pop = self._confirm_back
        app.page.update()

    def select(self, index: int) -> None:
        self.bottom_nav.selected_index = index
        self.root_view.can_pop = (
            not (self.app.playlists_page.selected_playlist_id and index == 3)
            and index == 0
        )

    async def _confirm_back(self, event) -> None:
        if (
            self.app.playlists_page.selected_playlist_id
            and self.app.selected_navigation == 3
        ):
            self.app.playlists_page._close_playlist()
        elif self.app.selected_navigation != 0:
            self.app.navigation.navigate(0)
        await event.control.confirm_pop(False)

    def _back(self, _) -> None:
        self.close_panel()

    def open_panel(self, name: str) -> None:
        if self.app.active_panel == name:
            return
        # Queue can be opened from Now Playing, so back returns to the player.
        content = (
            self.app.player.now_playing()
            if name == "player"
            else self.app.context_panel._panel_view(name)
        )
        body = ft.Container(content, padding=16, expand=True)
        view = ft.View(
            route=f"/{name}",
            padding=0,
            controls=[safe_area(body, expand=True)],
        )
        self.panel_history.append((name, view, body))
        self.app.active_panel = name
        self.app.page.views.append(view)
        self.app.page.update()

    def close_panel(self) -> None:
        if self.panel_history:
            _, view, _ = self.panel_history.pop()
            if view in self.app.page.views:
                self.app.page.views.remove(view)
        self.app.active_panel = (
            self.panel_history[-1][0] if self.panel_history else None
        )
        self.app.page.update()

    def refresh_panel(self) -> None:
        if self.panel_history:
            name, _, body = self.panel_history[-1]
            if name != "player":
                body.content = self.app.context_panel._panel_view(name)
            self.app.page.update(body)

    def refresh_downloads(self) -> None:
        active = self.app.downloads.active_count()
        badge = str(active) if active else None
        tooltip = f"Downloads, {active} active" if active else "Downloads"
        if self.downloads.badge == badge and self.downloads.tooltip == tooltip:
            return
        self.downloads.badge = badge
        self.downloads.tooltip = tooltip
        self.app.page.update(self.downloads)

    def resize(self, width: float, height: float) -> None:
        self.app.player.resize(width, height)
        # Flex and scrolling handle orientation without recreating forms or state.
        controls = [self.app.player.root]
        if self.app.player._player_is_mounted():
            controls.append(self.app.player.full_player)
        self.app.page.update(*controls)

    def keyboard(self, event) -> None:
        pass

    def context_header(self, title, subtitle, *actions):
        from musicplayer.ui.mobile.controls import heading, icon_button

        return heading(
            title,
            subtitle,
            *actions,
            icon_button(
                ft.Icons.ARROW_BACK_ROUNDED, "Back", lambda _: self.close_panel()
            ),
        )
