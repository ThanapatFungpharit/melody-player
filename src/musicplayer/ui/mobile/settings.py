from __future__ import annotations

import flet as ft

from musicplayer.core.media import YOUTUBE_MUSIC_NAME
from musicplayer.ui.mobile.controls import heading, icon_button, scroll_page


def _settings_tile(
    title: str,
    subtitle: str,
    icon: ft.IconData,
    section: ft.Container,
    *,
    destructive: bool = False,
) -> ft.ExpansionTile:
    # The tile supplies the section heading on mobile, so only its fields show
    # when it opens.
    if isinstance(section.content, ft.Column):
        section.content.controls[0].visible = False
    section.padding = ft.Padding.only(left=16, right=16, bottom=16)
    section.bgcolor = ft.Colors.TRANSPARENT
    section.border = None
    color = ft.Colors.ERROR if destructive else ft.Colors.PRIMARY
    shape = ft.RoundedRectangleBorder(radius=18)
    return ft.ExpansionTile(
        title=ft.Text(title, weight=ft.FontWeight.BOLD),
        subtitle=ft.Text(subtitle, size=12, color=ft.Colors.ON_SURFACE_VARIANT),
        leading=ft.Icon(icon, color=color),
        controls=[section],
        tile_padding=ft.Padding.symmetric(horizontal=16, vertical=4),
        bgcolor=ft.Colors.SURFACE_CONTAINER_LOW,
        collapsed_bgcolor=ft.Colors.SURFACE_CONTAINER_LOW,
        shape=shape,
        collapsed_shape=shape,
        icon_color=color,
        collapsed_icon_color=color,
        maintain_state=True,
    )


def _settings_view(app) -> ft.Control:
    appearance = app.settings_page._build_appearance_settings()
    download = app.settings_page._build_download_settings()
    youtube = app.settings_page._build_youtube_settings()
    data = app.settings_page._build_data_management_settings()
    app.settings_page.path.read_only = True
    app.settings_page.path.helper_text = (
        "Completed tracks are saved in the public Music/Melody folder"
        if app._is_android_platform()
        else "Managed music folder on this device"
    )
    content = scroll_page(
        [
            ft.Container(
                heading(
                    "Settings",
                    "Make Melody feel like yours.",
                    icon_button(
                        ft.Icons.ARROW_BACK_ROUNDED,
                        "Back",
                        lambda _: app.context_panel._close_context_panel(),
                    ),
                ),
                padding=16,
                border_radius=20,
                bgcolor=ft.Colors.PRIMARY_CONTAINER,
            ),
            _settings_tile(
                "Appearance",
                "Theme, accent, startup and notifications",
                ft.Icons.TUNE_ROUNDED,
                appearance,
            ),
            _settings_tile(
                "Downloads",
                "Folder, format, quality and speed",
                ft.Icons.DOWNLOAD_FOR_OFFLINE_ROUNDED,
                download,
            ),
            _settings_tile(
                YOUTUBE_MUSIC_NAME,
                "Account access and cookies",
                ft.Icons.SMART_DISPLAY_ROUNDED,
                youtube,
            ),
            _settings_tile(
                "Data management",
                "Clear or reset local data",
                ft.Icons.DELETE_SWEEP_ROUNDED,
                data,
                destructive=True,
            ),
        ]
    )
    footer = ft.Container(
        ft.Row(
            [
                ft.TextButton(
                    "Cancel",
                    height=48,
                    on_click=lambda _: app.settings_page._cancel_settings(),
                ),
                ft.Button(
                    "Save settings",
                    icon=ft.Icons.SAVE_ROUNDED,
                    height=48,
                    expand=True,
                    on_click=lambda _: app.settings_page._save_settings(),
                ),
            ],
            spacing=12,
        ),
        padding=12,
        border_radius=18,
        bgcolor=ft.Colors.SURFACE_CONTAINER_LOW,
        border=ft.Border.all(1, ft.Colors.OUTLINE_VARIANT),
    )
    return ft.Column([content, footer], spacing=10, expand=True)
