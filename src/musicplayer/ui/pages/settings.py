from __future__ import annotations

import logging
from dataclasses import replace
from pathlib import Path
from typing import TYPE_CHECKING, Any

import flet as ft

from musicplayer.application.cookie_files import (
    COOKIE_FILE_NAME,
    CookieFileError,
    ValidatedCookieFile,
    install_cookie_file,
    validate_cookie_file,
)
from musicplayer.application.models import AppSettings
from musicplayer.application.providers import ProviderRegistry
from musicplayer.core.media import YOUTUBE_MUSIC_NAME
from musicplayer.platform_runtime import public_music_directory
from musicplayer.ui.components.common import _theme_mode
from musicplayer.ui.tasks import page_action
from musicplayer.ui.theme import THEME_PALETTES, card

if TYPE_CHECKING:
    from musicplayer.app import MusicPlayerApp

logger = logging.getLogger(__name__)


class SettingsPage:
    """Settings page UI and persistence workflow."""

    def __init__(self, app: MusicPlayerApp):
        self.app = app
        self.theme_draft = app.settings.theme
        self.accent_draft = app.settings.accent_color
        self.selected_accent = app.settings.accent_color
        self.pending_cookie_file: ValidatedCookieFile | None = None
        self.pending_cookie_name = ""
        self.remove_cookie_requested = False

    def _settings_view(self) -> ft.Control:
        return self.app.views._settings_view(self.app)

    def _build_download_settings(self) -> ft.Container:
        android_public_music = self.app._is_android_platform()
        self.path = ft.TextField(
            value=(
                str(public_music_directory())
                if android_public_music
                else self.app.settings.download_directory
            ),
            label="Music & download folder",
            prefix_icon=ft.Icons.FOLDER_ROUNDED,
            height=56,
            border_radius=12,
            text_size=14,
            read_only=android_public_music,
        )
        self.format = ft.Dropdown(
            value=self.app.settings.audio_format,
            label="Audio format",
            height=56,
            border_radius=12,
            options=[
                ft.DropdownOption(key="mp3", text="MP3"),
                ft.DropdownOption(key="m4a", text="M4A"),
                ft.DropdownOption(key="opus", text="Opus"),
            ],
        )
        self.quality = ft.Dropdown(
            value=self.app.settings.audio_quality,
            label="Audio quality",
            height=56,
            border_radius=12,
            options=[
                ft.DropdownOption(key="best", text="Best available"),
                ft.DropdownOption(key="320", text="320 kbps"),
                ft.DropdownOption(key="256", text="256 kbps"),
                ft.DropdownOption(key="192", text="192 kbps"),
                ft.DropdownOption(key="128", text="128 kbps"),
            ],
        )
        self.concurrency = ft.Slider(
            min=1,
            max=8,
            divisions=7,
            value=self.app.settings.concurrent_downloads,
            label="{value} simultaneous",
            on_change=self._settings_concurrency_changed,
        )
        self.concurrency_value = ft.Text(
            f"{self.app.settings.concurrent_downloads} workers",
            weight=ft.FontWeight.BOLD,
            color=ft.Colors.PRIMARY,
        )
        for control in (self.format, self.quality):
            control.col = {"xs": 12, "md": 6}
        return _settings_card(
            [
                self._settings_section_header(
                    ft.Icons.DOWNLOAD_FOR_OFFLINE_ROUNDED,
                    "Download defaults",
                    "Control where audio is saved and how new downloads are processed.",
                ),
                self.path,
                self.app.shared._responsive_grid(
                    [self.format, self.quality],
                    spacing=12,
                    run_spacing=12,
                ),
                ft.Row(
                    [
                        ft.Column(
                            [
                                ft.Text(
                                    "Concurrent downloads",
                                    weight=ft.FontWeight.BOLD,
                                ),
                                ft.Text(
                                    "Balance speed against network and CPU usage.",
                                    size=12,
                                    color=ft.Colors.ON_SURFACE_VARIANT,
                                ),
                            ],
                            spacing=2,
                            expand=True,
                        ),
                        self.concurrency_value,
                    ]
                ),
                self.concurrency,
                ft.Container(
                    ft.Row(
                        [
                            ft.Icon(
                                ft.Icons.RESTART_ALT_ROUNDED,
                                size=20,
                                color=ft.Colors.PRIMARY,
                            ),
                            ft.Text(
                                "Download changes apply after restarting Melody.",
                                size=12,
                                color=ft.Colors.ON_SURFACE_VARIANT,
                                expand=True,
                            ),
                        ],
                        spacing=10,
                    ),
                    padding=12,
                    border_radius=12,
                    bgcolor=ft.Colors.PRIMARY_CONTAINER,
                ),
            ],
            columns={"xs": 12, "lg": 6, "xl": 4},
        )

    def _build_appearance_settings(self) -> ft.Container:
        # Keep in-progress appearance choices separate from persisted settings.
        # The mobile settings screen may rebuild this section after a swatch or
        # theme choice, so reading directly from ``settings`` would discard the
        # user's current choice on every refresh.
        self.theme_draft = self.theme_draft or self.app.settings.theme
        self.accent_draft = self.accent_draft or self.app.settings.accent_color
        self.theme = ft.Dropdown(
            value=self.theme_draft,
            label="Theme",
            height=56,
            border_radius=12,
            options=[
                ft.DropdownOption(key="dark", text="Dark"),
                ft.DropdownOption(key="light", text="Light"),
                ft.DropdownOption(key="system", text="Use system setting"),
            ],
            on_select=self._theme_changed,
        )
        self.resume = ft.Switch(
            label="Resume queue and playback state",
            value=self.app.settings.resume_session,
        )
        self.notifications = ft.Switch(
            label="Notify when tracks change", value=self.app.settings.notifications
        )
        # -- accent color picker ----------------------------------------
        self.selected_accent = self.accent_draft
        self.accent_picker = self._build_accent_picker()
        return _settings_card(
            [
                self._settings_section_header(
                    ft.Icons.TUNE_ROUNDED,
                    "Appearance & session",
                    "Choose how Melody looks and restores your workspace.",
                ),
                self.theme,
                ft.Text(
                    "Accent color",
                    weight=ft.FontWeight.BOLD,
                ),
                self.accent_picker,
                ft.Divider(height=18),
                self.resume,
                self.notifications,
            ],
            columns={"xs": 12, "lg": 6, "xl": 4},
        )

    def _build_youtube_settings(self) -> ft.Container:
        self.pending_cookie_file: ValidatedCookieFile | None = None
        self.pending_cookie_name = ""
        self.remove_cookie_requested = False
        configured_path = self.app.settings.cookie_file
        configured_cookie = bool(configured_path) and Path(configured_path).is_file()
        cookie_missing = bool(configured_path) and not configured_cookie
        if configured_cookie:
            cookie_status = f"Using {Path(self.app.settings.cookie_file).name}"
        elif cookie_missing:
            cookie_status = "The saved cookie file is missing. Upload a replacement."
        else:
            cookie_status = (
                f"No cookie file uploaded. {YOUTUBE_MUSIC_NAME} requests are anonymous."
            )
        self.cookie_status = ft.Text(
            cookie_status,
            size=12,
            color=(ft.Colors.ERROR if cookie_missing else ft.Colors.ON_SURFACE_VARIANT),
            expand=True,
        )
        self.cookie_upload = ft.Button(
            "Replace file" if configured_cookie else "Upload cookie file",
            icon=ft.Icons.UPLOAD_FILE_ROUNDED,
            on_click=self._pick_cookie_file,
        )
        self.cookie_remove = ft.TextButton(
            "Remove",
            icon=ft.Icons.DELETE_OUTLINE_ROUNDED,
            disabled=not configured_cookie,
            on_click=self._remove_cookie_file,
        )
        return _settings_card(
            [
                self._settings_section_header(
                    ft.Icons.SMART_DISPLAY_ROUNDED,
                    f"{YOUTUBE_MUSIC_NAME} access",
                    f"{YOUTUBE_MUSIC_NAME} is Melody’s default and only music source.",
                ),
                ft.Text(
                    f"{YOUTUBE_MUSIC_NAME} cookies",
                    weight=ft.FontWeight.BOLD,
                ),
                ft.Container(
                    ft.Row(
                        [
                            ft.Icon(
                                ft.Icons.COOKIE_OUTLINED,
                                size=20,
                                color=ft.Colors.ON_SURFACE_VARIANT,
                            ),
                            self.cookie_status,
                        ],
                        spacing=10,
                        vertical_alignment=ft.CrossAxisAlignment.START,
                    ),
                    padding=12,
                    border_radius=12,
                    bgcolor=ft.Colors.SURFACE_CONTAINER_HIGH,
                ),
                ft.Row(
                    [
                        self.cookie_upload,
                        self.cookie_remove,
                    ],
                    spacing=10,
                    scroll=ft.ScrollMode.AUTO,
                ),
                ft.Text(
                    "Upload a UTF-8 Netscape cookies.txt export. Melody validates it and copies it to private app storage; it never reads browser cookie databases. The same flow works on desktop and Android.",
                    size=12,
                    color=ft.Colors.ON_SURFACE_VARIANT,
                ),
            ],
            columns={"xs": 12, "lg": 12, "xl": 4},
        )

    def _build_data_management_settings(self) -> ft.Container:
        return _settings_card(
            [
                self._settings_section_header(
                    ft.Icons.DELETE_SWEEP_ROUNDED,
                    "Reset / Data Management",
                    "Remove only the local data you choose. Every action asks for confirmation.",
                ),
                self.app.shared._responsive_grid(
                    [
                        self._data_management_action(
                            "Clear Library",
                            "Remove every library track and all playlists. Audio files stay on disk.",
                            "Clear library",
                            ft.Icons.LIBRARY_MUSIC_ROUNDED,
                            "library",
                        ),
                        self._data_management_action(
                            "Clear Playlists",
                            "Delete user-created playlists while keeping every library track.",
                            "Clear playlists",
                            ft.Icons.QUEUE_MUSIC_ROUNDED,
                            "playlists",
                        ),
                        self._data_management_action(
                            "Reset Settings",
                            "Restore appearance, playback, download, and session settings to defaults.",
                            "Reset settings",
                            ft.Icons.RESTART_ALT_ROUNDED,
                            "settings",
                        ),
                    ],
                    spacing=12,
                    run_spacing=12,
                ),
                ft.Container(
                    self.app.shared._responsive_grid(
                        [
                            ft.Column(
                                [
                                    ft.Row(
                                        [
                                            ft.Icon(
                                                ft.Icons.WARNING_AMBER_ROUNDED,
                                                color=ft.Colors.ERROR,
                                            ),
                                            ft.Text(
                                                "Reset Everything",
                                                size=18,
                                                weight=ft.FontWeight.BOLD,
                                                color=ft.Colors.ERROR,
                                            ),
                                        ],
                                        spacing=8,
                                    ),
                                    ft.Text(
                                        "Clear the library and playlists, empty the playback queue, and restore all settings. Audio files, download history, and search history are preserved.",
                                        size=12,
                                        color=ft.Colors.ON_ERROR_CONTAINER,
                                    ),
                                ],
                                spacing=5,
                                col={"xs": 12, "md": 8},
                            ),
                            ft.Container(
                                ft.Button(
                                    "Reset everything",
                                    icon=ft.Icons.DELETE_FOREVER_ROUNDED,
                                    color=ft.Colors.ON_ERROR,
                                    bgcolor=ft.Colors.ERROR,
                                    height=52,
                                    on_click=lambda _: self._confirm_data_action(
                                        "everything"
                                    ),
                                ),
                                alignment=ft.Alignment.CENTER_RIGHT,
                                col={"xs": 12, "md": 4},
                            ),
                        ],
                        spacing=12,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    padding=16,
                    border_radius=14,
                    bgcolor=ft.Colors.ERROR_CONTAINER,
                    border=ft.Border.all(1, ft.Colors.ERROR),
                ),
            ],
            columns={"xs": 12},
        )

    def _build_settings_footer(self) -> ft.ResponsiveRow:
        footer_copy = ft.Text(
            "Changes are saved locally on this device.",
            size=12,
            color=ft.Colors.ON_SURFACE_VARIANT,
        )
        footer_copy.col = {"xs": 12, "md": 5}
        footer_actions = ft.Container(
            ft.Row(
                [
                    ft.TextButton(
                        "Cancel",
                        height=48,
                        on_click=lambda _: self._cancel_settings(),
                    ),
                    ft.Button(
                        "Save settings",
                        icon=ft.Icons.SAVE_ROUNDED,
                        width=180,
                        height=48,
                        on_click=lambda _: self._save_settings(),
                    ),
                ],
                spacing=12,
                alignment=ft.MainAxisAlignment.END,
            ),
            alignment=ft.Alignment.CENTER_RIGHT,
        )
        footer_actions.col = {"xs": 12, "md": 7}
        return self.app.shared._responsive_grid(
            [footer_copy, footer_actions],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )

    def _data_management_action(
        self,
        title: str,
        description: str,
        button_label: str,
        icon: Any,
        action: str,
    ) -> ft.Control:
        result = ft.Container(
            ft.Column(
                [
                    ft.Text(title, weight=ft.FontWeight.BOLD),
                    ft.Text(
                        description,
                        size=12,
                        color=ft.Colors.ON_SURFACE_VARIANT,
                        expand=True,
                    ),
                    ft.OutlinedButton(
                        button_label,
                        icon=icon,
                        icon_color=ft.Colors.ERROR,
                        style=ft.ButtonStyle(color=ft.Colors.ERROR),
                        on_click=lambda _, selected=action: self._confirm_data_action(
                            selected
                        ),
                    ),
                ],
                spacing=10,
                horizontal_alignment=ft.CrossAxisAlignment.START,
            ),
            padding=14,
            border_radius=14,
            bgcolor=ft.Colors.SURFACE_CONTAINER_HIGH,
        )
        result.col = {"xs": 12, "lg": 4}
        return result

    def _confirm_data_action(self, action: str) -> None:
        track_count, playlist_count = self.app.manager.counts()
        track_word = "track" if track_count == 1 else "tracks"
        playlist_word = "playlist" if playlist_count == 1 else "playlists"
        details = {
            "library": (
                "Clear library?",
                (
                    f"Remove {track_count} library {track_word} and {playlist_count} "
                    f"{playlist_word}. All playlists, the playback queue, favorites, "
                    "and track-linked listening history will be cleared. Downloaded "
                    "and imported audio files stay on disk. Settings, download "
                    "history, and search history are not changed."
                ),
                "Clear library",
                False,
            ),
            "playlists": (
                "Clear playlists?",
                (
                    f"Delete {playlist_count} user-created {playlist_word}. Library "
                    "tracks, audio files, settings, the playback queue, and histories "
                    "are not changed."
                ),
                "Clear playlists",
                False,
            ),
            "settings": (
                "Reset settings?",
                (
                    "Restore appearance, volume, session, download, cookie, "
                    "and notification settings to their defaults. Library tracks, "
                    "playlists, audio files, download history, and search history are "
                    "not changed. Any cookie file copied into Melody’s private app "
                    "storage will be removed; external files are never deleted."
                ),
                "Reset settings",
                False,
            ),
            "everything": (
                "Reset everything?",
                (
                    f"Remove {track_count} library {track_word} and {playlist_count} "
                    f"{playlist_word}, clear the playback queue and track-linked "
                    "history, and restore every setting to its default. Audio files, "
                    "download history, and search history remain on this device. This "
                    "cannot be undone inside Melody."
                ),
                "Reset everything",
                True,
            ),
        }
        if action not in details:
            raise ValueError(f"Unknown data-management action: {action}")
        title, description, confirm_label, prominent = details[action]

        self.app.page.show_dialog(
            ft.AlertDialog(
                scrollable=True,
                modal=True,
                icon=ft.Icon(
                    ft.Icons.WARNING_AMBER_ROUNDED,
                    color=ft.Colors.ERROR,
                    size=32,
                ),
                title=ft.Text(title),
                content=ft.Text(description),
                actions=[
                    ft.TextButton(
                        "Cancel", on_click=lambda _: self.app.page.pop_dialog()
                    ),
                    ft.Button(
                        confirm_label,
                        icon=(
                            ft.Icons.DELETE_FOREVER_ROUNDED
                            if prominent
                            else ft.Icons.DELETE_OUTLINE_ROUNDED
                        ),
                        color=ft.Colors.ON_ERROR if prominent else ft.Colors.ERROR,
                        bgcolor=ft.Colors.ERROR if prominent else None,
                        on_click=lambda _: self._run_data_action(action),
                    ),
                ],
            )
        )

    @page_action
    async def _run_data_action(self, action: str) -> None:
        try:
            message = await {
                "library": self._clear_library,
                "playlists": self._clear_playlists,
                "settings": self._reset_settings,
                "everything": self._reset_everything,
            }[action]()
        except (OSError, TypeError, ValueError, RuntimeError) as error:
            self.app.page.pop_dialog()
            self._refresh_after_data_action(action)
            self.app._show_error(f"The reset could not be completed: {error}")
            return

        self.app.page.pop_dialog()
        self._refresh_after_data_action(action)
        self.app._show_message(message)

    async def _clear_library(self) -> str:
        track_count, playlist_count = await self.app.tasks.io(
            self.app.manager.clear_library
        )
        self.app.playlists_page._abandon_playlist_import()
        self.app.playback.clear_library_state()
        await self.app.tasks.io(self.app.store.clear_library_data)
        self.app.playlists_page.selected_playlist_id = None
        if not track_count and not playlist_count:
            return "The library and playlists are already empty."
        return (
            f"Cleared {track_count} library track"
            f"{'s' if track_count != 1 else ''} and {playlist_count} playlist"
            f"{'s' if playlist_count != 1 else ''}. Audio files were kept."
        )

    async def _clear_playlists(self) -> str:
        playlist_count = await self.app.tasks.io(self.app.manager.clear_playlists)
        self.app.playlists_page._abandon_playlist_import()
        self.app.playlists_page.selected_playlist_id = None
        if not playlist_count:
            return "There are no playlists to clear."
        return (
            f"Deleted {playlist_count} playlist"
            f"{'s' if playlist_count != 1 else ''}. Library tracks were kept."
        )

    async def _reset_settings(self) -> str:
        already_default = await self._restore_default_settings()
        if already_default:
            return "Settings already use their default values."
        return "Settings restored to defaults. Download engine changes apply after restart."

    async def _reset_everything(self) -> str:
        track_count, playlist_count = await self.app.tasks.io(
            self.app.manager.clear_library
        )
        self.app.playlists_page._abandon_playlist_import()
        self.app.playback.clear_library_state()
        await self.app.tasks.io(self.app.store.clear_library_data)
        self.app.playlists_page.selected_playlist_id = None
        already_default = await self._restore_default_settings()
        if not track_count and not playlist_count and already_default:
            return "The library, playlists, and settings are already reset."
        return (
            "Library, playlists, and settings were reset. Audio files and unrelated "
            "history were kept. Download engine changes apply after restart."
        )

    async def _restore_default_settings(self) -> bool:
        defaults = AppSettings()
        already_default = self.app.settings == defaults
        configured_cookie = self.app.settings.cookie_file
        managed_cookie = Path(self.app.data_directory) / COOKIE_FILE_NAME
        if configured_cookie and await self.app.tasks.io(
            Path(configured_cookie).resolve
        ) == await self.app.tasks.io(managed_cookie.resolve):
            await self.app.tasks.io(managed_cookie.unlink, missing_ok=True)

        for name in defaults.__dataclass_fields__:
            setattr(self.app.settings, name, getattr(defaults, name))
        await self.app.tasks.io(self.app.store.save_settings, self.app.settings)
        self.app.playback.apply_settings(self.app.settings)
        self.app.providers = await self.app.tasks.io(
            ProviderRegistry, settings=self.app.settings
        )
        self.app.page.theme_mode = _theme_mode(self.app.settings.theme)
        self.pending_cookie_file = None
        self.pending_cookie_name = ""
        self.remove_cookie_requested = False
        return already_default

    def _refresh_after_data_action(self, action: str) -> None:
        if action in {"library", "playlists", "everything"}:
            self.app.playlists_page.selected_playlist_id = None
            if hasattr(self.app, "content"):
                self.app.navigation.navigate(self.app.selected_navigation)
        if hasattr(self.app, "player_bar"):
            self.app.player_bar._refresh_player()
        if getattr(self.app, "active_panel", None):
            self.app.context_panel._refresh_context_panel()
        else:
            self.app.page.update()

    @staticmethod
    def _settings_section_header(icon: Any, title: str, subtitle: str) -> ft.Control:
        return ft.Row(
            [
                ft.Container(
                    ft.Icon(icon, color=ft.Colors.PRIMARY, size=24),
                    width=46,
                    height=46,
                    border_radius=14,
                    bgcolor=ft.Colors.PRIMARY_CONTAINER,
                    alignment=ft.Alignment.CENTER,
                ),
                ft.Column(
                    [
                        ft.Text(title, size=18, weight=ft.FontWeight.BOLD),
                        ft.Text(
                            subtitle,
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
        )

    def _settings_concurrency_changed(self, event: Any) -> None:
        self.concurrency_value.value = f"{int(event.control.value)} workers"
        self.app.page.update(self.concurrency_value)

    def _build_accent_picker(self) -> ft.Control:
        """Build a row of clickable accent-color swatches."""
        swatches: list[ft.Control] = []
        for name, hex_color in THEME_PALETTES.items():
            selected = name == self.selected_accent
            swatch = ft.Container(
                ft.Column(
                    [
                        ft.Container(
                            width=40,
                            height=40,
                            border_radius=20,
                            bgcolor=hex_color,
                            border=ft.Border.all(
                                3 if selected else 1,
                                ft.Colors.ON_SURFACE
                                if selected
                                else ft.Colors.OUTLINE_VARIANT,
                            ),
                            animate=ft.Animation(150, ft.AnimationCurve.EASE_OUT),
                        ),
                        ft.Text(
                            name.capitalize(),
                            size=11,
                            text_align=ft.TextAlign.CENTER,
                            weight=ft.FontWeight.BOLD
                            if selected
                            else ft.FontWeight.NORMAL,
                        ),
                    ],
                    spacing=4,
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                on_click=lambda _, n=name: self._select_accent(n),
                padding=4,
            )
            swatches.append(swatch)
        return ft.Row(swatches, spacing=8, scroll=ft.ScrollMode.AUTO)

    def _select_accent(self, name: str) -> None:
        """Update the visually selected accent palette."""
        self.accent_draft = name
        self.selected_accent = name
        self.accent_picker = self._build_accent_picker()
        self.app._reapply_accent()
        self.app.context_panel._refresh_context_panel()

    def _theme_changed(self, event: Any) -> None:
        """Preview a theme choice immediately; persistence still happens on save."""
        value = str(getattr(event.control, "value", "") or "system")
        self.theme_draft = value
        self.app.page.theme_mode = _theme_mode(value)
        self.app.page.update()

    async def _pick_cookie_file(self, _: Any) -> None:
        try:
            files = await self.app.file_picker.pick_files(
                dialog_title=f"Upload {YOUTUBE_MUSIC_NAME} cookies",
                file_type=ft.FilePickerFileType.CUSTOM,
                allowed_extensions=["txt"],
                allow_multiple=False,
                with_data=True,
            )
        except (ft.FletException, OSError, RuntimeError) as error:
            self.app._show_error(f"The cookie file picker could not be opened: {error}")
            return
        if not files:
            return

        selected = files[0]
        try:
            content = selected.bytes
            if content is None and selected.path:
                content = await self.app.tasks.io(Path(selected.path).read_bytes)
            if content is None:
                raise CookieFileError("The selected cookie file could not be read.")
            validated = await self.app.tasks.io(validate_cookie_file, bytes(content))
        except (CookieFileError, OSError) as error:
            self.app._show_error(str(error))
            return

        self.pending_cookie_file = validated
        self.pending_cookie_name = selected.name
        self.remove_cookie_requested = False
        self.cookie_status.value = (
            f"Ready to save {selected.name} ({validated.cookie_count} "
            f"cookie{'s' if validated.cookie_count != 1 else ''})."
        )
        self.cookie_status.color = ft.Colors.PRIMARY
        self.cookie_upload.content = "Choose another file"
        self.cookie_remove.disabled = False
        self.app.page.update(
            self.cookie_status,
            self.cookie_upload,
            self.cookie_remove,
        )

    def _remove_cookie_file(self, _: Any) -> None:
        self.pending_cookie_file = None
        self.pending_cookie_name = ""
        self.remove_cookie_requested = True
        self.cookie_status.value = (
            "The cookie file will be removed when settings are saved."
        )
        self.cookie_status.color = ft.Colors.ON_SURFACE_VARIANT
        self.cookie_upload.content = "Upload cookie file"
        self.cookie_remove.disabled = True
        self.app.page.update(
            self.cookie_status,
            self.cookie_upload,
            self.cookie_remove,
        )

    def _cancel_settings(self) -> None:
        self.pending_cookie_file = None
        self.pending_cookie_name = ""
        self.remove_cookie_requested = False
        self.theme_draft = self.app.settings.theme
        self.accent_draft = self.app.settings.accent_color
        self.app.page.theme_mode = _theme_mode(self.app.settings.theme)
        self.app._reapply_accent()
        self.app.context_panel._close_context_panel()

    @page_action
    async def _save_settings(self) -> None:
        settings = replace(self.app.settings)
        folder_text = self.path.value or ""
        pending = self.pending_cookie_file
        remove_cookie = self.remove_cookie_requested
        settings.audio_format = self.format.value or "mp3"
        settings.audio_quality = self.quality.value or "best"
        settings.concurrent_downloads = int(self.concurrency.value or 1)
        settings.theme = self.theme_draft or self.theme.value or "system"
        settings.accent_color = self.accent_draft or self.selected_accent
        settings.resume_session = bool(self.resume.value)
        settings.notifications = bool(self.notifications.value)
        old_settings = replace(self.app.settings)
        self.app._show_message("Saving settings…")

        def persist():
            folder = (
                Path(old_settings.download_directory)
                if self.app._is_android_platform()
                else Path(folder_text).expanduser()
            )
            if (
                folder.resolve() != Path(old_settings.download_directory).resolve()
                and self.app.manager.counts()[0]
            ):
                raise ValueError(
                    "The music folder can only be changed while the library is empty."
                )
            folder.mkdir(parents=True, exist_ok=True)
            settings.download_directory = str(folder)
            managed = Path(self.app.data_directory) / COOKIE_FILE_NAME
            removing_managed_cookie = bool(
                remove_cookie
                and settings.cookie_file
                and Path(settings.cookie_file).resolve() == managed.resolve()
            )
            cookie_changed = pending is not None or removing_managed_cookie
            previous_cookie: bytes | None = None
            previous_cookie_existed = False
            if cookie_changed:
                try:
                    previous_cookie = managed.read_bytes()
                    previous_cookie_existed = True
                except FileNotFoundError:
                    pass

            try:
                if pending is not None:
                    settings.cookie_file = str(install_cookie_file(pending, managed))
                elif remove_cookie:
                    if removing_managed_cookie:
                        managed.unlink(missing_ok=True)
                    settings.cookie_file = ""
                providers = ProviderRegistry(settings=settings)
                self.app.store.save_settings(settings)
            except Exception:
                if cookie_changed:
                    try:
                        if previous_cookie_existed:
                            install_cookie_file(
                                ValidatedCookieFile(previous_cookie or b"", 0), managed
                            )
                        else:
                            managed.unlink(missing_ok=True)
                    except OSError:
                        logger.exception(
                            "Could not restore the managed cookie file after a "
                            "settings save failure"
                        )
                raise
            return providers

        providers = await self.app.tasks.io(persist)
        self.app.settings = settings
        self.app.providers = providers
        if self.pending_cookie_file is pending:
            self.pending_cookie_file = None
            self.pending_cookie_name = ""
            self.remove_cookie_requested = False
        self.theme_draft, self.accent_draft = (
            settings.theme,
            settings.accent_color,
        )
        self.app.page.theme_mode = _theme_mode(settings.theme)
        self.app._reapply_accent()
        self.app.page.update()
        restart = (
            any(
                getattr(settings, key) != getattr(old_settings, key)
                for key in (
                    "download_directory",
                    "audio_format",
                    "audio_quality",
                    "concurrent_downloads",
                    "cookie_file",
                )
            )
            or pending is not None
        )
        self.app._show_message(
            "Settings saved. Restart to apply download changes."
            if restart
            else "Settings saved."
        )


def _settings_card(
    controls: list[ft.Control], *, columns: ft.ResponsiveNumber
) -> ft.Container:
    section = card(
        ft.Column(
            controls,
            spacing=16,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        ),
        padding=22,
    )
    section.col = columns
    return section
