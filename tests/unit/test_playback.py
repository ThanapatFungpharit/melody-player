from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from musicplayer.application.library_service import LibraryService
from musicplayer.application.playback import PlaybackController
from musicplayer.application.store import ApplicationStore
from musicplayer.core.library import MusicManager


class FakeAudioBackend:
    def __init__(self) -> None:
        self.source = ""
        self.played_at: list[int] = []
        self.volume = 0.0
        self.pause_count = 0
        self.seeked_to: list[int] = []
        self.queues: list[tuple[list[dict[str, str]], int, str]] = []
        self.queue_updates: list[tuple[list[dict[str, str]], int, str]] = []
        self.cancelled_loads = 0
        self.discarded_sources = 0

    def load(
        self, source: str | bytes, *, autoplay: bool = False, position_ms: int = 0
    ) -> None:
        self.source = source
        if autoplay:
            self.played_at.append(position_ms)

    def play(self, position_ms: int = 0) -> None:
        self.played_at.append(position_ms)

    def pause(self) -> None:
        self.pause_count += 1

    def resume(self) -> None:
        self.played_at.append(-1)

    def seek(self, position_ms: int) -> None:
        self.seeked_to.append(position_ms)

    def set_volume(self, value: float) -> None:
        self.volume = value

    def set_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
        autoplay: bool = False,
        position_ms: int = 0,
    ) -> None:
        self.queues.append((items, current_index, repeat_mode))
        if autoplay:
            self.played_at.append(position_ms)

    def update_queue(
        self,
        items: list[dict[str, str]],
        current_index: int,
        *,
        repeat_mode: str,
    ) -> None:
        self.queue_updates.append((items, current_index, repeat_mode))

    def cancel_load(self) -> None:
        self.cancelled_loads += 1

    def discard_source(self) -> None:
        self.discarded_sources += 1


class PlaybackControllerTests(unittest.TestCase):
    def test_native_queue_owns_completion_and_python_mirrors_track_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids: list[str] = []
            for name in ("one.mp3", "two.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )

            controller.play_tracks(ids)

            items, index, repeat = backend.queues[-1]
            self.assertEqual([item["track_id"] for item in items], ids)
            self.assertEqual((index, repeat), (0, "off"))
            self.assertEqual(backend.played_at, [0])

            controller.on_loaded()
            controller.on_duration(1_000)
            controller.on_completed()

            # Completion is only an end-of-queue observation for this backend;
            # Python must not issue a second Next decision.
            self.assertEqual(controller.current_track_id, ids[0])
            self.assertFalse(controller.playing)
            self.assertEqual(len(backend.queues), 1)

            controller.on_track_changed(ids[1], 1)

            self.assertEqual(controller.current_track_id, ids[1])
            self.assertTrue(controller.playing)
            self.assertTrue(controller.snapshot.loading)
            self.assertEqual(store.get("playback")["current_index"], 1)

            controller.on_stopped()

            self.assertFalse(controller.playing)
            self.assertFalse(controller.media_session_active)
            self.assertEqual(controller.position_ms, 0)
            self.assertEqual(controller.current_track_id, ids[1])

    def test_native_queue_mutations_are_synchronized_without_reloading(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids: list[str] = []
            for name in ("one.mp3", "two.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )

            controller.play_track(ids[0])
            controller.add_last(ids[1])
            controller.cycle_repeat()

            self.assertEqual(len(backend.queues), 1)
            self.assertEqual(len(backend.queue_updates), 2)
            latest, index, repeat = backend.queue_updates[-1]
            self.assertEqual([item["track_id"] for item in latest], ids)
            self.assertEqual((index, repeat), (0, "track"))

    def test_shuffle_upcoming_updates_native_queue_on_every_tap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids: list[str] = []
            for name in ("one.mp3", "two.mp3", "three.mp3", "four.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.play_tracks(ids)

            with patch("musicplayer.application.queue.random.shuffle"):
                self.assertTrue(controller.shuffle_upcoming())
                self.assertEqual(
                    controller.queue.items, [ids[0], ids[2], ids[3], ids[1]]
                )
                self.assertTrue(controller.shuffle_upcoming())

            self.assertEqual(controller.queue.items, [ids[0], ids[3], ids[1], ids[2]])
            self.assertEqual(len(backend.queues), 1)
            self.assertEqual(len(backend.queue_updates), 2)
            self.assertEqual(
                [item["track_id"] for item in backend.queue_updates[-1][0]],
                controller.queue.items,
            )
            self.assertNotIn("shuffle", controller.queue.to_dict())
            self.assertNotIn("shuffle", store.get("playback"))

    def test_retiring_player_events_cannot_corrupt_native_handoff_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids = []
            for name in ("one.mp3", "two.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                FakeAudioBackend(),
            )

            controller.play_tracks(ids)
            controller.on_position(9_000)
            controller.on_duration(99_000)
            controller.on_playing(False)
            controller.on_completed()

            self.assertEqual(controller.current_track_id, ids[0])
            self.assertEqual(controller.position_ms, 0)
            self.assertEqual(controller.duration_ms, 0)
            self.assertTrue(controller.playing)

            controller.on_loaded()
            controller.on_duration(99_000)
            controller.on_position(9_000)
            self.assertEqual(controller.duration_ms, 99_000)
            self.assertEqual(controller.position_ms, 9_000)

    def test_stop_is_distinct_from_pause_and_terminates_media_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = str(manager.add_track(path, title="Song"))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.play_track(track_id)
            controller.toggle()

            self.assertTrue(controller.media_session_active)
            controller.toggle()
            self.assertTrue(controller.media_session_active)

            controller.stop()

            self.assertFalse(controller.media_session_active)
            self.assertFalse(controller.playing)
            self.assertEqual(controller.current_track_id, track_id)
            self.assertEqual(controller.position_ms, 0)

    def test_bulk_queue_updates_persist_and_notify_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            store = ApplicationStore(root / "state.json")
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )
            controller.queue.replace(["current"])

            with (
                patch.object(controller, "_persist") as persist,
                patch.object(controller, "_notify") as notify,
            ):
                controller.add_next_many(("next-one", "next-two"))
                controller.add_last_many(("last-one", "last-two"))

            self.assertEqual(
                controller.queue.items,
                ["current", "next-one", "next-two", "last-one", "last-two"],
            )
            self.assertEqual(persist.call_count, 2)
            self.assertEqual(notify.call_count, 2)

    def test_library_playback_sends_paths_only_to_the_managed_player(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            next_path = music / "next.mp3"
            next_path.write_bytes(b"next audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            next_id = manager.add_track(next_path, title="Next")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                backend,
            )

            with patch.object(
                Path,
                "read_bytes",
                side_effect=AssertionError("Python must not read managed audio"),
            ):
                controller.play_tracks([str(track_id), str(next_id)])

            items, index, repeat = backend.queues[-1]
            self.assertEqual(
                [item["source"] for item in items],
                [str(path.resolve()), str(next_path.resolve())],
            )
            self.assertEqual((index, repeat), (0, "off"))
            self.assertEqual(backend.source, "")
            self.assertEqual(backend.played_at, [0])

    def test_replacement_cancels_native_preparation_and_installs_new_queue(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids = []
            for name in ("one.mp3", "two.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                backend,
            )

            controller.play_track(ids[0])
            controller.play_track(ids[1])

            self.assertEqual(backend.cancelled_loads, 1)
            self.assertEqual(len(backend.queues), 2)
            items, index, _ = backend.queues[-1]
            self.assertEqual(items[index]["track_id"], ids[1])

    def test_play_tracks_keeps_requested_start_after_filtering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids = []
            for name in ("one.mp3", "two.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )

            controller.play_tracks(["not-a-uuid", ids[0], ids[1]], start_index=1)

            self.assertEqual(controller.current_track_id, ids[0])

    def test_next_at_queue_end_stops_and_rewinds_backend(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.play_tracks([str(track_id)])

            controller.next()

            self.assertFalse(controller.playing)
            self.assertEqual(controller.position_ms, 0)
            self.assertEqual(backend.pause_count, 1)
            self.assertEqual(backend.seeked_to, [0])

    def test_clear_library_state_stops_audio_and_empties_persistent_queue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.play_tracks([str(track_id)])
            controller.position_ms = 400

            controller.clear_library_state()
            controller.clear_library_state()

            self.assertEqual(controller.queue.items, [])
            self.assertEqual(controller.queue.current_index, -1)
            self.assertFalse(controller.playing)
            self.assertEqual(controller.position_ms, 0)
            self.assertEqual(controller.duration_ms, 0)
            self.assertEqual(backend.pause_count, 0)
            self.assertEqual(backend.queue_updates[-1][0], [])
            self.assertEqual(store.get("playback")["queue"], [])

    def test_native_missing_file_error_repairs_optimistic_play_intent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            store.set(
                "playback",
                {
                    "queue": [str(track_id)],
                    "current_index": 0,
                    "position_ms": 1234,
                },
            )
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            path.unlink()

            controller.toggle()
            controller.on_backend_error("native source is missing")

            self.assertFalse(controller.playing)
            self.assertEqual(backend.played_at, [1234])

    def test_restored_queue_discards_invalid_tracks_and_preserves_current(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            store.set(
                "playback",
                {
                    "queue": ["not-a-uuid", str(track_id)],
                    "current_index": 1,
                    "position_ms": 3456,
                    "repeat": "off",
                },
            )

            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )

            self.assertEqual(controller.queue.items, [str(track_id)])
            self.assertEqual(controller.current_track_id, str(track_id))
            self.assertEqual(controller.position_ms, 3456)

    def test_invalid_restored_position_does_not_prevent_startup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            store.set(
                "playback",
                {
                    "queue": [str(track_id)],
                    "current_index": 0,
                    "position_ms": "invalid",
                },
            )

            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )

            self.assertEqual(controller.current_track_id, str(track_id))
            self.assertEqual(controller.position_ms, 0)

    def test_removing_only_current_item_stops_playback_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.play_tracks([str(track_id)])

            controller.remove_queue_item(0)

            self.assertEqual(controller.queue.items, [])
            self.assertFalse(controller.playing)
            self.assertEqual(controller.position_ms, 0)
            self.assertEqual(backend.pause_count, 0)
            self.assertEqual(backend.queue_updates[-1][0], [])

    def test_drag_reorder_persists_and_preserves_current_track(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids = []
            for name in ("one.mp3", "two.mp3", "three.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )
            controller.queue.replace(ids, start_index=1)

            controller.reorder_queue(0, 3)

            self.assertEqual(controller.queue.items, [ids[1], ids[2], ids[0]])
            self.assertEqual(controller.current_track_id, ids[1])
            self.assertEqual(store.get("playback")["queue"], controller.queue.items)

    def test_playing_a_queue_row_does_not_reshuffle_the_queue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            manager = MusicManager(root / "library.mmdb", music)
            ids = []
            for name in ("one.mp3", "two.mp3", "three.mp3"):
                path = music / name
                path.write_bytes(name.encode())
                ids.append(str(manager.add_track(path, title=name)))
            store = ApplicationStore(root / "state.json")
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )
            controller.queue.replace(ids)
            controller.play_queue_index(2)

            self.assertEqual(controller.queue.items, ids)
            self.assertEqual(controller.current_track_id, ids[2])

    def test_restored_queue_loads_source_before_resuming(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            settings = store.settings
            settings.download_directory = str(music)
            settings.resume_session = True
            store.save_settings(settings)
            store.set(
                "playback",
                {
                    "queue": [str(track_id)],
                    "current_index": 0,
                    "position_ms": 3456,
                    "repeat": "off",
                },
            )
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )

            controller.toggle()

            items, index, _ = backend.queues[-1]
            self.assertEqual(items[index]["source"], str(path.resolve()))
            self.assertEqual(backend.source, "")
            self.assertEqual(backend.played_at, [3456])

    def test_seek_before_source_load_updates_resume_position_locally(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = str(manager.add_track(path, title="Song"))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.queue.replace([track_id])

            controller.seek(4_567)

            self.assertEqual(controller.position_ms, 4_567)
            self.assertEqual(backend.seeked_to, [])
            controller.toggle()
            self.assertEqual(backend.played_at, [4_567])

    def test_timeline_events_and_seeks_are_clamped_to_duration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = str(manager.add_track(path, title="Song"))
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.play_track(track_id)
            controller.on_loaded()
            controller.on_duration(1_000)

            controller.seek(2_000)
            controller.on_position(1_500)

            self.assertEqual(controller.position_ms, 1_000)
            self.assertEqual(backend.seeked_to, [1_000])
            controller.on_duration(500)
            self.assertEqual(controller.position_ms, 500)
            self.assertEqual(store.get("playback")["position_ms"], 500)

    def test_mute_restores_previous_exact_volume(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manager = MusicManager(root / "library.mmdb", root / "music")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, backend
            )
            controller.set_volume(41)
            controller.toggle_mute()
            self.assertEqual(backend.volume, 0.0)
            controller.toggle_mute()
            self.assertEqual(controller.volume, 41)
            self.assertEqual(backend.volume, 0.41)

    def test_volume_preview_skips_persistence_until_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manager = MusicManager(root / "library.mmdb", root / "music")
            store = ApplicationStore(root / "state.json")
            changes: list[str] = []
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                FakeAudioBackend(),
                on_change=changes.append,
            )

            with patch.object(store, "save_settings") as save_settings:
                controller.set_volume(35, persist=False)
                controller.set_volume(35)

            self.assertEqual(save_settings.call_count, 1)
            self.assertEqual(changes, ["volume", "volume"])

    def test_position_event_requests_only_a_progress_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manager = MusicManager(root / "library.mmdb", root / "music")
            store = ApplicationStore(root / "state.json")
            changes: list[str] = []
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                FakeAudioBackend(),
                on_change=changes.append,
            )

            controller._last_persisted_position = time.monotonic()
            controller.on_position(500)

            self.assertEqual(changes, ["progress"])

    def test_backend_failure_repairs_loaded_state_and_next_toggle_reloads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            errors: list[str] = []
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                backend,
                on_error=errors.append,
            )
            controller.play_track(str(track_id))

            controller.on_backend_error("native load failed")

            self.assertFalse(controller.playing)
            self.assertFalse(controller._source_loaded)
            self.assertEqual(errors, ["native load failed"])
            self.assertEqual(store.track_details(str(track_id)).play_count, 0)
            controller.toggle()
            self.assertEqual(backend.played_at, [0, 0])
            controller.on_loaded()
            controller.on_playing(True)
            self.assertEqual(store.track_details(str(track_id)).play_count, 1)

    def test_backend_failure_discards_pending_managed_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            backend = FakeAudioBackend()
            controller = PlaybackController(
                manager,
                LibraryService(manager, store),
                store,
                backend,
            )

            controller.play_track(str(track_id))
            controller.on_backend_error("native load failed")

            self.assertEqual(backend.discarded_sources, 1)
            self.assertFalse(controller._loading)
            self.assertFalse(controller.snapshot.loading)
            self.assertFalse(controller._source_loaded)

    def test_native_playing_event_clears_missing_loaded_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            music = root / "music"
            music.mkdir()
            path = music / "song.mp3"
            path.write_bytes(b"audio")
            manager = MusicManager(root / "library.mmdb", music)
            track_id = manager.add_track(path, title="Song")
            store = ApplicationStore(root / "state.json")
            controller = PlaybackController(
                manager, LibraryService(manager, store), store, FakeAudioBackend()
            )

            controller.play_track(str(track_id))
            self.assertTrue(controller.snapshot.loading)

            controller.on_playing(True)

            self.assertTrue(controller.playing)
            self.assertFalse(controller.snapshot.loading)


if __name__ == "__main__":
    unittest.main()
