from dataclasses import dataclass

import flet as ft


@dataclass
class MediaSessionActionEvent(ft.Event["BackgroundAudioSession"]):
    """A transport command received from the operating-system media panel."""

    action: str
    seek_position_ms: int | None = None


@ft.control("BackgroundAudioSession")
class BackgroundAudioSession(ft.Service):
    """System media-session companion to this package's managed player."""

    on_action: ft.EventHandler[MediaSessionActionEvent] | None = None

    async def sync(
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
        has_next: bool = False,
        has_previous: bool = False,
        repeat_mode: str = "off",
        can_repeat: bool = False,
        can_shuffle: bool = False,
        can_favorite: bool = False,
        favorite: bool = False,
        notification_action_pair: str = "shuffle_favorite",
        keep_alive: bool = False,
        reattach: bool = False,
    ) -> None:
        """Activate the native session and publish one coherent player snapshot."""
        if repeat_mode not in ("off", "track", "playlist"):
            raise ValueError(f"Invalid repeat mode: {repeat_mode!r}")
        await self._invoke_method(
            "sync",
            {
                "title": title,
                "artist": artist,
                "album": album,
                "artwork_uri": artwork_uri,
                "auto_focal_point_live_notifications": bool(
                    auto_focal_point_live_notifications
                ),
                "duration_ms": max(0, int(duration_ms)),
                "position_ms": max(0, int(position_ms)),
                "playing": bool(playing),
                "loading": bool(loading),
                "has_next": bool(has_next),
                "has_previous": bool(has_previous),
                "repeat_mode": repeat_mode,
                "can_repeat": bool(can_repeat),
                "can_shuffle": bool(can_shuffle),
                "can_favorite": bool(can_favorite),
                "favorite": bool(favorite),
                "notification_action_pair": notification_action_pair,
                "keep_alive": bool(keep_alive),
                "reattach": bool(reattach),
            },
        )

    async def deactivate(self) -> None:
        """Remove system controls and release the foreground playback service."""
        await self._invoke_method("deactivate")
