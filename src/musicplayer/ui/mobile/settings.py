from __future__ import annotations

import flet as ft

from musicplayer.core.media import YOUTUBE_MUSIC_NAME
from musicplayer.ui.mobile.controls import heading, icon_button, scroll_page


def _settings_view(app) -> ft.Control:
    # Field validation, cookie upload, reset confirmation and saving are shared.
    appearance = app.settings_page._build_appearance_settings()
    download = app.settings_page._build_download_settings()
    youtube = app.settings_page._build_youtube_settings()
    data = ft.Column(
        [
            ft.Text(
                "Audio files stay on your device. Each action asks you to confirm.",
                size=12,
            ),
            *[
                ft.OutlinedButton(
                    label,
                    icon=ft.Icons.DELETE_OUTLINE_ROUNDED,
                    height=48,
                    on_click=lambda _, selected=action: (
                        app.settings_page._confirm_data_action(selected)
                    ),
                )
                for label, action in (
                    ("Clear library and playlists", "library"),
                    ("Clear playlists", "playlists"),
                    ("Reset settings", "settings"),
                    ("Reset everything", "everything"),
                )
            ],
        ],
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        spacing=12,
    )
    app.settings_page.path.read_only = True
    app.settings_page.path.helper_text = (
        "Completed tracks are saved in the public Music/Melody folder"
        if app._is_android_platform()
        else "Managed music folder on this device"
    )
    return scroll_page(
        [
            heading(
                "Settings",
                "",
                icon_button(
                    ft.Icons.ARROW_BACK_ROUNDED,
                    "Back",
                    lambda _: app.context_panel._close_context_panel(),
                ),
            ),
            appearance,
            ft.ExpansionTile(
                title=ft.Text("Download defaults"),
                controls=[download],
                maintain_state=True,
            ),
            ft.ExpansionTile(
                title=ft.Text(f"{YOUTUBE_MUSIC_NAME} access"),
                controls=[youtube],
                maintain_state=True,
            ),
            ft.ExpansionTile(
                title=ft.Text("Data management"), controls=[data], maintain_state=True
            ),
            ft.Button(
                "Save settings",
                icon=ft.Icons.SAVE_ROUNDED,
                height=52,
                on_click=lambda _: app.settings_page._save_settings(),
            ),
            ft.TextButton(
                "Cancel changes",
                height=48,
                on_click=lambda _: app.settings_page._cancel_settings(),
            ),
        ]
    )
