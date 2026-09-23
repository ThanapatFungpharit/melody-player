from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import flet as ft

from musicplayer.application.downloads import DownloadCoordinator
from musicplayer.application.library_service import LibraryService
from musicplayer.application.models import DownloadRecord
from musicplayer.application.playback import PlaybackController
from musicplayer.application.playback_persistence import PlaybackPersistence
from musicplayer.application.providers import ProviderRegistry
from musicplayer.application.store import ApplicationStore
from musicplayer.application.thumbnails import ThumbnailCache
from musicplayer.core.concurrency import LazyBoundedExecutor, WorkerQueueFull
from musicplayer.core.library import MusicManager
from musicplayer.platform_runtime import (
    UnsupportedPlatformError,
    application_data_directory,
    current_platform,
    public_music_directory,
)
from musicplayer.runtime_environment import public_error_message
from musicplayer.ui.audio_backend import ManagedAudioBackend
from musicplayer.ui.components import (
    ContextPanel,
    NavigationShell,
    PlayerBar,
    SharedUIComponents,
)
from musicplayer.ui.components.common import (
    _theme_mode,
)
from musicplayer.ui.pages import (
    DownloadsPage,
    HomePage,
    LibraryPage,
    PlaylistsPage,
    QueuePage,
    SearchPage,
    SettingsPage,
)
from musicplayer.ui.presentation import PresentationKind, presentation_kind
from musicplayer.ui.tasks import PageTasks
from musicplayer.ui.theme import accent_color, build_theme

logger = logging.getLogger(__name__)

_TERMINAL_DOWNLOAD_STATUSES = frozenset({"completed", "failed", "cancelled"})
_EMPTY_MEDIA_METADATA = ("", "", "", "")

__all__ = [
    "AppServices",
    "MusicPlayerApp",
    "main",
]


class MusicPlayerApp:
    """Application composition root for Melody's page and component modules."""

    content: ft.Container
    player: Any

    @property
    def views(self):
        # Release bundles contain only the presentation for their native target.
        # Keep the other package out of the import graph, including at startup.
        if (
            getattr(self, "presentation", PresentationKind.DESKTOP)
            is PresentationKind.MOBILE
        ):
            from musicplayer.ui import mobile

            return mobile
        from musicplayer.ui import desktop

        return desktop

    def __init__(self, page: ft.Page, services: AppServices | None = None) -> None:
        self.page = page
        services = services or AppServices.load()
        self._attach_services(services)
        self._create_task_runtime()
        self._create_playback(services.available_track_ids)
        self._create_components()
        self._initialize_state()
        self.shell = self._create_shell()
        self._configure_page()
        self.navigation._build_shell()
        if self._is_android_platform():
            self._queue_private_tracks_for_export()

    def _attach_services(self, services: AppServices) -> None:
        """Expose application services to the presentation controllers."""
        self.data_directory = services.directory
        self.store = services.store
        self.settings = services.store.settings
        self.manager = services.manager
        self.library = services.library
        self.providers = services.providers
        self.thumbnails = services.thumbnails
        self.downloads = services.downloads

    def _create_task_runtime(self) -> None:
        """Create the bounded executors owned by this page."""
        # Search, stream resolution, and imports share a bounded I/O pool that
        # exists only while at least one background operation is in flight.
        self.workers = LazyBoundedExecutor(
            max_workers=2,
            max_pending=2,
            thread_name_prefix="melody-io",
        )
        self.tasks = PageTasks(self.page, self.workers, self._show_error)
        self.persistence = PlaybackPersistence(
            self.store, lambda message: self.tasks.dispatch(self._show_error, message)
        )

    def _create_playback(self, available_track_ids: set[str]) -> None:
        """Wire the playback controller to its Flet/native backend."""
        self._system_media_key: tuple[str, ...] | None = None
        self._system_media_metadata = _EMPTY_MEDIA_METADATA
        self.file_picker = ft.FilePicker()
        self.page.services.append(self.file_picker)
        self.backend = ManagedAudioBackend(
            self.page, use_device_volume=self._is_mobile_platform()
        )
        self.playback = PlaybackController(
            self.manager,
            self.library,
            self.store,
            self.backend,
            persistence=self.persistence,
            available_track_ids=available_track_ids,
            on_change=self._playback_changed,
            on_error=self._show_error,
        )
        self.backend.bind(
            on_loaded=self.playback.on_loaded,
            on_position=self.playback.on_position,
            on_duration=self.playback.on_duration,
            on_playing=self.playback.on_playing,
            on_completed=self.playback.on_completed,
            on_track_changed=self.playback.on_track_changed,
            on_stopped=self.playback.on_stopped,
            on_error=self.playback.on_backend_error,
            on_media_action=self._media_action,
        )
        self.downloads.on_change = lambda record: self.tasks.dispatch(
            self._download_changed, record
        )

    def _create_components(self) -> None:
        """Create the feature controllers consumed by the active shell."""
        self.shared = SharedUIComponents(self)
        self.home_page = HomePage(self)
        self.search_page = SearchPage(self)
        self.library_page = LibraryPage(self)
        self.playlists_page = PlaylistsPage(self)
        self.queue_page = QueuePage(self)
        self.downloads_page = DownloadsPage(self)
        self.settings_page = SettingsPage(self)
        self.navigation = NavigationShell(self)
        self.player_bar = PlayerBar(self)
        self.context_panel = ContextPanel(self)

    def _initialize_state(self) -> None:
        """Initialize transient state that is not owned by a feature controller."""
        self._closing = False
        self._pending_music_exports: set[str] = set()
        self._private_export_sources: dict[str, Path] = {}
        self.selected_navigation = 0
        self.active_panel: str | None = None
        self.pending_download_actions: dict[str, tuple[str, str | None]] = {}
        self._download_play_requests: dict[str, int] = {}
        self._last_announced_track: str | None = None

    def _create_shell(self) -> Any:
        """Create only the presentation shell bundled for this target."""
        self.presentation = presentation_kind(
            self.page.platform, native_mobile=self._is_mobile_platform()
        )
        if self.presentation is PresentationKind.MOBILE:
            from musicplayer.ui.mobile.shell import MobileShell

            return MobileShell(self)

        from musicplayer.ui.desktop.shell import DesktopShell

        return DesktopShell(self)

    def _configure_page(self) -> None:
        self.page.title = "Melody — Music player"
        self.page.padding = 0
        self.page.spacing = 0
        self._reapply_accent()
        self.page.theme_mode = _theme_mode(self.settings.theme)
        # Window constraints are meaningful on desktop only. Applying the
        # desktop minimum size to an Android/iOS window makes the app render
        # beyond the device viewport.
        if not self._is_mobile_platform():
            self.page.window.width = 1540
            self.page.window.height = 960
            self.page.window.min_width = 1040
            self.page.window.min_height = 700
        self.page.on_keyboard_event = self._keyboard_event
        self.page.on_resize = self._page_resized
        self.page.on_app_lifecycle_state_change = self._app_lifecycle_changed
        self.page.on_close = self._close
        # Browser tabs disconnect without emitting the native window close
        # event. Use the same idempotent teardown path for both lifecycles.
        self.page.on_disconnect = self._close

    def _app_lifecycle_changed(self, event: ft.AppLifecycleStateChangeEvent) -> None:
        """Refresh native playback state after the page returns to the foreground."""
        foreground = event.state in (
            ft.AppLifecycleState.SHOW,
            ft.AppLifecycleState.RESUME,
        )
        self.backend.set_foreground(foreground)
        if not foreground:
            return
        self.backend.refresh_state()
        self.backend.invalidate_media_session()
        # Refresh the session immediately with the current controller state;
        # the native position query above will publish a precise correction as
        # soon as it completes.
        self._sync_system_media(refresh_metadata=False)

    def _playback_changed(self, change: str = "state") -> None:
        if change != "volume":
            self._sync_system_media(refresh_metadata=change == "track")
        if change == "track" and self._private_export_sources:
            self.tasks.start(self._cleanup_exported_sources)
        if change == "progress":
            self.player_bar._refresh_player_progress()
            return
        if change == "volume":
            self.player_bar._refresh_player_volume()
            return
        self.player_bar._refresh_player()
        current = self.playback.current_track_id or (
            f"stream:{self.playback.external_title}"
            if self.playback.external_title
            else None
        )
        if (
            self.settings.notifications
            and self.playback.playing
            and current
            and current != self._last_announced_track
        ):
            self._last_announced_track = current
            self._show_message(f"Now playing: {self.player.title.value}")
        if self.active_panel == "queue" and change in {"queue", "track"}:
            self.context_panel._refresh_context_panel()

    def _sync_system_media(self, *, refresh_metadata: bool = True) -> None:
        """Keep native lock-screen/notification controls aligned with playback."""
        media_key = self._system_media_identity()
        if refresh_metadata or media_key != self._system_media_key:
            self._system_media_key = media_key
            self._system_media_metadata = self._resolve_system_media_metadata()
        title, artist, album, artwork_uri = self._system_media_metadata

        has_media = bool(title) and self.playback.media_session_active
        self.backend.sync_media_session(
            title=title if has_media else "",
            artist=artist,
            album=album,
            artwork_uri=artwork_uri,
            duration_ms=self.playback.duration_ms,
            position_ms=self.playback.position_ms,
            playing=self.playback.playing,
            loading=self.playback.snapshot.loading,
            has_next=has_media
            and self.playback.queue.peek_next(automatic=True) is not None,
            has_previous=has_media,
            repeat_mode=self.playback.queue.repeat.value,
            shuffle=self.playback.queue.shuffle,
            # A paused Android MediaSessionService is otherwise allowed to
            # disappear with its notification when the app task is removed.
            # Preserve it while Melody still owns a resumable queue; explicit
            # Stop clears has_media and remains the teardown boundary.
            keep_alive=has_media and bool(getattr(self.playback.queue, "items", ())),
        )

    def _system_media_identity(self) -> tuple[str, ...] | None:
        """Return the fields whose changes require a metadata refresh."""
        if self.playback.external_title:
            return (
                "stream",
                self.playback.external_title,
                self.playback.external_uploader,
                self.playback.external_thumbnail,
            )
        if self.playback.current_track_id:
            return ("track", self.playback.current_track_id)
        return None

    def _resolve_system_media_metadata(self) -> tuple[str, str, str, str]:
        """Resolve display metadata only when the active media identity changes."""
        if self.playback.external_title:
            return (
                self.playback.external_title,
                self.playback.external_uploader,
                "",
                self._artwork_uri(self.playback.external_thumbnail),
            )
        if not self.playback.current_track_id:
            return _EMPTY_MEDIA_METADATA

        try:
            track = self.manager.get_track(self.playback.current_track_id)
            details = self.library.details(self.playback.current_track_id)
        except KeyError, OSError, ValueError:
            logger.debug("Could not resolve system media metadata", exc_info=True)
            return _EMPTY_MEDIA_METADATA

        return (
            track.title or Path(track.filename).stem,
            details.uploader,
            # Melody does not currently persist album tags. The source name is
            # still useful context without pretending it is an album title.
            details.source_name,
            self._artwork_uri(details.thumbnail),
        )

    def _artwork_uri(self, source: str) -> str:
        cache = getattr(self, "thumbnails", None)
        return cache.artwork_uri(source) if cache is not None else source

    def _media_action(self, action: str, seek_position_ms: int | None) -> None:
        """Apply an idempotent command received from native media controls."""
        command = action.casefold()
        if command == "play":
            if not self.playback.playing:
                self.playback.toggle()
        elif command == "pause":
            if self.playback.playing:
                self.playback.toggle()
        elif command == "stop":
            self.playback.stop()
        elif command == "skiptonext":
            self.playback.next()
        elif command == "skiptoprevious":
            self.playback.previous()
        elif command == "seekto" and seek_position_ms is not None:
            self.playback.seek(seek_position_ms)
        elif command == "rewind":
            self.playback.seek(self.playback.position_ms - 10_000)
        elif command == "fastforward":
            self.playback.seek(self.playback.position_ms + 10_000)

    def _download_changed(self, record: DownloadRecord) -> None:
        self.context_panel._refresh_download_badge()
        if record.status == "completed" and self._is_android_platform():
            self._pending_music_exports.update(record.track_ids)
            self.tasks.start(self._drain_music_exports)

        if record.status in _TERMINAL_DOWNLOAD_STATUSES:
            self._finish_pending_download_action(record)
            self._refresh_after_download()
        if self.active_panel == "downloads":
            self.context_panel._refresh_context_panel()

    def _finish_pending_download_action(self, record: DownloadRecord) -> None:
        """Apply a queued UI action once its download reaches a terminal state."""
        pending = self.pending_download_actions.get(record.id)
        if pending is None:
            return

        self.pending_download_actions.pop(record.id, None)
        generation = self._download_play_requests.pop(record.id, None)
        relevant = pending[0] != "play" or (
            generation is not None and self.playback.is_current_request(generation)
        )
        if not relevant:
            return
        if record.status == "completed":
            self.search_page._apply_track_action(record.track_ids, *pending)
            return
        self._show_error(f"Couldn’t finish the requested action for {record.title}.")

    def _refresh_after_download(self) -> None:
        """Refresh feature views affected by a completed download operation."""
        if self.playlists_page.playlist_import_session is not None:
            self.playlists_page.notify_download_changed()
        if self.selected_navigation == 2 and hasattr(self.library_page, "track_list"):
            self.library_page._refresh_library_list()

    def _keyboard_event(self, event: ft.KeyboardEvent) -> None:
        key = event.key.casefold()
        if key in {"media play pause", "mediaplaypause"}:
            self.playback.toggle()
        elif key in {"media track next", "medianexttrack"}:
            self.playback.next()
        elif key in {"media track previous", "mediaprevioustrack"}:
            self.playback.previous()
        else:
            self.shell.keyboard(event)

    async def _page_resized(self, event: Any) -> None:
        self.shell.resize(
            float(getattr(event, "width", 0) or self.page.width or 1540),
            float(getattr(event, "height", 0) or self.page.height or 960),
        )

    def _is_mobile_platform(self) -> bool:
        if self._page_platform_contains("android", "ios"):
            return True
        return self._runtime_is_android()

    def _is_android_platform(self) -> bool:
        return self._page_platform_contains("android") or self._runtime_is_android()

    def _page_platform_contains(self, *names: str) -> bool:
        platform = str(getattr(self.page, "platform", "")).casefold()
        return any(name in platform for name in names)

    @staticmethod
    def _runtime_is_android() -> bool:
        try:
            return current_platform() == "android"
        except UnsupportedPlatformError:
            return False

    def _queue_private_tracks_for_export(self) -> None:
        """Resume Android exports interrupted before their private copy was removed."""
        private_root = Path(self.data_directory).resolve()
        for track in self.manager.list_tracks():
            try:
                path = self.manager.track_path(track.id).resolve()
            except OSError, KeyError, ValueError:
                continue
            if path.is_relative_to(private_root) and path.is_file():
                self._pending_music_exports.add(str(track.id))
        if self._pending_music_exports:
            self.tasks.start(self._drain_music_exports)

    async def _drain_music_exports(self) -> None:
        """Publish staged Android audio and make the public copy canonical."""
        failed = False
        private_root = Path(self.data_directory).resolve()
        while self._pending_music_exports:
            track_id = self._pending_music_exports.pop()
            try:
                source = self.manager.track_path(track_id).resolve()
                if not source.is_relative_to(private_root) or not source.is_file():
                    continue
                published = await self.backend.publish_to_music(source)
                old_source = await self.tasks.io(
                    self._adopt_published_track,
                    track_id,
                    source,
                    published,
                )
                if old_source is None:
                    continue
                if self.playback.current_track_id == track_id:
                    self._private_export_sources[track_id] = old_source
                else:
                    await self.tasks.io(self._remove_unreferenced_file, old_source)
            except asyncio.CancelledError:
                self._pending_music_exports.add(track_id)
                raise
            except Exception:
                failed = True
                logger.exception(
                    "Could not publish track to the Android Music folder: track_id=%s",
                    track_id,
                )
        if failed:
            self._show_error(
                "A downloaded track could not be moved to Music/Melody. "
                "Melody will retry next time it starts."
            )

    def _adopt_published_track(
        self, track_id: str, source: Path, published: Path
    ) -> Path | None:
        """Atomically repoint library metadata before removing private audio."""
        public_root = public_music_directory().resolve()
        destination = published.resolve()
        if not destination.is_relative_to(public_root):
            raise ValueError("Android returned a file outside Music/Melody")
        self.manager.replace_track_file(track_id, destination)
        return source if source != destination else None

    async def _cleanup_exported_sources(self) -> None:
        current = self.playback.current_track_id
        ready = {
            track_id: path
            for track_id, path in self._private_export_sources.items()
            if track_id != current
        }
        for track_id, path in ready.items():
            await self.tasks.io(self._remove_unreferenced_file, path)
            self._private_export_sources.pop(track_id, None)

    def _remove_unreferenced_file(self, path: Path) -> None:
        if not self.manager.is_path_referenced(path):
            path.unlink(missing_ok=True)

    def _accent_hex(self) -> str:
        """Resolve the current accent-color hex from settings."""
        return accent_color(self.settings_page.accent_draft)

    def _reapply_accent(self) -> None:
        self.page.theme = build_theme(self._accent_hex())
        self.page.dark_theme = build_theme(self._accent_hex())

    def _close(self, _: Any) -> None:
        if self._closing:
            return
        self._closing = True
        self.playlists_page._cancel_playlist_import_retry()
        # Reject native RPCs before controller cleanup can cancel an in-flight
        # source. This avoids scheduling cleanup against a disposed session.
        self.backend.close()
        self.playback.close()
        for path in tuple(self._private_export_sources.values()):
            try:
                self._remove_unreferenced_file(path)
            except OSError:
                logger.debug("Could not remove exported staging audio", exc_info=True)
        self.tasks.close()
        self.persistence.close(wait=True)
        # Closing a window must not wait for a slow network read or postprocess.
        # Running jobs observe cancellation at their next yt-dlp callback.
        self.downloads.shutdown(wait=False)
        self.workers.shutdown(wait=True, cancel_pending=True)

    def _submit_background(
        self, operation: Callable[..., object], /, *args: object
    ) -> bool:
        """Submit bounded blocking I/O without allocating workers while idle."""
        try:
            self.workers.submit(operation, *args)
        except WorkerQueueFull as error:
            self._show_error(str(error))
            return False
        except RuntimeError:
            logger.debug("Background work rejected during application shutdown")
            return False
        return True

    def _show_message(self, message: str, *, error: bool = False) -> None:
        try:
            self.page.show_dialog(
                ft.SnackBar(
                    ft.Text(message),
                    show_close_icon=True,
                    bgcolor=ft.Colors.ERROR_CONTAINER if error else None,
                )
            )
        except Exception:
            logger.debug("Could not show notification", exc_info=True)

    def _show_error(self, message: str) -> None:
        self._show_message(public_error_message(message), error=True)


@dataclass
class AppServices:
    directory: Path
    store: ApplicationStore
    manager: MusicManager
    library: LibraryService
    providers: ProviderRegistry
    thumbnails: ThumbnailCache
    downloads: DownloadCoordinator
    available_track_ids: set[str]

    @classmethod
    def load(cls) -> AppServices:
        """Load only state required to render and resume the local application."""
        directory = application_data_directory()
        store = ApplicationStore(directory / "state.json")
        settings = store.settings
        platform_name = current_platform()
        manager = MusicManager(
            directory / "library.mmdb",
            settings.download_directory,
            additional_music_folders=_public_music_folders(platform_name),
        )
        library = LibraryService(manager, store)
        providers = ProviderRegistry(settings=settings)
        thumbnails = ThumbnailCache(directory / "thumbnails")
        downloads = DownloadCoordinator(manager, store, settings, thumbnails=thumbnails)
        return cls(
            directory=directory,
            store=store,
            manager=manager,
            library=library,
            providers=providers,
            thumbnails=thumbnails,
            downloads=downloads,
            available_track_ids=_available_resume_tracks(
                manager,
                store,
                resume_session=settings.resume_session,
            ),
        )


def _public_music_folders(platform_name: str) -> tuple[Path, ...]:
    if platform_name != "android":
        return ()
    return (public_music_directory(platform_name=platform_name),)


def _available_resume_tracks(
    manager: MusicManager,
    store: ApplicationStore,
    *,
    resume_session: bool,
) -> set[str]:
    """Check only queue entries needed to restore playback at startup."""
    # Scanning every file in a large library made startup perform thousands of
    # unnecessary filesystem calls even when the persisted queue was short.
    playback = store.get("playback", {}) if resume_session else {}
    queue = playback.get("queue", []) if isinstance(playback, dict) else []
    queued_ids = {
        track_id
        for track_id in queue
        if isinstance(track_id, str) and manager.has_track(track_id)
    }
    return {
        track_id for track_id in queued_ids if manager.track_path(track_id).is_file()
    }


async def main(page: ft.Page) -> None:
    page.title = "Melody — Loading library"
    loading = ft.Column(
        [ft.ProgressRing(), ft.Text("Loading your library…")],
        alignment=ft.MainAxisAlignment.CENTER,
        horizontal_alignment=ft.CrossAxisAlignment.CENTER,
        expand=True,
    )
    page.add(loading)
    try:
        services = await asyncio.to_thread(AppServices.load)
        page.controls.clear()
        MusicPlayerApp(page, services)
    except Exception:  # noqa: BLE001 - final UI boundary must stay user-safe
        logger.error("Melody failed to start")
        page.title = "Melody — Startup error"
        page.padding = 32
        page.add(
            ft.Column(
                [
                    ft.Icon(
                        ft.Icons.ERROR_OUTLINE_ROUNDED, size=52, color=ft.Colors.ERROR
                    ),
                    ft.Text(
                        "Melody couldn’t start", size=28, weight=ft.FontWeight.BOLD
                    ),
                    ft.Text(
                        "Restart Melody and check that the configured music folder "
                        "and app data location are available."
                    ),
                ],
                spacing=14,
            )
        )
