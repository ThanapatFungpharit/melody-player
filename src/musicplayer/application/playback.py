from __future__ import annotations

import time
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from functools import wraps
from pathlib import Path
from threading import RLock
from typing import Any, Protocol

from musicplayer.core.library import MusicManager

from .library_service import LibraryService
from .models import AppSettings
from .playback_persistence import PlaybackPersistence
from .queue import PlaybackQueue
from .store import ApplicationStore


class TrackPlayerBackend(Protocol):
    """Required contract for the package-owned managed track player."""

    def load(
        self, source: str | bytes, *, autoplay: bool = False, position_ms: int = 0
    ) -> None: ...
    def set_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
        autoplay: bool = False,
        position_ms: int = 0,
    ) -> None: ...

    def update_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
    ) -> None: ...

    def play(self, position_ms: int = 0) -> None: ...
    def pause(self) -> None: ...
    def resume(self) -> None: ...
    def seek(self, position_ms: int) -> None: ...
    def set_volume(self, value: float) -> None: ...
    def cancel_load(self) -> None: ...
    def discard_source(self) -> None: ...


def _serialized[**P, R](method: Callable[P, R]) -> Callable[P, R]:
    @wraps(method)
    def invoke(*args: P.args, **kwargs: P.kwargs) -> R:
        controller = args[0]
        assert isinstance(controller, PlaybackController)
        with controller._load_lock:
            return method(*args, **kwargs)

    return invoke


@dataclass(frozen=True)
class PlaybackSnapshot:
    current_track_id: str | None
    queue: tuple[str, ...]
    playing: bool
    loading: bool
    position_ms: int
    duration_ms: int
    generation: int


class PlaybackController:
    """Coordinates persistent queue semantics with the managed track player."""

    def __init__(
        self,
        manager: MusicManager,
        library: LibraryService,
        store: ApplicationStore,
        backend: TrackPlayerBackend,
        *,
        persistence: PlaybackPersistence | None = None,
        available_track_ids: set[str] | None = None,
        artwork_uri: Callable[[str], str] | None = None,
        on_change: Callable[[str], None] | None = None,
        on_error: Callable[[str], None] | None = None,
    ) -> None:
        self.manager = manager
        self.library = library
        self.store = store
        self.backend = backend
        self._artwork_uri = artwork_uri or (lambda source: source)
        self.persistence = persistence
        self.on_change = on_change
        self.on_error = on_error
        settings = store.settings
        restored = store.get("playback", {}) if settings.resume_session else {}
        persisted = restored if isinstance(restored, dict) else {}
        self.queue = PlaybackQueue.from_dict(persisted)
        original_items = list(self.queue.items)
        original_index = self.queue.current_index

        available_items: list[str] = []
        items_before_original = 0
        current_was_available = False

        for index, item in enumerate(original_items):
            is_available = (
                item in available_track_ids
                if available_track_ids is not None
                else self.manager.has_track(item)
                and self.manager.track_path(item).is_file()
            )
            if is_available:
                available_items.append(item)
                if index < original_index:
                    items_before_original += 1
            if index == original_index:
                current_was_available = is_available

        self.queue.items = available_items

        if not self.queue.items:
            self.queue.current_index = -1
        elif current_was_available:
            self.queue.current_index = items_before_original
        else:
            self.queue.current_index = min(
                items_before_original, len(self.queue.items) - 1
            )
        self.position_ms = 0
        if current_was_available:
            try:
                self.position_ms = max(0, int(persisted.get("position_ms", 0)))
            except TypeError, ValueError, OverflowError:
                pass
        self.volume = settings.volume
        self.muted = settings.muted
        self.previous_volume = settings.previous_volume
        self._playing = False
        self.duration_ms = 0
        self.external_title = ""
        self.external_uploader = ""
        self.external_thumbnail = ""
        self._source_loaded = False
        self._load_lock = RLock()
        self._load_generation = 0
        self._closed = False
        self._player_loading = False
        self._loading = False
        self._load_autoplay = False
        self._last_persisted_position = 0.0
        self._last_backend_error_at: float | None = None
        self._pending_play_record_id: str | None = None
        self._media_session_active = False
        self.backend.set_volume(0.0 if self.muted else self.volume / 100)
        if self.queue.items != original_items:
            self._persist()

    @property
    def playing(self) -> bool:
        return self._playing

    @property
    def snapshot(self) -> PlaybackSnapshot:
        with self._load_lock:
            return PlaybackSnapshot(
                self.current_track_id,
                tuple(self.queue.items),
                self._playing,
                self._loading or self._player_loading,
                self.position_ms,
                self.duration_ms,
                self._load_generation,
            )

    @property
    def current_track_id(self) -> str | None:
        return self.queue.current

    @property
    def media_session_active(self) -> bool:
        return self._media_session_active

    @_serialized
    def on_native_reattach(self, state: dict[str, Any]) -> None:
        """Mirror a decoder that survived disposal of the previous Flet page."""
        track_id = state.get("track_id")
        if isinstance(track_id, str) and track_id in self.queue.items:
            self.queue.select(self.queue.items.index(track_id))
            self._clear_external()
        else:
            source = str(state.get("source") or "")
            self.external_title = str(state.get("title") or Path(source).stem)
            self.external_uploader = str(state.get("artist") or "")
            self.external_thumbnail = str(state.get("artwork_uri") or "")
        self._source_loaded = True
        self._player_loading = False
        self._loading = False
        self._playing = bool(state.get("playing"))
        self._media_session_active = True
        self.position_ms = max(0, int(state.get("position_ms") or 0))
        self.duration_ms = max(0, int(state.get("duration_ms") or 0))
        self._persist()
        self._notify("track")

    @_serialized
    def play_tracks(
        self,
        track_ids: Sequence[str],
        *,
        start_index: int = 0,
    ) -> None:
        self._play_tracks(track_ids, start_index=start_index, shuffle_once=False)

    @_serialized
    def play_tracks_shuffled(self, track_ids: Sequence[str]) -> None:
        """Start a collection in a random order without enabling a mode."""
        self._play_tracks(track_ids, start_index=0, shuffle_once=True)

    def _play_tracks(
        self,
        track_ids: Sequence[str],
        *,
        start_index: int,
        shuffle_once: bool,
    ) -> None:
        selected_index = (
            max(0, min(start_index, len(track_ids) - 1)) if track_ids else -1
        )
        selected = str(track_ids[selected_index]) if selected_index >= 0 else None
        available: list[str] = []
        seen: set[str] = set()
        for item in track_ids:
            normalized = str(item)
            if normalized in seen or not self.manager.has_track(normalized):
                continue
            seen.add(normalized)
            available.append(normalized)

        if not available:
            self._error("There are no available tracks to play.")
            return
        available_index = (
            available.index(selected)
            if selected in seen
            else min(max(0, selected_index), len(available) - 1)
        )
        self.queue.replace(
            available,
            start_index=available_index,
            shuffle_once=shuffle_once,
        )
        self._load_current(autoplay=True)

    @_serialized
    def play_stream(
        self,
        source: str,
        *,
        title: str,
        uploader: str = "",
        thumbnail: str = "",
    ) -> None:
        """Play an ephemeral search result without adding it to the library."""
        self._cancel_pending_load()
        self.external_title = title
        self.external_uploader = uploader
        self.external_thumbnail = thumbnail
        self._source_loaded = True
        self._player_loading = True
        self.position_ms = 0
        self.duration_ms = 0
        self._playing = True
        self._media_session_active = True
        try:
            self.backend.load(source, autoplay=True)
        except (OSError, ValueError, RuntimeError) as error:
            self.on_backend_error(str(error))
        self._notify()

    @_serialized
    def play_track(self, track_id: str) -> None:
        track_id = str(track_id)
        if track_id == self.current_track_id and self._loading:
            return
        try:
            self.queue.select(self.queue.items.index(track_id))
        except ValueError:
            self.queue.replace([track_id])
        self._load_current(autoplay=True)

    @_serialized
    def play_queue_index(self, index: int) -> None:
        """Play one existing queue row without rebuilding or reshuffling it."""
        if not 0 <= int(index) < len(self.queue.items):
            return
        self.queue.select(int(index))
        self._load_current(autoplay=True)

    @_serialized
    def toggle(self) -> None:
        if not self.current_track_id and not self.external_title:
            tracks = self.manager.list_tracks()
            if tracks:
                self.queue.replace([str(item.id) for item in tracks])
                self._load_current(autoplay=True)
            else:
                self._error("Your library is empty. Download a track first.")
            return
        if self._loading:
            # A search selection is still resolving or downloading. Preserve
            # the desired state until its managed-player source is available.
            self._load_autoplay = not self._playing
            self._playing = self._load_autoplay
            if self._source_loaded:
                if self._playing:
                    self.backend.resume()
                else:
                    self.backend.pause()
            if self._playing:
                self._media_session_active = True
            self._persist()
            self._notify()
            return
        if self._player_loading:
            self._playing = not self._playing
            if self._playing:
                self._media_session_active = True
                self.backend.resume()
            else:
                self.backend.pause()
            self._notify()
            return
        if self._playing:
            self.backend.pause()
            self._playing = False
        else:
            if not self._source_loaded:
                saved_position = self.position_ms
                if not self._load_current(autoplay=True, position_ms=saved_position):
                    return
                if self._loading:
                    return
            else:
                self.backend.resume()
            self._playing = True
            self._media_session_active = True
        self._persist()
        self._notify()

    @_serialized
    def next(self) -> None:
        was_external = bool(self.external_title)
        source_was_loaded = self._source_loaded
        was_playing = self._playing
        self._clear_external()
        if self.queue.next():
            self._load_current(autoplay=True)
        else:
            if was_external:
                # A stream has no queue selection to resume after Next.
                self.stop()
                self._notify("track")
                return
            if source_was_loaded:
                if was_playing:
                    self.backend.pause()
                self.backend.seek(0)
            self._playing = False
            self.position_ms = 0
            self._persist()
            self._notify("track")

    @_serialized
    def previous(self) -> None:
        if self.external_title:
            self.seek(0)
            return
        if self.position_ms > 5_000:
            self.seek(0)
        elif self.queue.previous():
            self._load_current(autoplay=True)

    @_serialized
    def stop(self) -> None:
        """Terminate playback while preserving a library queue selection.

        Pause deliberately keeps the media session visible. Stop is the
        explicit destructive transport boundary that releases the source and
        removes system controls.
        """
        self._cancel_pending_load(discard_source=True)
        self._source_loaded = False
        self._playing = False
        self._player_loading = False
        self._media_session_active = False
        self.position_ms = 0
        self.duration_ms = 0
        self._pending_play_record_id = None
        if self.external_title:
            self.external_title = ""
            self.external_uploader = ""
            self.external_thumbnail = ""
        self._persist()
        self._notify("state")

    @_serialized
    def seek(self, position_ms: int) -> None:
        self.position_ms = max(
            0, min(int(position_ms), self.duration_ms or int(position_ms))
        )
        if self._loading:
            self._persist()
            self._notify()
            return
        if not self._source_loaded:
            # A restored queue has a meaningful resume position before its
            # managed-player source exists. Keep that intent locally so the next
            # play load start at this position instead of issuing a seek to an
            # empty decoder.
            self._persist()
            self._notify("progress")
            return
        self.backend.seek(self.position_ms)
        self._persist()
        self._notify("progress")

    @_serialized
    def add_next(self, track_id: str) -> None:
        self.queue.add_next(track_id)
        self._sync_queue()
        self._persist()
        self._notify("queue")

    @_serialized
    def add_last(self, track_id: str) -> None:
        self.queue.add_last(track_id)
        self._sync_queue()
        self._persist()
        self._notify("queue")

    @_serialized
    def add_next_many(self, track_ids: Iterable[str]) -> int:
        """Insert several tracks next with one persistence/UI update cycle."""
        items = [str(track_id) for track_id in track_ids]
        for track_id in reversed(items):
            self.queue.add_next(track_id)
        if items:
            self._sync_queue()
            self._persist()
            self._notify("queue")
        return len(items)

    @_serialized
    def add_last_many(self, track_ids: Iterable[str]) -> int:
        """Append several tracks with one persistence/UI update cycle."""
        items = [str(track_id) for track_id in track_ids]
        for track_id in items:
            self.queue.add_last(track_id)
        if items:
            self._sync_queue()
            self._persist()
            self._notify("queue")
        return len(items)

    @_serialized
    def remove_queue_item(self, index: int) -> None:
        was_current = index == self.queue.current_index
        self.queue.remove_at(index)
        if was_current and not self.external_title:
            if self.queue.current:
                self._load_current(autoplay=self._playing)
            else:
                # Updating an empty native queue preserves its active decoder.
                # Release the source when its last visible row is removed.
                self.stop()
                self._notify("queue")
                return
        else:
            self._sync_queue()
        self._persist()
        self._notify("queue")

    @_serialized
    def reorder_queue(self, old_index: int | None, new_index: int | None) -> None:
        """Apply a direct drag-and-drop reorder and persist it immediately."""
        if old_index is None or new_index is None:
            return
        if not (0 <= old_index < len(self.queue.items)):
            return
        if new_index > old_index:
            new_index -= 1
        target = max(0, min(new_index, len(self.queue.items) - 1))
        self.queue.move(old_index, target)
        self._sync_queue()
        self._persist()
        self._notify("queue")

    @_serialized
    def clear_queue(self) -> None:
        self.queue.clear(keep_current=True)
        self._sync_queue()
        self._persist()
        self._notify("queue")

    @_serialized
    def clear_library_state(self) -> None:
        """Drop queued library tracks and stop a loaded library source."""
        library_source_active = bool(
            not self.external_title and (self.current_track_id or self._source_loaded)
        )
        self.queue.clear()
        if library_source_active:
            self.stop()
        else:
            self._sync_queue()
            self._persist()
        self._notify("queue")

    @_serialized
    def shuffle_upcoming(self) -> bool:
        if not self.queue.shuffle_upcoming():
            return False
        self._sync_queue()
        self._persist()
        self._notify("queue")
        return True

    @_serialized
    def cycle_repeat(self):
        mode = self.queue.cycle_repeat()
        self._sync_queue()
        self._persist()
        self._notify("queue")
        return mode

    @_serialized
    def set_volume(self, value: int, *, persist: bool = True) -> None:
        """Apply volume immediately and optionally persist the settled value.

        Slider previews pass ``persist=False`` so dragging remains responsive;
        the final pointer-up event persists the selected value atomically.
        """
        value = max(0, min(100, int(value)))
        self.volume = value
        if value > 0:
            self.previous_volume = value
            self.muted = False
        else:
            self.muted = True
        self.backend.set_volume(0.0 if self.muted else value / 100)
        if persist:
            self._save_volume()
        self._notify("volume")

    @_serialized
    def toggle_mute(self) -> None:
        if self.muted:
            self.muted = False
            self.volume = max(1, self.previous_volume)
        else:
            if self.volume > 0:
                self.previous_volume = self.volume
            self.muted = True
        self.backend.set_volume(0.0 if self.muted else self.volume / 100)
        self._save_volume()
        self._notify("volume")

    @_serialized
    def apply_settings(self, settings: AppSettings) -> None:
        """Apply live playback settings without changing queue/session state."""
        self.volume = settings.volume
        self.previous_volume = settings.previous_volume
        self.muted = settings.muted
        self.backend.set_volume(0.0 if self.muted else self.volume / 100)
        self._notify("volume")

    @_serialized
    def on_position(self, position_ms: int) -> None:
        if self._loading or self._player_loading:
            return
        position = max(0, int(position_ms))
        self.position_ms = (
            min(position, self.duration_ms) if self.duration_ms else position
        )
        now = time.monotonic()
        if now - self._last_persisted_position >= 5:
            self._persist()
            self._last_persisted_position = now
        self._notify("progress")

    @_serialized
    def on_duration(self, duration_ms: int) -> None:
        if self._loading or self._player_loading:
            return
        self.duration_ms = max(0, int(duration_ms))
        if self.duration_ms and self.position_ms > self.duration_ms:
            self.position_ms = self.duration_ms
            self._persist()
        self._notify("progress")

    @_serialized
    def on_playing(self, playing: bool) -> None:
        if self._loading or not self._source_loaded:
            return
        if self._player_loading:
            if not playing:
                return
            # A native playing event also confirms that preparation finished.
            # Recover if the earlier loaded event was missed during a handoff.
            self._player_loading = False
        self._playing = playing
        if playing:
            self._media_session_active = True
        track_id = self.current_track_id
        if (
            playing
            and track_id is not None
            and track_id == self._pending_play_record_id
        ):
            self._pending_play_record_id = None
            if self.persistence is not None:
                self.persistence.record_play(track_id)
            else:
                self.library.record_play(
                    track_id,
                    playback=self.queue.to_dict(position_ms=self.position_ms),
                )
        self._notify()

    @_serialized
    def on_completed(self) -> None:
        if self._loading or self._player_loading or not self._source_loaded:
            return
        # The managed player has already applied repeat/queue policy. A
        # completion event reaches Python only when it found no next item.
        self._playing = False
        self.position_ms = self.duration_ms
        self._persist()
        self._notify()

    @_serialized
    def on_track_changed(self, track_id: str, index: int) -> None:
        """Mirror a transition selected by the managed queue engine."""
        if self._closed:
            return
        normalized = str(track_id)
        if not (0 <= int(index) < len(self.queue.items)):
            return
        if self.queue.items[int(index)] != normalized:
            try:
                index = self.queue.items.index(normalized)
            except ValueError:
                return
        self.queue.select(int(index))
        self.external_title = ""
        self.external_uploader = ""
        self.external_thumbnail = ""
        self._source_loaded = True
        self._player_loading = True
        self._loading = False
        self._playing = True
        self._media_session_active = True
        self.position_ms = 0
        self.duration_ms = 0
        self._pending_play_record_id = normalized
        self._persist()
        self._notify("track")

    @_serialized
    def on_stopped(self) -> None:
        """Adopt Stop after the managed player handled a system action."""
        if self._closed:
            return
        self._source_loaded = False
        self._player_loading = False
        self._loading = False
        self._playing = False
        self._media_session_active = False
        self.position_ms = 0
        self.duration_ms = 0
        self._pending_play_record_id = None
        self.external_title = ""
        self.external_uploader = ""
        self.external_thumbnail = ""
        self._persist()
        self._notify()

    @_serialized
    def on_backend_error(self, message: str) -> None:
        """Reconcile optimistic state after a managed-player failure."""
        # Supersede pending selection and player generations before repairing
        # controller state so a late callback cannot resurrect a rejected track.
        self._cancel_pending_load(discard_source=True)
        self._playing = False
        self._source_loaded = False
        self._loading = False
        self._player_loading = False
        self._media_session_active = False
        self._pending_play_record_id = None
        if self.external_title:
            self.external_title = ""
            self.external_uploader = ""
            self.external_thumbnail = ""
            self.position_ms = 0
            self.duration_ms = 0
        self._persist()
        self._notify()
        now = time.monotonic()
        if (
            self._last_backend_error_at is None
            or now - self._last_backend_error_at >= 5
        ):
            self._last_backend_error_at = now
            self._error(message)

    def _load_current(self, *, autoplay: bool, position_ms: int = 0) -> bool:
        track_id = self.current_track_id
        if not track_id:
            return False
        # The managed player validates the complete queue and prepares the
        # selected decoder beside the active one before swapping sources.
        self._clear_external()
        if autoplay:
            self._media_session_active = True
        position = max(0, int(position_ms))
        try:
            self._activate_queue(
                track_id,
                autoplay=autoplay,
                position_ms=position,
            )
        except (OSError, KeyError, ValueError, RuntimeError) as error:
            self._playing = False
            self._source_loaded = False
            self._error(f"This track is unavailable: {error}")
            self._persist()
            self._notify("track")
            return False
        self._notify("track")
        return True

    def _queue_items(self) -> list[dict[str, str]]:
        details = self.library.details_many(self.queue.items)
        items: list[dict[str, str]] = []
        for track_id in self.queue.items:
            track = self.manager.get_track(track_id)
            extra = details.get(track_id)
            items.append(
                {
                    "track_id": track_id,
                    "source": _audio_source(self.manager.track_path(track_id)),
                    "title": track.title or Path(track.filename).stem,
                    "artist": extra.uploader if extra else "",
                    "album": extra.source_name if extra else "",
                    "artwork_uri": self._artwork_uri(extra.thumbnail) if extra else "",
                }
            )
        return items

    def _activate_queue(
        self,
        track_id: str,
        *,
        autoplay: bool,
        position_ms: int,
    ) -> None:
        items = self._queue_items()
        current_index = self.queue.items.index(track_id)
        self._source_loaded = True
        self._player_loading = True
        self.position_ms = position_ms
        self.duration_ms = 0
        self._playing = autoplay
        self._pending_play_record_id = track_id if autoplay else None
        self.backend.set_queue(
            items,
            current_index,
            repeat_mode=self.queue.repeat.value,
            autoplay=autoplay,
            position_ms=position_ms,
        )
        self._persist()

    def _sync_queue(self) -> None:
        """Send every queue mutation to the authoritative managed player."""
        if self.external_title or self._closed:
            return
        try:
            items = self._queue_items()
        except OSError, KeyError, ValueError:
            return
        self.backend.update_queue(
            items,
            self.queue.current_index,
            repeat_mode=self.queue.repeat.value,
        )

    def _save_volume(self) -> None:
        if self.persistence is not None:
            self.persistence.save(
                volume={
                    "volume": self.volume,
                    "previous_volume": self.previous_volume,
                    "muted": self.muted,
                }
            )
            return
        settings = self.store.settings
        settings.volume = self.volume
        settings.previous_volume = self.previous_volume
        settings.muted = self.muted
        self.store.save_settings(settings)

    def _clear_external(self) -> None:
        self._cancel_pending_load()
        self.external_title = ""
        self.external_uploader = ""
        self.external_thumbnail = ""

    def _cancel_pending_load(self, *, discard_source: bool = False) -> None:
        with self._load_lock:
            self._load_generation += 1
            player_was_loading = self._player_loading
            self._loading = False
            self._player_loading = False
            self._pending_play_record_id = None
        if self._closed:
            return
        if discard_source:
            self.backend.discard_source()
        elif player_was_loading:
            self.backend.cancel_load()

    def _persist(self) -> None:
        state = self.queue.to_dict(position_ms=self.position_ms)
        if self.persistence is not None:
            self.persistence.save(playback=state)
        else:
            self.store.set("playback", state)

    @_serialized
    def on_loaded(self) -> None:
        self._player_loading = False
        self._notify("loading")

    @_serialized
    def close(self) -> None:
        self._persist()
        self._closed = True
        self._cancel_pending_load()

    @_serialized
    def begin_pending_track(self, title: str) -> int:
        """Reserve playback intent before resolving or downloading a selection."""
        self._cancel_pending_load()
        self.backend.pause()
        self._source_loaded = False
        self.external_title = title
        self.external_uploader = ""
        self.external_thumbnail = ""
        self._loading = True
        self._playing = self._load_autoplay = True
        self._media_session_active = True
        self.position_ms = self.duration_ms = 0
        self._notify()
        return self._load_generation

    @_serialized
    def is_current_request(self, generation: int) -> bool:
        return not self._closed and generation == self._load_generation

    def _notify(self, change: str = "state") -> None:
        """Publish a scoped UI invalidation instead of forcing a full redraw."""
        if self.on_change:
            self.on_change(change)

    def _error(self, message: str) -> None:
        if self.on_error:
            self.on_error(message)


def _audio_source(path: Path) -> str:
    """Return a native path without reading the song through Python.

    Never send a whole song through the UI protocol. Use a native path, not a
    file URI (which Flet interprets as a network URL on Windows). The native
    decoder owns existence, format, and non-empty validation and reports any
    failure through the generation-scoped backend error event.
    """
    return str(path)
