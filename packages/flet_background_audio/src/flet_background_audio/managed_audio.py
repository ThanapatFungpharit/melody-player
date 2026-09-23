from dataclasses import dataclass

import flet as ft

AudioSource = str | bytes


@dataclass
class ManagedAudioErrorEvent(ft.Event["ManagedAudio"]):
    message: str


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
    """Long-lived audio player owned entirely by this extension.

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

    async def load_source(self, source: AudioSource, generation: int) -> None:
        await self._invoke_method(
            "load_source", {"source": source, "generation": int(generation)}
        )

    async def set_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        generation: int,
        repeat_mode: str,
        shuffle: bool,
    ) -> None:
        await self._invoke_method(
            "set_queue",
            {
                "items": items,
                "current_index": int(current_index),
                "generation": int(generation),
                "repeat_mode": repeat_mode,
                "shuffle": bool(shuffle),
            },
        )

    async def update_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        repeat_mode: str,
        shuffle: bool,
    ) -> None:
        await self._invoke_method(
            "update_queue",
            {
                "items": items,
                "current_index": int(current_index),
                "repeat_mode": repeat_mode,
                "shuffle": bool(shuffle),
            },
        )

    async def cancel_load(self) -> None:
        await self._invoke_method("cancel_load")

    async def clear_source(self) -> None:
        await self._invoke_method("clear_source")

    async def set_foreground(self, foreground: bool) -> None:
        await self._invoke_method("set_foreground", {"foreground": bool(foreground)})

    async def get_playback_state(self) -> dict[str, int | None]:
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
