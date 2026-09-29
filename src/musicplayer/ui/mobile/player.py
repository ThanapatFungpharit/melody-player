from __future__ import annotations

import flet as ft

from musicplayer.ui.components.player_bar import PlaybackBindings
from musicplayer.ui.theme import TOUCH_TARGET


class MobilePlayer(PlaybackBindings):
    """Mini player plus Now Playing; device buttons adjust volume."""

    @staticmethod
    def button(icon, label, action) -> ft.IconButton:
        return ft.IconButton(
            icon,
            tooltip=label,
            on_click=action,
            width=TOUCH_TARGET,
            height=TOUCH_TARGET,
        )

    def __init__(self, app) -> None:
        super().__init__(app)
        self.mini_title = ft.Text(
            max_lines=1,
            overflow=ft.TextOverflow.ELLIPSIS,
            weight=ft.FontWeight.W_600,
            size=14,
        )
        self.mini_credit = ft.Text(
            max_lines=1, overflow=ft.TextOverflow.ELLIPSIS, size=11
        )
        self.mini_play = self.button(
            ft.Icons.PLAY_ARROW_ROUNDED, "Play", lambda _: app.playback.toggle()
        )
        self.mini_next = self.button(
            ft.Icons.SKIP_NEXT_ROUNDED, "Next track", lambda _: app.playback.next()
        )
        self.mini_progress = ft.ProgressBar(value=0, height=3, color=ft.Colors.PRIMARY)
        self._mini_progress_changed = False
        self.root = ft.Container(
            ft.Column(
                [
                    ft.Row(
                        [
                            ft.Container(
                                ft.Row(
                                    [
                                        ft.Icon(
                                            ft.Icons.GRAPHIC_EQ_ROUNDED,
                                            color=ft.Colors.PRIMARY,
                                        ),
                                        ft.Column(
                                            [self.mini_title, self.mini_credit],
                                            spacing=1,
                                            expand=True,
                                        ),
                                    ],
                                    spacing=10,
                                ),
                                expand=True,
                                on_click=lambda _: app.shell.open_panel("player"),
                                tooltip="Open Now Playing",
                                padding=ft.Padding.symmetric(vertical=12),
                            ),
                            self.mini_play,
                            self.mini_next,
                        ],
                        spacing=4,
                    ),
                    self.mini_progress,
                ],
                spacing=0,
            ),
            padding=ft.Padding.symmetric(horizontal=12),
            bgcolor=ft.Colors.SURFACE_CONTAINER_HIGH,
        )
        self.resize(float(app.page.width or 390), float(app.page.height or 844))
        self.mini_play.bgcolor = ft.Colors.PRIMARY_CONTAINER
        self.mini_play.icon_color = ft.Colors.ON_PRIMARY_CONTAINER
        self.play.width = self.play.height = 64
        self.play.icon_size = 38
        self.play.bgcolor = ft.Colors.PRIMARY_CONTAINER

    def now_playing(self) -> ft.Control:
        self.resize(
            float(self.app.page.width or 390),
            float(self.app.page.height or 844),
        )
        self.refresh()
        self.full_player = ft.Column(
            [
                ft.Row(
                    [
                        ft.Text(
                            "Now Playing",
                            size=24,
                            weight=ft.FontWeight.BOLD,
                            expand=True,
                        ),
                        self.button(
                            ft.Icons.KEYBOARD_ARROW_DOWN_ROUNDED,
                            "Close Now Playing",
                            lambda _: self.app.context_panel._close_context_panel(),
                        ),
                    ]
                ),
                ft.Container(self.art, alignment=ft.Alignment.CENTER, padding=8),
                self.title,
                self.credit,
                ft.Row([self.position, self.seek, self.duration], spacing=4),
                ft.Row(
                    [self.shuffle, self.previous, self.play, self.next, self.repeat],
                    alignment=ft.MainAxisAlignment.SPACE_EVENLY,
                    spacing=0,
                ),
                ft.Row(
                    [
                        self.favorite,
                        self.mute,
                        self.stop,
                        ft.TextButton(
                            "Queue",
                            icon=ft.Icons.QUEUE_MUSIC_ROUNDED,
                            on_click=lambda _: (
                                self.app.context_panel._open_queue_panel()
                            ),
                            height=48,
                        ),
                    ],
                    alignment=ft.MainAxisAlignment.SPACE_EVENLY,
                ),
                ft.Text(
                    "Use your device’s volume buttons to adjust loudness.",
                    size=12,
                    color=ft.Colors.ON_SURFACE_VARIANT,
                    text_align=ft.TextAlign.CENTER,
                ),
            ],
            spacing=12,
            scroll=ft.ScrollMode.AUTO,
            expand=True,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        )
        return self.full_player

    def resize(self, width: float, height: float) -> None:
        cover_size = int(max(176, min(340, width - 64, height * 0.42)))
        if self.art.width == cover_size:
            return
        self.art.width = self.art.height = cover_size
        if self._player_is_mounted():
            self.refresh()

    def _player_is_mounted(self) -> bool:
        history = getattr(self.app.shell, "panel_history", ())
        return any(name == "player" for name, _, _ in history)

    def state_controls(self) -> list[ft.Control]:
        controls: list[ft.Control] = [
            self.mini_title,
            self.mini_credit,
            self.mini_play,
            self.mini_next,
            self.mini_progress,
        ]
        if self._player_is_mounted():
            controls.extend(super().state_controls())
        return controls

    def progress_controls(self) -> list[ft.Control]:
        controls: list[ft.Control] = (
            [self.mini_progress] if self._mini_progress_changed else []
        )
        if self._player_is_mounted():
            controls.extend(super().progress_controls())
        return controls

    def volume_controls(self) -> list[ft.Control]:
        return super().volume_controls() if self._player_is_mounted() else []

    def refresh(self, change: str = "state") -> None:
        super().refresh(change)
        self.mini_title.value = self.title.value
        self.mini_credit.value = self.credit.value
        self.mini_play.icon = self.play.icon
        self.mini_play.tooltip = self.play.tooltip
        self.mini_play.disabled = self.play.disabled
        self.mini_next.disabled = self.next.disabled

    def refresh_progress(self) -> None:
        previous = self.mini_progress.value
        super().refresh_progress()
        self.mini_progress.value = min(
            1, self.app.playback.position_ms / max(1, self.app.playback.duration_ms)
        )
        self._mini_progress_changed = previous != self.mini_progress.value

    def refresh_volume(self) -> None:
        super().refresh_volume()
        self.mute.tooltip = (
            "Restore sound"
            if self.app.playback.muted or self.app.playback.volume == 0
            else "Mute"
        )
