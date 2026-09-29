from __future__ import annotations

import unittest
from unittest.mock import patch

from musicplayer.application.models import RepeatMode
from musicplayer.application.queue import PlaybackQueue


class PlaybackQueueTests(unittest.TestCase):
    def test_play_next_and_append_are_distinct(self) -> None:
        queue = PlaybackQueue()
        queue.replace(["a", "b"])
        queue.add_next("next")
        queue.add_last("last")
        self.assertEqual(queue.items, ["a", "next", "b", "last"])

    def test_move_preserves_current_track(self) -> None:
        queue = PlaybackQueue(["a", "b", "c"], current_index=1)
        queue.move(0, 2)
        self.assertEqual(queue.current, "b")

    def test_move_preserves_the_current_duplicate_instance(self) -> None:
        queue = PlaybackQueue(["a", "b", "a"], current_index=2)
        queue.move(0, 1)
        self.assertEqual(queue.items, ["b", "a", "a"])
        self.assertEqual(queue.current_index, 2)

    def test_repeat_track_and_playlist(self) -> None:
        queue = PlaybackQueue(["a", "b"], current_index=1, repeat=RepeatMode.TRACK)
        self.assertEqual(queue.next_index(automatic=True), 1)
        self.assertEqual(queue.next(automatic=True), "b")
        queue.repeat = RepeatMode.PLAYLIST
        self.assertEqual(queue.next_index(automatic=True), 0)
        self.assertEqual(queue.next(automatic=True), "a")
        queue.repeat = RepeatMode.OFF
        queue.current_index = 1
        self.assertIsNone(queue.next_index(automatic=True))

    def test_round_trip(self) -> None:
        original = PlaybackQueue(["a", "b"], 1, RepeatMode.PLAYLIST)
        restored = PlaybackQueue.from_dict(original.to_dict(position_ms=3456))
        self.assertEqual(restored.items, original.items)
        self.assertEqual(restored.current, "b")
        self.assertNotIn("shuffle", restored.to_dict())
        self.assertEqual(restored.repeat, RepeatMode.PLAYLIST)

    def test_invalid_persisted_queue_fields_do_not_break_restore(self) -> None:
        restored = PlaybackQueue.from_dict(
            {
                "queue": ["valid", None, ""],
                "current_index": "invalid",
                "repeat": [],
            }
        )
        self.assertEqual(restored.items, ["valid"])
        self.assertEqual(restored.current_index, 0)
        self.assertEqual(restored.repeat, RepeatMode.OFF)
        self.assertEqual(PlaybackQueue.from_dict({"queue": "not a list"}).items, [])

    def test_shuffle_reorders_only_upcoming_tracks(self) -> None:
        queue = PlaybackQueue(["a", "b", "c", "d"], current_index=1)

        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ) as shuffle:
            queue.shuffle_upcoming()

        shuffle.assert_called_once()
        self.assertEqual(queue.items, ["a", "b", "d", "c"])
        self.assertEqual(queue.current, "b")

    def test_shuffle_upcoming_reshuffles_on_each_tap(self) -> None:
        queue = PlaybackQueue(["a", "b", "c", "d"], current_index=0)
        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ) as shuffle:
            self.assertTrue(queue.shuffle_upcoming())
            self.assertEqual(queue.items, ["a", "d", "c", "b"])
            self.assertTrue(queue.shuffle_upcoming())

        self.assertEqual(queue.items, ["a", "b", "c", "d"])
        self.assertNotIn("shuffle", queue.to_dict())
        self.assertEqual(queue.current, "a")
        self.assertEqual(shuffle.call_count, 2)

    def test_shuffle_upcoming_does_nothing_with_one_remaining(self) -> None:
        queue = PlaybackQueue(["a", "b"], current_index=0)
        with patch("musicplayer.application.queue.random.shuffle") as shuffle:
            self.assertFalse(queue.shuffle_upcoming())
        shuffle.assert_not_called()

    def test_shuffle_upcoming_changes_order_if_random_returns_same_order(self) -> None:
        queue = PlaybackQueue(["a", "b", "c", "d"], current_index=0)
        with patch("musicplayer.application.queue.random.shuffle"):
            self.assertTrue(queue.shuffle_upcoming())
        self.assertEqual(queue.items, ["a", "c", "d", "b"])

    def test_shuffle_preload_prediction_is_the_next_selected_track(self) -> None:
        queue = PlaybackQueue(["a", "b", "c", "d"], current_index=1)
        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ):
            queue.shuffle_upcoming()

        predicted = queue.peek_next()

        self.assertEqual(predicted, "d")
        self.assertEqual(queue.next(), predicted)

    def test_shuffle_navigation_follows_visible_reordered_queue(self) -> None:
        queue = PlaybackQueue(["a", "b", "c"], current_index=0)
        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ):
            queue.shuffle_upcoming()

        self.assertEqual(queue.items, ["a", "c", "b"])
        self.assertEqual(queue.next(), "c")
        self.assertEqual(queue.next(), "b")
        self.assertEqual(queue.previous(), "c")

    def test_explicit_shuffled_replacement_reorders_the_whole_queue(self) -> None:
        queue = PlaybackQueue()
        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ):
            queue.replace(["a", "b", "c"], shuffle_once=True)

        self.assertEqual(queue.items, ["c", "b", "a"])
        self.assertEqual(queue.current, "c")

    def test_shuffled_collection_does_not_change_later_queue_replacements(self) -> None:
        queue = PlaybackQueue()
        with patch(
            "musicplayer.application.queue.random.shuffle",
            side_effect=lambda items: items.reverse(),
        ) as shuffle:
            queue.replace(["a", "b", "c"], shuffle_once=True)
            queue.replace(["x", "y", "z"])

        self.assertEqual(queue.items, ["x", "y", "z"])
        shuffle.assert_called_once()

    def test_legacy_shuffle_flag_is_ignored_on_restore(self) -> None:
        queue = PlaybackQueue.from_dict(
            {"queue": ["a", "b"], "current_index": 0, "shuffle": True}
        )
        self.assertNotIn("shuffle", queue.to_dict())
        with patch("musicplayer.application.queue.random.shuffle") as shuffle:
            queue.replace(["x", "y"])
        shuffle.assert_not_called()

    def test_play_next_stays_next_after_shuffle_reorder(self) -> None:
        queue = PlaybackQueue(["a", "b", "c"], current_index=0)

        queue.add_next("requested")

        self.assertEqual(queue.next(), "requested")


if __name__ == "__main__":
    unittest.main()
