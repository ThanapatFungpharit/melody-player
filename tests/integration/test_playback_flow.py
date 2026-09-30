from __future__ import annotations

import tempfile
import unittest
import wave
from pathlib import Path
from threading import Event

from musicplayer.application.downloads import DownloadCoordinator
from musicplayer.application.library_service import LibraryService
from musicplayer.application.models import AppSettings
from musicplayer.application.playback import PlaybackController
from musicplayer.application.store import ApplicationStore
from musicplayer.core.downloader import Downloader
from musicplayer.core.library import MusicManager


class ValidWaveDownloader(Downloader):
    """Deterministic stand-in for yt-dlp's successfully transcoded output."""

    def _run_yt_dlp(self, job, temporary_directory: str) -> None:
        path = Path(temporary_directory) / "downloaded.wav"
        with wave.open(str(path), "wb") as audio:
            audio.setnchannels(2)
            audio.setsampwidth(2)
            audio.setframerate(8_000)
            audio.writeframes(b"\x00\x00\x00\x00" * 2_000)


class FlowAudioBackend:
    def __init__(self) -> None:
        self.source: str | bytes = ""
        self.queue: list[dict[str, str]] = []
        self.current_index = -1
        self.loaded = Event()
        self.played_at: list[int] = []

    def load(
        self, source: str | bytes, *, autoplay: bool = False, position_ms: int = 0
    ) -> None:
        self.source = source
        self.loaded.set()
        if autoplay:
            self.played_at.append(position_ms)

    def play(self, position_ms: int = 0) -> None:
        self.played_at.append(position_ms)

    def set_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
        autoplay: bool = False,
        position_ms: int = 0,
    ) -> None:
        self.queue = items
        self.current_index = current_index
        self.loaded.set()
        if autoplay:
            self.played_at.append(position_ms)

    def update_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
    ) -> None:
        self.queue = items
        self.current_index = current_index

    def pause(self) -> None:
        pass

    def resume(self) -> None:
        pass

    def seek(self, position_ms: int) -> None:
        pass

    def set_volume(self, value: float) -> None:
        pass

    def cancel_load(self) -> None:
        pass

    def discard_source(self) -> None:
        pass


class CleanDownloadPlaybackFlowTests(unittest.TestCase):
    def test_clean_state_download_register_load_and_play(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            store_path = root / "state.json"
            library_path = root / "library.mmdb"
            self.assertFalse(store_path.exists())
            self.assertFalse(library_path.exists())

            settings = AppSettings(
                download_directory=str(music),
                audio_format="wav",
                concurrent_downloads=1,
            )
            store = ApplicationStore(store_path)
            store.save_settings(settings)
            manager = MusicManager(library_path, music)
            coordinator = DownloadCoordinator(manager, store, settings)
            coordinator._downloader.shutdown()
            coordinator._downloader = ValidWaveDownloader(
                music,
                max_workers=1,
                audio_extensions=frozenset({".wav"}),
            )
            try:
                (task,) = coordinator.start_urls(("https://youtu.be/clean-flow",)).tasks
                job = coordinator._downloader._jobs[task.id]
                job.future.result(timeout=5)  # ty: ignore[unresolved-attribute]

                record = coordinator.list()[0]
                self.assertEqual(record.status, "completed")
                self.assertEqual(len(record.track_ids), 1)
                track_id = record.track_ids[0]
                track = manager.get_track(track_id)
                path = manager.track_path(track_id)
                self.assertEqual(path, music.resolve() / track.filename)
                self.assertTrue(path.is_file())
                self.assertGreater(path.stat().st_size, 44)
                self.assertIsNone(manager.check_track_integrity(track_id))
                with wave.open(str(path), "rb") as audio:
                    self.assertEqual(audio.getnchannels(), 2)
                    self.assertEqual(audio.getframerate(), 8_000)
                    self.assertEqual(audio.getnframes(), 2_000)

                backend = FlowAudioBackend()
                playback = PlaybackController(
                    manager,
                    LibraryService(manager, store),
                    store,
                    backend,
                )
                playback.play_track(track_id)
                self.assertTrue(backend.loaded.wait(timeout=5))
                selected = backend.queue[backend.current_index]
                self.assertEqual(selected["track_id"], track_id)
                self.assertEqual(selected["source"], str(path))
                self.assertEqual(selected["title"], "Song 1 of 1")
                self.assertEqual(backend.source, "")
                self.assertEqual(backend.played_at, [0])
                self.assertEqual(playback.current_track_id, track_id)
                playback.on_loaded()
                playback.on_playing(True)
                self.assertEqual(store.track_details(track_id).play_count, 1)
            finally:
                coordinator.shutdown()


if __name__ == "__main__":
    unittest.main()
