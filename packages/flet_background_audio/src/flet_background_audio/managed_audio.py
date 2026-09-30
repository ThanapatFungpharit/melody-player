from dataclasses import dataclass
from typing import Any

import flet as ft

AudioSource = str | bytes


def _validate_repeat_mode(value: str) -> None:
    if value not in ("off", "track", "playlist"):
        raise ValueError(f"Invalid repeat mode: {value!r}")


def _validate_generation(value: int) -> int:
    generation = int(value)
    if generation < 0 or generation % 2:
        raise ValueError("Python source generations must be nonnegative and even")
    return generation


def _validate_source(source: AudioSource) -> None:
    if isinstance(source, str):
        if not source.strip():
            raise ValueError("Audio source requires a nonempty path or URL")
    elif isinstance(source, bytes):
        if not source:
            raise ValueError("Audio source bytes must not be empty")
    else:
        raise TypeError("Audio source must be a path, URL, or bytes")


def _validate_queue_items(items: list[dict[str, str]]) -> None:
    """Reject malformed rows before Dart silently drops them."""
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise TypeError(f"Queue item {index} must be a mapping")
        for key in ("track_id", "source"):
            value = item.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"Queue item {index} requires a nonempty {key}")


@dataclass
class ManagedAudioErrorEvent(ft.Event["ManagedAudio"]):
    message: str
    generation: int


@dataclass
class ManagedAudioLoadedEvent(ft.Event["ManagedAudio"]):
    generation: int


@dataclass
class ManagedAudioPositionChangeEvent(ft.Event["ManagedAudio"]):
    position: int
    generation: int


@dataclass
class ManagedAudioDurationChangeEvent(ft.Event["ManagedAudio"]):
    duration: int
    generation: int


@dataclass
class ManagedAudioStateChangeEvent(ft.Event["ManagedAudio"]):
    state: str
    generation: int


@dataclass
class ManagedAudioTrackChangeEvent(ft.Event["ManagedAudio"]):
    track_id: str
    index: int
    generation: int


@ft.control("ManagedAudio")
class ManagedAudio(ft.Service):
    """Page-scoped command and event bridge to a process-scoped audio player.

    The matching Dart service owns the decoder, live queue, preloading, and
    transport. Python exposes only the versioned RPC and event surface used by
    Melody; it does not inherit from or delegate to Flet's stock Audio control.
    """

    volume: ft.Number = 1.0
    on_error: ft.EventHandler[ManagedAudioErrorEvent] | None = None
    on_loaded: ft.EventHandler[ManagedAudioLoadedEvent] | None = None
    on_position_change: ft.EventHandler[ManagedAudioPositionChangeEvent] | None = None
    on_duration_change: ft.EventHandler[ManagedAudioDurationChangeEvent] | None = None
    on_state_change: ft.EventHandler[ManagedAudioStateChangeEvent] | None = None
    on_track_change: ft.EventHandler[ManagedAudioTrackChangeEvent] | None = None

    async def load_source(
        self,
        source: AudioSource,
        generation: int,
        autoplay: bool = False,
        position_ms: int = 0,
    ) -> None:
        _validate_source(source)
        await self._invoke_method(
            "load_source",
            {
                "source": source,
                "generation": _validate_generation(generation),
                "autoplay": bool(autoplay),
                "position_ms": max(0, int(position_ms)),
            },
        )

    async def set_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        generation: int,
        repeat_mode: str,
        autoplay: bool = False,
        position_ms: int = 0,
    ) -> None:
        _validate_queue_items(items)
        _validate_repeat_mode(repeat_mode)
        generation = _validate_generation(generation)
        await self._invoke_method(
            "set_queue",
            {
                "items": items,
                "current_index": int(current_index),
                "generation": generation,
                "repeat_mode": repeat_mode,
                "autoplay": bool(autoplay),
                "position_ms": max(0, int(position_ms)),
            },
        )

    async def update_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        repeat_mode: str,
    ) -> None:
        _validate_queue_items(items)
        _validate_repeat_mode(repeat_mode)
        await self._invoke_method(
            "update_queue",
            {
                "items": items,
                "current_index": int(current_index),
                "repeat_mode": repeat_mode,
            },
        )

    async def cancel_load(self) -> None:
        await self._invoke_method("cancel_load")

    async def clear_source(self) -> None:
        await self._invoke_method("clear_source")

    async def get_playback_state(self) -> dict[str, Any]:
        result = await self._invoke_method("get_playback_state")
        return dict(result or {})

    async def play(self, position: ft.DurationValue = 0) -> None:
        await self._invoke_method("play", {"position": position})

    async def pause(self) -> None:
        await self._invoke_method("pause")

    async def resume(self) -> None:
        await self._invoke_method("resume")

    async def seek(self, position: ft.DurationValue) -> None:
        await self._invoke_method("seek", {"position": position})

    async def stop(self) -> None:
        await self._invoke_method("stop")

    async def skip_next(self) -> None:
        await self._invoke_method("skip_next")

    async def skip_previous(self) -> None:
        await self._invoke_method("skip_previous")
