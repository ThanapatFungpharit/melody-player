from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path
from threading import Event
from typing import cast
from unittest.mock import patch

import flet as ft

from musicplayer.application.thumbnails import ThumbnailCache
from musicplayer.ui.components.common import _artwork
from musicplayer.ui.components.lazy_artwork import DeferredArtwork

JPEG = b"\xff\xd8\xff\xe0" + b"offline-artwork"


class ThumbnailCacheTests(unittest.TestCase):
    def test_downloaded_bytes_are_loaded_offline_without_an_opener(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)
            url = "https://i.ytimg.com/vi/song/hqdefault.jpg"

            self.assertTrue(cache.store_bytes(url, JPEG))
            self.assertEqual(cache.image_source(url), JPEG)
            self.assertTrue(cache.artwork_uri(url).startswith("file:"))

            reopened = ThumbnailCache(directory)
            self.assertEqual(reopened.image_source(url), JPEG)

    def test_local_artwork_paths_become_media_session_uris(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)
            local = (Path(directory) / "restored.thumb").resolve()
            local.write_bytes(JPEG)

            self.assertEqual(cache.artwork_uri(str(local)), local.as_uri())
            missing = str(Path(directory).resolve() / "missing.thumb")
            self.assertEqual(cache.artwork_uri(missing), missing)
            self.assertEqual(cache.artwork_uri(""), "")

    def test_invalid_or_non_remote_artwork_is_not_cached(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)

            self.assertFalse(
                cache.store_bytes("https://example.test/not-image", b"not an image")
            )
            self.assertFalse(cache.store_bytes("file:///cover.jpg", JPEG))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_native_display_uses_file_path_without_reading_image_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)
            url = "https://i.ytimg.com/vi/song/hqdefault.jpg"
            self.assertTrue(cache.store_bytes(url, JPEG))
            self.assertEqual(cache.display_source(url), JPEG)
            cache.native_image_sources = True

            with patch.object(Path, "read_bytes", side_effect=AssertionError):
                source = cache.display_source(url)
                image = cast(DeferredArtwork, _artwork(url, 48, cache=cache))

            cached_path = cache.cached_path(url)
            self.assertIsNotNone(cached_path)
            self.assertEqual(source, str(cast(Path, cached_path).absolute()))
            self.assertIsInstance(image, DeferredArtwork)
            self.assertIsInstance(image.content, ft.Icon)
            self.assertEqual(image.artwork_source, url)
            self.assertEqual(
                cache.display_source("https://example.test/missing.jpg"),
                "https://example.test/missing.jpg",
            )

    def test_memory_cache_is_bounded_by_bytes_as_well_as_entry_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)
            artwork = b"x" * (6 * 1024 * 1024)

            cache._remember("first", artwork)
            cache._remember("second", artwork)
            cache._remember("third", artwork)

            self.assertNotIn("first", cache._memory)
            self.assertEqual(list(cache._memory), ["second", "third"])
            self.assertEqual(cache._memory_bytes, 12 * 1024 * 1024)


class DeferredArtworkTests(unittest.IsolatedAsyncioTestCase):
    async def test_text_can_render_while_artwork_resolves_in_background(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)
            started = Event()
            release = Event()
            url = "https://example.test/art.jpg"

            def slow_source(_: str) -> bytes:
                started.set()
                release.wait(2)
                return JPEG

            with (
                patch.object(
                    cache, "display_source", side_effect=slow_source
                ) as resolve,
                patch("musicplayer.ui.components.lazy_artwork._FIRST_PAINT_DELAY", 0),
                patch.object(DeferredArtwork, "update") as update,
            ):
                artwork = cast(DeferredArtwork, _artwork(url, 48, cache=cache))
                self.assertIsInstance(artwork.content, ft.Icon)
                resolve.assert_not_called()
                artwork._mounted = True
                page = cast(ft.Page, type("Page", (), {})())
                task = asyncio.create_task(artwork._load(page))
                try:
                    self.assertTrue(await asyncio.to_thread(started.wait, 2))
                    self.assertIsInstance(artwork.content, ft.Icon)
                finally:
                    release.set()
                await task

            self.assertIsInstance(artwork.content, ft.Image)
            self.assertEqual(cast(ft.Image, artwork.content).src, JPEG)
            update.assert_called_once()

    async def test_removed_artwork_does_not_update_the_page(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = ThumbnailCache(directory)
            started = Event()
            release = Event()

            def slow_source(_: str) -> bytes:
                started.set()
                release.wait(2)
                return JPEG

            with (
                patch.object(cache, "display_source", side_effect=slow_source),
                patch("musicplayer.ui.components.lazy_artwork._FIRST_PAINT_DELAY", 0),
                patch.object(DeferredArtwork, "update") as update,
            ):
                artwork = cast(
                    DeferredArtwork,
                    _artwork("https://example.test/art.jpg", 48, cache=cache),
                )
                artwork._mounted = True
                page = cast(ft.Page, type("Page", (), {})())
                task = asyncio.create_task(artwork._load(page))
                try:
                    self.assertTrue(await asyncio.to_thread(started.wait, 2))
                    artwork._mounted = False
                finally:
                    release.set()
                await task

            self.assertIsInstance(artwork.content, ft.Icon)
            update.assert_not_called()


if __name__ == "__main__":
    unittest.main()
