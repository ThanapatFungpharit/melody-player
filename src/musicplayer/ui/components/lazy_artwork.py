"""Render artwork after its surrounding track controls have mounted."""

from __future__ import annotations

import asyncio
import logging
from concurrent.futures import Future
from dataclasses import field
from typing import Any
from weakref import WeakKeyDictionary

import flet as ft

from musicplayer.application.thumbnails import ThumbnailCache

logger = logging.getLogger(__name__)

_FIRST_PAINT_DELAY = 0.04
_BATCH_PAUSE = 0.016
_ARTWORK_GATES: WeakKeyDictionary[ft.Page, asyncio.Semaphore] = WeakKeyDictionary()


def _artwork_gate(page: ft.Page) -> asyncio.Semaphore:
    gate = _ARTWORK_GATES.get(page)
    if gate is None:
        gate = asyncio.Semaphore(4)
        _ARTWORK_GATES[page] = gate
    return gate


@ft.control("Container", isolated=True)
class DeferredArtwork(ft.Container):
    """Show a stable placeholder, then load one image without blocking the UI."""

    artwork_source: str | bytes = field(default="", metadata={"skip": True})
    artwork_size: int = field(default=48, metadata={"skip": True})
    playlist_artwork: bool = field(default=False, metadata={"skip": True})
    artwork_cache: ThumbnailCache | None = field(
        default=None, repr=False, metadata={"skip": True}
    )
    _task: Future[Any] | None = field(
        default=None, init=False, repr=False, compare=False, metadata={"skip": True}
    )
    _mounted: bool = field(
        default=False, init=False, repr=False, compare=False, metadata={"skip": True}
    )

    def init(self) -> None:
        size = self.artwork_size
        self.width = size
        self.height = size
        self.border_radius = 14 if size >= 100 else 12
        self.bgcolor = ft.Colors.PRIMARY_CONTAINER
        self.alignment = ft.Alignment.CENTER
        self.content = ft.Icon(
            ft.Icons.ALBUM_ROUNDED
            if self.playlist_artwork
            else ft.Icons.MUSIC_NOTE_ROUNDED,
            size=max(22, size * 0.38),
            color=ft.Colors.PRIMARY,
        )

    def did_mount(self) -> None:
        self._mounted = True
        self._task = self.page.run_task(self._load, self.page)

    def will_unmount(self) -> None:
        self._mounted = False
        if self._task is not None:
            self._task.cancel()
            self._task = None

    async def _load(self, page: ft.Page) -> None:
        # Let the first page patch paint text and placeholders before images.
        await asyncio.sleep(_FIRST_PAINT_DELAY)
        if not self._mounted:
            return
        try:
            async with _artwork_gate(page):
                source = (
                    await asyncio.to_thread(
                        self.artwork_cache.display_source, self.artwork_source
                    )
                    if self.artwork_cache is not None
                    else self.artwork_source
                )
                if not self._mounted:
                    return
                self.content = ft.Image(
                    src=source,
                    width=self.artwork_size,
                    height=self.artwork_size,
                    fit=ft.BoxFit.COVER,
                    border_radius=14 if self.artwork_size >= 100 else 12,
                    error_content=ft.Icon(ft.Icons.BROKEN_IMAGE_OUTLINED),
                )
                self.bgcolor = None
                self.update()
                # Give Flutter a frame between small groups of image patches.
                await asyncio.sleep(_BATCH_PAUSE)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.warning("Could not display track artwork", exc_info=True)
