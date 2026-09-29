import asyncio
import logging
from collections.abc import Awaitable, Callable
from concurrent.futures import Future
from pathlib import Path
from typing import Any, cast

import flet as ft
from flet_background_audio import (
    AudioSource,
    BackgroundAudioSession,
    ManagedAudio,
    ManagedAudioDurationChangeEvent,
    ManagedAudioPositionChangeEvent,
    ManagedAudioStateChangeEvent,
    ManagedAudioTrackChangeEvent,
    MediaSessionActionEvent,
    SharedAudioStorage,
)

logger = logging.getLogger(__name__)


class ManagedAudioBackend:
    """Lifecycle-safe adapter around the package-owned managed track player.

    One command bridge stays mounted for the page lifetime. Candidate sources prepare
    beside the active decoder and swap only after native readiness. Transport
    and source RPCs use separate locks so pause remains responsive during a
    handoff, and every operation is bounded at this final player boundary.
    """

    _OPERATION_TIMEOUT_SECONDS = 12

    def __init__(self, page: ft.Page, *, use_device_volume: bool = False) -> None:
        self.page = page
        self._web = bool(getattr(page, "web", False))
        self._use_device_volume = use_device_volume
        self.audio = ManagedAudio(volume=1.0)
        self.on_position: Callable[[int], None] | None = None
        self.on_loaded: Callable[[], None] | None = None
        self.on_duration: Callable[[int], None] | None = None
        self.on_playing: Callable[[bool], None] | None = None
        self.on_completed: Callable[[], None] | None = None
        self.on_track_changed: Callable[[str, int], None] | None = None
        self.on_stopped: Callable[[], None] | None = None
        self.on_error: Callable[[str], None] | None = None
        self.on_media_action: Callable[[str, int | None], None] | None = None
        self.on_native_reattach: Callable[[dict[str, Any]], None] | None = None
        self._volume = 1.0
        self._generation = 0
        self._completed_generation = -1
        self._loaded = False
        self._has_active_source = False
        self._closing = False
        self._service_failed = False
        self._pending_play_position: int | None = None
        self._pending_seek_position: int | None = None
        self._load_watchdog: Future[Any] | None = None
        self._operation_lock = asyncio.Lock()
        self._transport_lock = asyncio.Lock()
        self._operations: set[Future[Any]] = set()
        self._media_operation_lock = asyncio.Lock()
        self._media_generation = 0
        self._media_snapshot: tuple[object, ...] | None = None
        self._media_pending_snapshot: tuple[object, ...] | None = None
        self._media_session_active = False
        self._media_reattach_pending = False
        self.media_session: BackgroundAudioSession | None = None
        self.shared_storage: SharedAudioStorage | None = None
        if not self._web:
            self.media_session = BackgroundAudioSession(on_action=self._media_action)
            self.page.services.append(self.media_session)
            self.shared_storage = SharedAudioStorage()
            self.page.services.append(self.shared_storage)
        self._bind_audio_events(self.audio)
        self.page.services.append(self.audio)

    def _bind_audio_events(self, audio: ManagedAudio) -> None:
        """Bind generation-scoped events from the package-owned player."""
        audio.on_loaded = lambda event: self._loaded_event(event.generation)
        audio.on_position_change = lambda event: self._position_changed(
            event, event.generation
        )
        audio.on_duration_change = lambda event: self._duration_changed(
            event, event.generation
        )
        audio.on_state_change = lambda event: self._state_changed(
            event, event.generation
        )
        audio.on_track_change = self._track_changed
        audio.on_error = lambda event: self._source_error(
            event.message, event.generation
        )

    async def publish_to_music(self, source: str | Path) -> Path:
        """Copy one staged Android track into the public Music collection."""
        if self._closing or self.shared_storage is None:
            raise RuntimeError("The audio service is closing")
        return await asyncio.wait_for(
            self.shared_storage.publish(source),
            timeout=self._OPERATION_TIMEOUT_SECONDS,
        )

    def bind(
        self,
        *,
        on_position: Callable[[int], None],
        on_loaded: Callable[[], None] | None = None,
        on_duration: Callable[[int], None],
        on_playing: Callable[[bool], None],
        on_completed: Callable[[], None],
        on_track_changed: Callable[[str, int], None] | None = None,
        on_stopped: Callable[[], None] | None = None,
        on_error: Callable[[str], None] | None = None,
        on_media_action: Callable[[str, int | None], None] | None = None,
        on_native_reattach: Callable[[dict[str, Any]], None] | None = None,
    ) -> None:
        self.on_position = on_position
        self.on_loaded = on_loaded
        self.on_duration = on_duration
        self.on_playing = on_playing
        self.on_completed = on_completed
        self.on_track_changed = on_track_changed
        self.on_stopped = on_stopped
        self.on_error = on_error
        self.on_media_action = on_media_action
        self.on_native_reattach = on_native_reattach

    async def reattach_native_state(self) -> None:
        """Adopt playback retained by the native runtime after a page remount."""
        if self._closing:
            return
        state: dict[str, Any] | None = None
        for attempt in range(3):
            try:
                state = await asyncio.wait_for(
                    self.audio.get_playback_state(),
                    timeout=self._OPERATION_TIMEOUT_SECONDS,
                )
                break
            except Exception:
                if attempt == 2 or self._closing:
                    logger.debug(
                        "Native playback reattachment is unavailable", exc_info=True
                    )
                    return
                await asyncio.sleep(0.2)
        if state is None:
            return
        if self._closing or not state.get("source"):
            return
        self._generation = int(state.get("generation") or 0)
        self._loaded = True
        self._has_active_source = True
        self._media_reattach_pending = True
        if self.on_native_reattach:
            self.on_native_reattach(state)

    def sync_media_session(
        self,
        *,
        title: str,
        artist: str = "",
        album: str = "",
        artwork_uri: str = "",
        auto_focal_point_live_notifications: bool = False,
        duration_ms: int = 0,
        position_ms: int = 0,
        playing: bool = False,
        loading: bool = False,
        has_next: bool = True,
        has_previous: bool = True,
        repeat_mode: str = "off",
        can_repeat: bool = False,
        can_shuffle: bool = False,
        can_favorite: bool = False,
        favorite: bool = False,
        notification_action_pair: str = "shuffle_favorite",
        keep_alive: bool = False,
    ) -> None:
        """Publish a coherent snapshot to native system controls.

        Flet sends one position event per second. Publish each event to keep
        the media notification current while the app is visible or hidden.
        """
        clean_title = title.strip()
        duration = max(0, int(duration_ms))
        position = max(0, int(position_ms))
        is_playing = bool(playing)
        is_loading = bool(loading)
        can_skip_next = bool(has_next)
        can_skip_previous = bool(has_previous)
        can_cycle_repeat = bool(can_repeat)
        can_shuffle_upcoming = bool(can_shuffle)
        can_toggle_favorite = bool(can_favorite)
        is_favorite = bool(favorite)
        should_keep_alive = bool(keep_alive)
        position_marker = position
        snapshot: tuple[object, ...] = (
            clean_title,
            artist,
            album,
            artwork_uri,
            bool(auto_focal_point_live_notifications),
            duration,
            position_marker,
            is_playing,
            is_loading,
            can_skip_next,
            can_skip_previous,
            repeat_mode,
            can_cycle_repeat,
            can_shuffle_upcoming,
            can_toggle_favorite,
            is_favorite,
            notification_action_pair,
            should_keep_alive,
        )
        if (
            (snapshot == self._media_snapshot and self._media_pending_snapshot is None)
            or snapshot == self._media_pending_snapshot
            or self._closing
            or self._service_failed
            or self.media_session is None
        ):
            return
        # Keep the last successfully published snapshot separate from the
        # latest queued one. A method-channel failure must remain retryable;
        # recording it as already synchronized would permanently strand stale
        # lock-screen controls until another playback event happens.
        self._media_pending_snapshot = snapshot
        self._media_generation += 1
        generation = self._media_generation
        payload = {
            "title": clean_title,
            "artist": artist,
            "album": album,
            "artwork_uri": artwork_uri,
            "auto_focal_point_live_notifications": bool(
                auto_focal_point_live_notifications
            ),
            "duration_ms": duration,
            "position_ms": position,
            "playing": is_playing,
            "loading": is_loading,
            "has_next": can_skip_next,
            "has_previous": can_skip_previous,
            "repeat_mode": repeat_mode,
            "can_repeat": can_cycle_repeat,
            "can_shuffle": can_shuffle_upcoming,
            "can_favorite": can_toggle_favorite,
            "favorite": is_favorite,
            "notification_action_pair": notification_action_pair,
            "keep_alive": should_keep_alive,
            "reattach": self._media_reattach_pending,
        }
        try:
            self.page.run_task(
                self._run_media_sync,
                generation,
                cast(Any, payload),
                snapshot,
            )
        except Exception:
            if (
                generation == self._media_generation
                and self._media_pending_snapshot == snapshot
            ):
                self._media_pending_snapshot = None
            logger.debug(
                "Media-session update skipped after session disposal", exc_info=True
            )

    def invalidate_media_session(self) -> None:
        """Force the next snapshot to reattach after an app lifecycle resume."""
        if self._closing:
            return
        self._media_generation += 1
        self._media_snapshot = None
        self._media_pending_snapshot = None
        self._media_reattach_pending = True

    def set_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
        autoplay: bool = False,
        position_ms: int = 0,
    ) -> None:
        """Install and prepare the native authoritative playback queue.

        The selected source is prepared by the native engine. ``play()`` remains
        a separate intent so a user can pause while preparation is in flight.
        Automatic completion and system transport actions no longer return to
        Python before the next decoder is selected.
        """
        if self._closing:
            return
        self._service_failed = False
        self._cancel_load_watchdog()
        self._next_python_generation()
        self._cancel_operations()
        generation = self._generation
        self._loaded = False
        self._pending_play_position = None
        self._pending_seek_position = None
        self._schedule(
            self.audio.set_queue,
            items,
            int(current_index),
            generation,
            repeat_mode,
            autoplay,
            max(0, int(position_ms)),
            generation=generation,
        )
        try:
            self._load_watchdog = self.page.run_task(self._watch_load, generation)
        except Exception:  # noqa: BLE001 - Flet may reject after disposal
            self._fail_service(
                generation,
                "The native playback queue did not respond.",
            )

    def update_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
    ) -> None:
        """Update native queue policy without interrupting the active decoder."""
        if self._closing or self._service_failed:
            return
        self._schedule(
            self.audio.update_queue,
            items,
            int(current_index),
            repeat_mode,
            generation=self._generation,
        )

    def load(
        self, source: AudioSource, *, autoplay: bool = False, position_ms: int = 0
    ) -> None:
        if self._closing:
            return
        # A new explicit source selection is the retry boundary after a
        # disconnected or failed player service.
        self._service_failed = False
        self._cancel_load_watchdog()
        self._next_python_generation()
        self._cancel_operations()
        generation = self._generation
        self._loaded = False
        self._pending_play_position = None
        self._pending_seek_position = None

        self._schedule(
            self.audio.load_source,
            source,
            generation,
            autoplay,
            max(0, int(position_ms)),
            generation=generation,
        )
        try:
            self._load_watchdog = self.page.run_task(self._watch_load, generation)
        except Exception:  # noqa: BLE001 - Flet may reject after disposal
            self._fail_service(
                generation,
                "The audio player did not respond. The playback service may "
                "have disconnected.",
            )

    def play(self, position_ms: int = 0) -> None:
        position = max(0, int(position_ms))
        if not self._loaded:
            self._pending_play_position = position
            return
        self._schedule_transport(self.audio.play, position, generation=self._generation)

    def pause(self) -> None:
        if not self._loaded:
            self._pending_play_position = None
            self._schedule_transport(self.audio.pause, generation=self._generation)
            return
        self._schedule_transport(self.audio.pause, generation=self._generation)

    def resume(self) -> None:
        if not self._loaded:
            self._pending_play_position = self._pending_seek_position or 0
            self._schedule_transport(self.audio.resume, generation=self._generation)
            return
        self._schedule_transport(self.audio.resume, generation=self._generation)

    def seek(self, position_ms: int) -> None:
        position = max(0, int(position_ms))
        if not self._loaded:
            self._pending_seek_position = position
            if self._pending_play_position is not None:
                self._pending_play_position = position
            return
        self._schedule_transport(self.audio.seek, position, generation=self._generation)

    def close(self) -> None:
        # The native service is disposed with the page. Starting an RPC during
        # on_close races the session teardown and can itself produce
        # "Session closed" errors, so shutdown is deliberately local-only.
        self._closing = True
        self._service_failed = True
        self._next_python_generation()
        self._media_generation += 1
        self._media_pending_snapshot = None
        self._cancel_load_watchdog()
        self._cancel_operations()
        self._pending_play_position = None
        self._pending_seek_position = None

    def refresh_state(self) -> None:
        """Reconcile the Python UI with the native player after app resume.

        Querying the native player when the page becomes visible corrects any
        position drift accumulated while the page was suspended.
        """
        if self._closing or not self._loaded:
            return
        try:
            self.page.run_task(self._refresh_state, self._generation)
        except Exception:
            logger.debug("Audio state refresh could not be scheduled", exc_info=True)

    async def _refresh_state(self, generation: int) -> None:
        if self._closing or generation != self._generation:
            return
        try:
            async with self._transport_lock:
                if self._closing or generation != self._generation:
                    return
                state = await asyncio.wait_for(
                    self.audio.get_playback_state(),
                    timeout=self._OPERATION_TIMEOUT_SECONDS,
                )
                position = state.get("position_ms")
                duration = state.get("duration_ms")
                playing = state.get("playing")
        except asyncio.CancelledError:
            return
        except Exception:
            # Resume reconciliation is best effort. The normal event stream and
            # the native session remain usable if a platform channel is briefly
            # unavailable while the app is being restored.
            logger.debug("Native audio state refresh failed", exc_info=True)
            return

        if self._closing or generation != self._generation:
            return
        if position is not None and self.on_position:
            self.on_position(int(position))
        if duration is not None and self.on_duration:
            self.on_duration(int(duration))
        if playing is not None and self.on_playing:
            self.on_playing(bool(playing))

    def set_volume(self, value: float) -> None:
        gain = max(0.0, min(1.0, value))
        # Phones use system media volume. Preserve the shared app-volume setting
        # for desktop, but do not attenuate it behind an unavailable phone slider.
        self._volume = float(gain > 0) if self._use_device_volume else gain
        self.audio.volume = self._volume
        try:
            self.page.update(cast(ft.Control, self.audio))
        except Exception:
            logger.debug(
                "Audio volume update deferred until service mount", exc_info=True
            )

    def _loaded_event(self, generation: int) -> None:
        if generation != self._generation or self._closing:
            return
        self._loaded = True
        self._has_active_source = True
        self._cancel_load_watchdog()
        if self.on_loaded:
            self.on_loaded()
        pending_play = self._pending_play_position
        pending_seek = self._pending_seek_position
        self._pending_play_position = None
        self._pending_seek_position = None
        if pending_play is not None:
            self._schedule_transport(
                self.audio.play, pending_play, generation=generation
            )
        elif pending_seek is not None:
            self._schedule_transport(
                self.audio.seek, pending_seek, generation=generation
            )

    def _schedule(
        self,
        operation: Callable[..., Awaitable[Any]],
        *args: Any,
        generation: int,
    ) -> None:
        if self._closing or generation != self._generation:
            return
        try:
            future = self.page.run_task(
                self._run_operation, operation, args, generation
            )
            self._operations.add(future)
            future.add_done_callback(self._operations.discard)
        except Exception:
            logger.exception("Audio operation could not be scheduled")
            self._fail_service(
                generation,
                "The audio player did not respond. The playback service may "
                "have disconnected.",
            )

    def _schedule_best_effort(
        self, operation: Callable[..., Awaitable[Any]], *args: Any
    ) -> None:
        """Run cleanup RPCs without turning cleanup failure into recovery."""
        if self._closing or self._service_failed:
            return
        try:
            future = self.page.run_task(self._run_best_effort, operation, args)
            self._operations.add(future)
            future.add_done_callback(self._operations.discard)
        except Exception:
            logger.debug("Audio cleanup could not be scheduled", exc_info=True)

    async def _run_best_effort(
        self,
        operation: Callable[..., Awaitable[Any]],
        args: tuple[Any, ...],
    ) -> None:
        try:
            await asyncio.wait_for(
                operation(*args), timeout=self._OPERATION_TIMEOUT_SECONDS
            )
        except asyncio.CancelledError:
            return
        except Exception:
            logger.debug("Audio cleanup operation failed", exc_info=True)

    def _schedule_transport(
        self,
        operation: Callable[..., Awaitable[Any]],
        *args: Any,
        generation: int,
    ) -> None:
        if self._closing or generation != self._generation:
            return
        try:
            future = self.page.run_task(
                self._run_transport_operation, operation, args, generation
            )
            self._operations.add(future)
            future.add_done_callback(self._operations.discard)
        except Exception:
            logger.exception("Audio transport operation could not be scheduled")
            self._report_error(
                "The audio player did not respond. The playback service may "
                "have disconnected."
            )

    async def _run_transport_operation(
        self,
        operation: Callable[..., Awaitable[Any]],
        args: tuple[Any, ...],
        generation: int,
    ) -> None:
        if self._closing or generation != self._generation:
            return
        try:
            async with self._transport_lock:
                if self._closing or generation != self._generation:
                    return
                await asyncio.wait_for(
                    operation(*args), timeout=self._OPERATION_TIMEOUT_SECONDS
                )
        except asyncio.CancelledError:
            return
        except Exception:
            logger.exception("Audio transport operation failed")
            self._fail_service(
                generation,
                "The audio player did not respond. The track may be unsupported or "
                "the playback service may have disconnected.",
            )

    async def _run_operation(
        self,
        operation: Callable[..., Awaitable[Any]],
        args: tuple[Any, ...],
        generation: int,
    ) -> None:
        if self._closing or generation != self._generation:
            return
        try:
            async with self._operation_lock:
                if self._closing or generation != self._generation:
                    return
                await asyncio.wait_for(
                    operation(*args), timeout=self._OPERATION_TIMEOUT_SECONDS
                )
        except asyncio.CancelledError:
            return
        except Exception:
            # This coroutine is the final boundary around Flet/native RPCs.
            # Extension and method-channel failures are not restricted to the
            # built-in timeout/OSError hierarchy.
            logger.exception("Audio operation failed")
            self._fail_service(
                generation,
                "The audio player did not respond. The track may be unsupported or "
                "the playback service may have disconnected.",
            )

    async def _watch_load(self, generation: int) -> None:
        await asyncio.sleep(self._OPERATION_TIMEOUT_SECONDS)
        if generation == self._generation and not self._loaded and not self._closing:
            if self.on_playing:
                self.on_playing(False)
            self._fail_service(
                generation,
                "The track could not be loaded by the audio service. The file may be "
                "corrupted or encoded in an unsupported format.",
            )

    def _cancel_load_watchdog(self) -> None:
        watchdog = self._load_watchdog
        self._load_watchdog = None
        if watchdog is not None:
            watchdog.cancel()

    def _next_python_generation(self) -> None:
        # Native queue transitions use odd generations. Explicit Python
        # requests use even ones, including after adopting a native track.
        self._generation = (self._generation + 2) & ~1

    def _cancel_operations(self) -> None:
        for future in tuple(self._operations):
            future.cancel()
        self._operations.clear()
        # Obsolete RPCs cannot hold the next player's transport lock hostage.
        self._operation_lock = asyncio.Lock()
        self._transport_lock = asyncio.Lock()

    def cancel_load(self) -> None:
        """Supersede native preparation while leaving the active source intact."""
        if self._closing:
            return
        self._next_python_generation()
        self._loaded = self._has_active_source
        self._pending_play_position = None
        self._pending_seek_position = None
        self._cancel_load_watchdog()
        self._cancel_operations()
        if self._service_failed:
            return
        self._schedule_best_effort(self.audio.cancel_load)

    def _source_error(self, message: str, generation: int) -> None:
        if generation == self._generation and not self._closing:
            self._cancel_load_watchdog()
            self._report_error(message)

    def discard_source(self) -> None:
        """Invalidate callbacks and release native decoders without unmounting."""
        self._next_python_generation()
        self._loaded = False
        self._has_active_source = False
        self._pending_play_position = self._pending_seek_position = None
        self._cancel_load_watchdog()
        self._cancel_operations()
        if self._closing or self._service_failed:
            return
        self._schedule_best_effort(self.audio.clear_source)

    async def _run_media_sync(
        self,
        generation: int,
        payload: dict[str, object],
        snapshot: tuple[object, ...],
    ) -> None:
        if self._closing or generation != self._media_generation:
            return
        media_session = self.media_session
        if media_session is None:
            return
        try:
            async with self._media_operation_lock:
                if self._closing or generation != self._media_generation:
                    return
                if payload["title"]:
                    # Activation happens inside the native sync call. Mark the
                    # session as potentially active before entering it so a
                    # partial platform-channel failure is still followed by a
                    # best-effort deactivate when the track is cleared.
                    self._media_session_active = True
                    await asyncio.wait_for(
                        media_session.sync(**cast(Any, payload)),
                        timeout=self._OPERATION_TIMEOUT_SECONDS,
                    )
                elif self._media_session_active:
                    await asyncio.wait_for(
                        media_session.deactivate(),
                        timeout=self._OPERATION_TIMEOUT_SECONDS,
                    )
                    self._media_session_active = False
                # Commit only after the native operation has completed. This is
                # the success marker used to coalesce future progress updates.
                if generation == self._media_generation:
                    self._media_snapshot = snapshot
                    if payload.get("reattach"):
                        self._media_reattach_pending = False
                    if self._media_pending_snapshot == snapshot:
                        self._media_pending_snapshot = None
        except asyncio.CancelledError:
            return
        except Exception:
            if (
                generation == self._media_generation
                and self._media_pending_snapshot == snapshot
            ):
                self._media_pending_snapshot = None
            # System controls are an enhancement; their failure must never stop
            # the actual audio path or surface a misleading playback error.
            logger.warning("Media-session synchronization failed", exc_info=True)

    def _report_error(self, message: str) -> None:
        # Every failure must reach the controller so its optimistic loaded and
        # playing flags can be repaired. User-notification coalescing belongs
        # above this transport boundary; suppressing this callback used to
        # leave a second failed source falsely marked as playable.
        if self.on_error:
            self.on_error(message)

    def _fail_service(self, generation: int, message: str) -> None:
        """Report one terminal failure for a source generation.

        Recovery callbacks discard native state. Without this latch, a failed
        discard RPC reports another playback failure and recursively schedules
        more cleanup after a page or method channel has disconnected.
        """
        if self._closing or generation != self._generation or self._service_failed:
            return
        self._service_failed = True
        self._loaded = False
        self._has_active_source = False
        self._cancel_load_watchdog()
        self._report_error(message)

    def _position_changed(
        self, event: ManagedAudioPositionChangeEvent, generation: int
    ) -> None:
        if generation == self._generation and self.on_position:
            self.on_position(event.position)

    def _duration_changed(
        self, event: ManagedAudioDurationChangeEvent, generation: int
    ) -> None:
        if generation == self._generation and self.on_duration:
            duration = event.duration
            milliseconds = getattr(duration, "in_milliseconds", duration)
            self.on_duration(int(milliseconds))

    def _state_changed(
        self, event: ManagedAudioStateChangeEvent, generation: int
    ) -> None:
        if generation != self._generation:
            return
        state = getattr(event.state, "value", event.state)
        if state == "completed":
            if self._completed_generation == generation:
                return
            self._completed_generation = generation
            if self.on_completed:
                self.on_completed()
        else:
            if state == "stopped" and self.on_stopped:
                self._loaded = False
                self._has_active_source = False
                self.on_stopped()
                return
            if state == "playing":
                # A source may be replayed without a reload (for example after
                # reaching the end of a one-track queue). Once native playback
                # actually restarts, allow that generation to complete again.
                self._completed_generation = -1
            if self.on_playing:
                self.on_playing(state == "playing")

    def _track_changed(self, event: ManagedAudioTrackChangeEvent) -> None:
        """Adopt a track transition selected entirely by the native engine."""
        generation = int(event.generation)
        if self._closing or generation <= self._generation:
            return
        self._cancel_load_watchdog()
        self._cancel_operations()
        self._generation = generation
        self._loaded = False
        self._pending_play_position = None
        self._pending_seek_position = None
        if self.on_track_changed:
            self.on_track_changed(str(event.track_id), int(event.index))
        try:
            self._load_watchdog = self.page.run_task(self._watch_load, generation)
        except Exception:  # noqa: BLE001 - Flet may reject after disposal
            self._fail_service(generation, "The next track could not be prepared.")

    def _media_action(self, event: MediaSessionActionEvent) -> None:
        if self._closing or self.on_media_action is None:
            return
        self.on_media_action(event.action, event.seek_position_ms)
