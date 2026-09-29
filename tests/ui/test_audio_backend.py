from __future__ import annotations

import asyncio
import inspect
import unittest
from concurrent.futures import Future
from types import SimpleNamespace
from typing import Any, cast
from unittest.mock import AsyncMock, Mock, patch

from flet.controls.control_event import get_event_field_type
from flet_background_audio import (
    BackgroundAudioSession,
    ManagedAudio,
    ManagedAudioDurationChangeEvent,
    ManagedAudioErrorEvent,
    ManagedAudioTrackChangeEvent,
)

from musicplayer.app import MusicPlayerApp
from musicplayer.ui.audio_backend import ManagedAudioBackend


class FakePage:
    def __init__(self) -> None:
        self.services: list[Any] = []
        self.scheduled: list[tuple[Any, tuple[Any, ...]]] = []
        self.futures: list[Future[Any]] = []
        self.update_count = 0
        self.web = False

    def update(self, *_: Any) -> None:
        self.update_count += 1

    def run_task(self, handler: Any, *args: Any) -> Future[Any]:
        self.scheduled.append((handler, args))
        future: Future[Any] = Future()
        self.futures.append(future)
        return future


class ManagedAudioBackendTests(unittest.TestCase):
    def test_media_session_defaults_hide_unavailable_skip_actions(self) -> None:
        session = BackgroundAudioSession()
        invoke = AsyncMock()
        with patch.object(session, "_invoke_method", invoke):
            asyncio.run(session.sync(title="Track"))

        self.assertEqual(invoke.call_args.args[0], "sync")
        payload = invoke.call_args.args[1]
        self.assertFalse(payload["has_next"])
        self.assertFalse(payload["has_previous"])

    def test_managed_queue_rejects_rows_missing_required_keys(self) -> None:
        audio = ManagedAudio()
        malformed = [{"id": "one", "url": "one.mp3"}]

        with self.assertRaisesRegex(
            ValueError, "Queue item 0 requires a nonempty track_id"
        ):
            asyncio.run(audio.set_queue(malformed, 0, 1, "off"))
        with self.assertRaisesRegex(
            ValueError, "Queue item 0 requires a nonempty track_id"
        ):
            asyncio.run(audio.update_queue(malformed, 0, "off"))

    def test_managed_queue_rejects_invalid_repeat_and_generation(self) -> None:
        audio = ManagedAudio()
        items = [{"track_id": "one", "source": "one.mp3"}]

        with self.assertRaisesRegex(ValueError, "Invalid repeat mode"):
            asyncio.run(audio.set_queue(items, 0, 2, "unknown"))
        with self.assertRaisesRegex(ValueError, "generations must be"):
            asyncio.run(audio.set_queue(items, 0, 3, "off"))

    def test_source_selection_carries_play_intent_and_position(self) -> None:
        audio = ManagedAudio()
        invoke = AsyncMock()
        with patch.object(audio, "_invoke_method", invoke):
            asyncio.run(
                audio.set_queue(
                    [{"track_id": "one", "source": "one.mp3"}],
                    0,
                    4,
                    "off",
                    autoplay=True,
                    position_ms=12_000,
                )
            )
        self.assertEqual(invoke.call_args.args[0], "set_queue")
        payload = invoke.call_args.args[1]
        self.assertTrue(payload["autoplay"])
        self.assertEqual(payload["position_ms"], 12_000)

    def test_custom_duration_event_annotation_resolves_in_flet(self) -> None:
        """Native duration events must be deserializable in packaged runtimes."""
        audio = ManagedAudio()

        self.assertIs(
            get_event_field_type(audio, "on_duration_change"),
            ManagedAudioDurationChangeEvent,
        )
        self.assertIs(
            get_event_field_type(audio, "on_track_change"),
            ManagedAudioTrackChangeEvent,
        )
        self.assertIs(
            get_event_field_type(audio, "on_error"),
            ManagedAudioErrorEvent,
        )

    def test_native_queue_is_installed_as_one_generation_scoped_operation(self):
        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]
        items = [
            {"track_id": "one", "source": "one.mp3"},
            {"track_id": "two", "source": "two.mp3"},
        ]

        backend.set_queue(
            items,
            1,
            repeat_mode="playlist",
        )
        backend.play(250)

        self.assertEqual(len(page.scheduled), 2)  # set_queue RPC + watchdog
        operation, args, generation = page.scheduled[0][1]
        self.assertEqual(operation.__self__, backend.audio)
        self.assertEqual(args, (items, 1, 2, "playlist", False, 0))
        self.assertEqual(generation, 2)
        self.assertEqual(backend._pending_play_position, 250)

    def test_native_track_change_adopts_generation_before_followup_events(self):
        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]
        changed: list[tuple[str, int]] = []
        stopped: list[bool] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
            on_track_changed=lambda track_id, index: changed.append((track_id, index)),
            on_stopped=lambda: stopped.append(True),
        )

        backend._track_changed(
            cast(
                ManagedAudioTrackChangeEvent,
                SimpleNamespace(track_id="next", index=1, generation=1),
            )
        )

        self.assertEqual(backend._generation, 1)
        self.assertFalse(backend._loaded)
        self.assertEqual(changed, [("next", 1)])
        self.assertEqual(len(page.scheduled), 1)  # native transition watchdog

        backend._state_changed(
            cast(
                Any,
                SimpleNamespace(state="stopped", generation=1),
            ),
            1,
        )
        self.assertEqual(stopped, [True])

    def test_python_selection_after_native_transition_uses_next_even_generation(self):
        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]
        backend._track_changed(
            cast(
                ManagedAudioTrackChangeEvent,
                SimpleNamespace(track_id="next", index=1, generation=3),
            )
        )

        backend.load("selected.mp3")
        self.assertEqual(backend._generation, 4)
        self.assertEqual(page.scheduled[-2][1][-1], 4)

    def test_phone_gain_uses_system_volume_while_desktop_keeps_precise_gain(self):
        for mobile, expected in ((True, 1.0), (False, 0.25)):
            backend = ManagedAudioBackend(FakePage(), use_device_volume=mobile)  # ty: ignore[invalid-argument-type]
            backend.set_volume(0.25)
            self.assertEqual(backend._volume, expected)
            backend.set_volume(0)
            self.assertEqual(backend._volume, 0)
            backend.set_volume(0.25)
            self.assertEqual(backend._volume, expected)

    def test_play_waits_for_loaded_event_and_operations_use_page_loop(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]

        backend.load(b"audio bytes")
        backend.play(1250)

        # The long-lived service receives an async source-load RPC and a load
        # watchdog; play remains pending until native preparation completes.
        self.assertEqual(len(page.scheduled), 2)
        backend._loaded_event(2)
        self.assertTrue(page.futures[1].cancelled())
        backend.pause()
        backend.resume()
        backend.seek(2500)
        backend.close()

        self.assertEqual(len(page.scheduled), 6)
        self.assertTrue(
            all(inspect.iscoroutinefunction(handler) for handler, _ in page.scheduled)
        )
        play_operation = page.scheduled[2][1]
        seek_operation = page.scheduled[5][1]
        self.assertEqual(play_operation[1], (1250,))
        self.assertEqual(seek_operation[1], (2500,))

    def test_track_switch_keeps_services_mounted_and_avoids_page_update(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        mounted_services = tuple(page.services)

        backend.load(b"first")
        backend._loaded_event(2)
        backend.load(b"second")
        backend.pause()

        self.assertEqual(tuple(page.services), mounted_services)
        self.assertEqual(len(page.services), 3)
        self.assertEqual(page.update_count, 0)
        self.assertIs(
            page.scheduled[-1][0].__func__, ManagedAudioBackend._run_transport_operation
        )

    def test_web_uses_package_owned_audio_without_platform_services(self) -> None:
        page = FakePage()
        page.web = True
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]

        self.assertEqual(page.services, [backend.audio])
        backend.load(b"web audio")
        backend.play(1_250)

        self.assertEqual(len(page.services), 1)
        self.assertIs(type(backend.audio), ManagedAudio)
        self.assertEqual(page.update_count, 0)
        self.assertEqual(len(page.scheduled), 2)  # load RPC and watchdog

        loaded = backend.audio.on_loaded
        assert loaded is not None
        cast(Any, loaded)(SimpleNamespace(generation=2))

        self.assertTrue(page.futures[1].cancelled())
        self.assertEqual(len(page.scheduled), 3)
        self.assertIs(
            page.scheduled[-1][0].__func__,
            ManagedAudioBackend._run_transport_operation,
        )

    def test_web_skips_platform_media_session_and_storage_services(self) -> None:
        page = FakePage()
        page.web = True
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]

        backend.sync_media_session(title="Web track", playing=True)

        self.assertEqual(page.services, [backend.audio])
        self.assertEqual(page.scheduled, [])

    def test_failed_service_reports_once_without_recursive_cleanup_rpc(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]
        errors: list[str] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
            on_error=errors.append,
        )

        async def fail() -> None:
            raise RuntimeError("method listener missing")

        asyncio.run(backend._run_operation(fail, (), backend._generation))
        backend.discard_source()

        self.assertEqual(len(errors), 1)
        self.assertEqual(page.scheduled, [])

    def test_obsolete_native_generation_events_are_rejected(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        positions: list[int] = []
        backend.bind(
            on_position=positions.append,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
        )
        backend.load("first.mp3")
        backend.load("second.mp3")
        assert backend.audio is not None
        position_handler = backend.audio.on_position_change
        assert position_handler is not None

        cast(Any, position_handler)(SimpleNamespace(position=1_000, generation=2))
        self.assertEqual(positions, [])
        cast(Any, position_handler)(SimpleNamespace(position=2_000, generation=4))
        self.assertEqual(positions, [2_000])

    def test_replayed_source_can_complete_again_without_reloading(self) -> None:
        backend = ManagedAudioBackend(FakePage())  # ty: ignore[invalid-argument-type]
        completed: list[bool] = []
        playing: list[bool] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=playing.append,
            on_completed=lambda: completed.append(True),
        )
        completion = SimpleNamespace(state="completed", generation=0)

        backend._state_changed(cast(Any, completion), 0)
        backend._state_changed(cast(Any, completion), 0)  # duplicate native event
        backend._state_changed(  # native replay confirmation
            cast(Any, SimpleNamespace(state="playing", generation=0)), 0
        )
        backend._state_changed(cast(Any, completion), 0)

        self.assertEqual(completed, [True, True])
        self.assertEqual(playing, [True])

    def test_media_session_updates_each_second(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]

        backend.sync_media_session(
            title="Track",
            artist="Artist",
            artwork_uri="https://example.test/cover.jpg",
            duration_ms=180_000,
            position_ms=1_000,
            playing=True,
        )
        backend.sync_media_session(
            title="Track",
            artist="Artist",
            artwork_uri="https://example.test/cover.jpg",
            duration_ms=180_000,
            position_ms=2_000,
            playing=True,
        )
        backend.sync_media_session(
            title="Track",
            artist="Artist",
            artwork_uri="https://example.test/cover.jpg",
            duration_ms=180_000,
            position_ms=5_000,
            playing=True,
        )

        self.assertEqual(len(page.scheduled), 3)
        first_payload = page.scheduled[0][1][1]
        second_payload = page.scheduled[1][1][1]
        third_payload = page.scheduled[2][1][1]
        self.assertEqual(first_payload["position_ms"], 1_000)
        self.assertEqual(second_payload["position_ms"], 2_000)
        self.assertEqual(third_payload["position_ms"], 5_000)

    def test_repeat_shuffle_and_favorite_changes_refresh_media_actions(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]

        backend.sync_media_session(
            title="Track",
            repeat_mode="off",
            can_repeat=True,
            can_shuffle=False,
            can_favorite=True,
            favorite=False,
        )
        backend.sync_media_session(
            title="Track",
            repeat_mode="track",
            can_repeat=True,
            can_shuffle=True,
            can_favorite=True,
            favorite=True,
            notification_action_pair="shuffle_repeat",
            auto_focal_point_live_notifications=True,
        )

        self.assertEqual(len(page.scheduled), 2)
        payload = page.scheduled[-1][1][1]
        self.assertEqual(payload["repeat_mode"], "track")
        self.assertTrue(payload["can_repeat"])
        self.assertTrue(payload["can_shuffle"])
        self.assertTrue(payload["can_favorite"])
        self.assertTrue(payload["favorite"])
        self.assertEqual(payload["notification_action_pair"], "shuffle_repeat")
        self.assertTrue(payload["auto_focal_point_live_notifications"])

    def test_failed_media_session_update_can_be_retried(self) -> None:
        class FailingSession:
            async def sync(self, **_: object) -> None:
                raise ValueError("native session is not ready")

            async def deactivate(self) -> None:
                pass

        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        backend.media_session = FailingSession()  # ty: ignore[invalid-assignment]

        backend.sync_media_session(title="Track", playing=True)
        generation, payload, snapshot = page.scheduled[0][1]
        asyncio.run(backend._run_media_sync(generation, payload, snapshot))

        self.assertIsNone(backend._media_snapshot)
        self.assertIsNone(backend._media_pending_snapshot)

        # The same state must be schedulable again after a transient native
        # failure; otherwise the lock screen can remain stale indefinitely.
        backend.sync_media_session(title="Track", playing=True)
        self.assertEqual(len(page.scheduled), 2)

    def test_media_session_snapshot_commits_only_after_success(self) -> None:
        class WorkingSession:
            async def sync(self, **_: object) -> None:
                pass

            async def deactivate(self) -> None:
                pass

        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        backend.media_session = WorkingSession()  # ty: ignore[invalid-assignment]

        backend.sync_media_session(title="Track", playing=False)
        generation, payload, snapshot = page.scheduled[0][1]
        asyncio.run(backend._run_media_sync(generation, payload, snapshot))

        backend.sync_media_session(title="Track", playing=False)
        self.assertEqual(len(page.scheduled), 1)

        backend.invalidate_media_session()
        backend.sync_media_session(title="Track", playing=False)
        self.assertEqual(len(page.scheduled), 2)
        self.assertTrue(page.scheduled[-1][1][1]["reattach"])

    def test_return_to_committed_state_supersedes_pending_media_sync(self) -> None:
        class RecordingSession:
            def __init__(self) -> None:
                self.states: list[bool] = []

            async def sync(self, **payload: object) -> None:
                self.states.append(bool(payload["playing"]))

            async def deactivate(self) -> None:
                pass

        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]
        session = RecordingSession()
        backend.media_session = session  # ty: ignore[invalid-assignment]

        backend.sync_media_session(title="Track", playing=True)
        asyncio.run(backend._run_media_sync(*page.scheduled[-1][1]))
        backend.sync_media_session(title="Track", playing=False)
        backend.sync_media_session(title="Track", playing=True)

        self.assertEqual(len(page.scheduled), 3)
        stale_sync = page.scheduled[1][1]
        latest_sync = page.scheduled[2][1]
        asyncio.run(backend._run_media_sync(*stale_sync))
        asyncio.run(backend._run_media_sync(*latest_sync))
        self.assertEqual(session.states, [True, True])
        self.assertEqual(backend._media_snapshot, latest_sync[2])

    def test_pause_keeps_media_session_metadata_until_explicit_stop(self) -> None:
        class SessionBackend:
            def __init__(self) -> None:
                self.payloads: list[dict[str, object]] = []

            def sync_media_session(self, **payload: object) -> None:
                self.payloads.append(payload)

        queue = SimpleNamespace(
            items=["queued-track"],
            peek_next=lambda **_: None,
            repeat=SimpleNamespace(value="off"),
        )
        playback = SimpleNamespace(
            external_title="Preview",
            external_uploader="Artist",
            external_thumbnail="",
            current_track_id=None,
            media_session_active=True,
            duration_ms=10_000,
            position_ms=2_000,
            playing=False,
            snapshot=SimpleNamespace(loading=False),
            queue=queue,
        )
        app = object.__new__(MusicPlayerApp)
        app.playback = playback  # type: ignore[assignment]  # ty: ignore[invalid-assignment]
        app.settings = SimpleNamespace(notification_action_pair="shuffle_favorite")  # ty: ignore[invalid-assignment]
        session_backend = SessionBackend()
        app.backend = session_backend  # type: ignore[assignment]  # ty: ignore[invalid-assignment]
        app._system_media_key = None
        app._system_media_metadata = ("", "", "", "")

        app._sync_system_media()
        self.assertEqual(session_backend.payloads[-1]["title"], "Preview")
        self.assertFalse(session_backend.payloads[-1]["playing"])
        self.assertTrue(session_backend.payloads[-1]["keep_alive"])

        playback.media_session_active = False
        app._sync_system_media(refresh_metadata=False)
        self.assertEqual(session_backend.payloads[-1]["title"], "")
        self.assertFalse(session_backend.payloads[-1]["keep_alive"])

    def test_refresh_state_publishes_native_position_duration_and_playing(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        assert isinstance(backend.audio, ManagedAudio)

        async def get_playback_state() -> dict[str, int | bool]:
            return {
                "position_ms": 12_345,
                "duration_ms": 180_000,
                "playing": True,
            }

        backend.audio.get_playback_state = get_playback_state  # ty: ignore[invalid-assignment]
        backend._loaded = True
        positions: list[int] = []
        durations: list[int] = []
        playing: list[bool] = []
        backend.bind(
            on_position=positions.append,
            on_duration=durations.append,
            on_playing=playing.append,
            on_completed=lambda: None,
        )

        asyncio.run(backend._refresh_state(backend._generation))

        self.assertEqual(positions, [12_345])
        self.assertEqual(durations, [180_000])
        self.assertEqual(playing, [True])

    def test_reattach_adopts_native_runtime_without_loading_again(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # ty: ignore[invalid-argument-type]
        state: dict[str, Any] = {
            "track_id": "saved-track",
            "source": "saved.mp3",
            "generation": 7,
            "position_ms": 42_000,
            "duration_ms": 180_000,
            "playing": True,
        }
        backend.audio.get_playback_state = AsyncMock(return_value=state)
        adopted: list[dict[str, Any]] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
            on_native_reattach=adopted.append,
        )

        asyncio.run(backend.reattach_native_state())

        self.assertEqual(adopted, [state])
        self.assertEqual(backend._generation, 7)
        self.assertTrue(backend._loaded)
        self.assertTrue(backend._media_reattach_pending)
        self.assertEqual(page.scheduled, [])

    def test_stale_native_error_does_not_clear_new_source(self) -> None:
        backend = ManagedAudioBackend(FakePage())  # ty: ignore[invalid-argument-type]
        errors: list[str] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
            on_error=errors.append,
        )
        backend.load("first.mp3")
        backend.load("second.mp3")
        handler = backend.audio.on_error
        assert handler is not None

        cast(Any, handler)(SimpleNamespace(message="old failure", generation=2))
        self.assertEqual(errors, [])
        cast(Any, handler)(SimpleNamespace(message="current failure", generation=4))
        self.assertEqual(errors, ["current failure"])

    def test_native_media_action_is_forwarded_to_controller_callback(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        received: list[tuple[str, int | None]] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
            on_media_action=lambda action, position: received.append(
                (action, position)
            ),
        )

        event = SimpleNamespace(
            action="seekTo",
            seek_position_ms=42_000,
        )
        backend._media_action(event)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]

        self.assertEqual(received, [("seekTo", 42_000)])

    def test_every_audio_failure_is_forwarded_for_state_repair(self) -> None:
        page = FakePage()
        backend = ManagedAudioBackend(page)  # type: ignore[arg-type]  # ty: ignore[invalid-argument-type]
        errors: list[str] = []
        backend.bind(
            on_position=lambda _: None,
            on_duration=lambda _: None,
            on_playing=lambda _: None,
            on_completed=lambda: None,
            on_error=errors.append,
        )

        backend._report_error("first")
        backend._report_error("second")

        self.assertEqual(errors, ["first", "second"])

    def test_native_media_actions_map_to_idempotent_playback_commands(self) -> None:
        class FakePlayback:
            def __init__(self) -> None:
                self.playing = False
                self.position_ms = 30_000
                self.calls: list[tuple[str, int | None]] = []

            def toggle(self) -> None:
                self.playing = not self.playing
                self.calls.append(("toggle", None))

            def next(self) -> None:
                self.calls.append(("next", None))

            def previous(self) -> None:
                self.calls.append(("previous", None))

            def seek(self, position_ms: int) -> None:
                self.position_ms = position_ms
                self.calls.append(("seek", position_ms))

            def stop(self) -> None:
                self.playing = False
                self.position_ms = 0
                self.calls.append(("stop", None))

        playback = FakePlayback()
        app = object.__new__(MusicPlayerApp)
        app.playback = playback  # type: ignore[assignment]  # ty: ignore[invalid-assignment]

        app._media_action("play", None)
        app._media_action("play", None)
        app._media_action("pause", None)
        app._media_action("pause", None)
        app._media_action("skipToNext", None)
        app._media_action("skipToPrevious", None)
        app._media_action("seekTo", 42_000)
        app._media_action("rewind", None)
        app._media_action("fastForward", None)
        playback.playing = True
        app._media_action("stop", None)

        self.assertEqual(
            playback.calls,
            [
                ("toggle", None),
                ("toggle", None),
                ("next", None),
                ("previous", None),
                ("seek", 42_000),
                ("seek", 32_000),
                ("seek", 42_000),
                ("stop", None),
            ],
        )

    def test_notification_repeat_shuffle_and_favorite_actions_target_current_track(
        self,
    ) -> None:
        app = object.__new__(MusicPlayerApp)
        repeat_action = Mock()
        shuffle_action = Mock()
        favorite_action = Mock()
        app.playback = SimpleNamespace(  # ty: ignore[invalid-assignment]
            media_session_active=True,
            queue=SimpleNamespace(items=["track"]),
            current_track_id="track",
            external_title="",
            cycle_repeat=repeat_action,
            shuffle_upcoming=shuffle_action,
        )
        app.library_page = SimpleNamespace(_toggle_favorite=favorite_action)  # ty: ignore[invalid-assignment]

        app._media_action("cycleRepeat", None)
        app._media_action("shuffleUpcoming", None)
        app._media_action("toggleFavorite", None)

        repeat_action.assert_called_once_with()
        shuffle_action.assert_called_once_with()
        favorite_action.assert_called_once_with("track")

        app.playback.external_title = "Preview"
        app._media_action("shuffleUpcoming", None)
        app._media_action("toggleFavorite", None)
        shuffle_action.assert_called_once_with()
        favorite_action.assert_called_once_with("track")


if __name__ == "__main__":
    unittest.main()
