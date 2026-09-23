"""Shared queue language so desktop and mobile explain the same play order."""

from __future__ import annotations

from dataclasses import dataclass

import flet as ft

from musicplayer.application.models import RepeatMode
from musicplayer.application.queue import PlaybackQueue


@dataclass(frozen=True)
class QueueModeStatus:
    label: str
    description: str
    icon: ft.IconData


def queue_mode_status(queue: PlaybackQueue) -> QueueModeStatus:
    if queue.repeat is RepeatMode.TRACK:
        return QueueModeStatus(
            "Repeat track",
            "The current track repeats. Every other track waits until repeat is changed.",
            ft.Icons.REPEAT_ONE_ROUNDED,
        )
    if queue.repeat is RepeatMode.PLAYLIST:
        return QueueModeStatus(
            "Repeat queue",
            "After the last track, playback continues again from the first track.",
            ft.Icons.REPEAT_ROUNDED,
        )
    return QueueModeStatus(
        "Play once",
        "The remaining tracks play in order, then playback stops.",
        ft.Icons.FORMAT_LIST_NUMBERED_ROUNDED,
    )


def queue_item_status(queue: PlaybackQueue, index: int) -> str:
    """Describe a row by its actual automatic playback role."""
    if index == queue.current_index:
        return (
            "Now playing · Repeats continuously"
            if queue.repeat is RepeatMode.TRACK
            else "Now playing"
        )

    if queue.repeat is RepeatMode.TRACK:
        return "Waiting · Repeat track is on"

    next_index = queue.next_index(automatic=True)
    if index == next_index:
        return (
            "Up next · Queue loops here"
            if queue.repeat is RepeatMode.PLAYLIST and index <= queue.current_index
            else "Up next"
        )

    if index < queue.current_index:
        return (
            "Played · Returns after the queue loops"
            if queue.repeat is RepeatMode.PLAYLIST
            else "Already played"
        )
    return "Later in queue"
