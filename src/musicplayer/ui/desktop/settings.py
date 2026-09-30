from __future__ import annotations

from typing import TYPE_CHECKING

import flet as ft

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp


def _settings_view(app: MusicPlayerApp) -> ft.Control:
    download = app.settings_page._build_download_settings()
    appearance = app.settings_page._build_appearance_settings()
    youtube_access = app.settings_page._build_youtube_settings()
    maintenance = app.settings_page._build_maintenance_settings()
    data_management = app.settings_page._build_data_management_settings()
    footer = app.settings_page._build_settings_footer()
    appearance_column = ft.Column(
        [appearance, youtube_access, maintenance],
        spacing=16,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )
    appearance_column.col = {"xs": 12, "lg": 5}
    library_column = ft.Column(
        [download, data_management],
        spacing=16,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )
    library_column.col = {"xs": 12, "lg": 7}
    return ft.Column(
        [
            ft.Container(
                app.shared._context_header(
                    "Settings",
                    "Shape your listening experience.",
                ),
                padding=20,
                border_radius=22,
                gradient=ft.LinearGradient(
                    begin=ft.Alignment.TOP_LEFT,
                    end=ft.Alignment.BOTTOM_RIGHT,
                    colors=[
                        ft.Colors.PRIMARY_CONTAINER,
                        ft.Colors.SURFACE_CONTAINER_LOW,
                    ],
                ),
            ),
            app.shared._responsive_grid(
                [appearance_column, library_column],
                spacing=16,
                run_spacing=16,
                scroll=ft.ScrollMode.AUTO,
                expand=True,
            ),
            ft.Container(
                footer,
                padding=16,
                border_radius=18,
                bgcolor=ft.Colors.SURFACE_CONTAINER_LOW,
                border=ft.Border.all(1, ft.Colors.OUTLINE_VARIANT),
            ),
        ],
        spacing=16,
        expand=True,
    )
