from __future__ import annotations

import unittest

from musicplayer.application.models import RepeatMode
from musicplayer.application.queue import PlaybackQueue
from musicplayer.ui.components.queue_status import (
    queue_item_status,
    queue_mode_status,
)


class QueueStatusTests(unittest.TestCase):
    def test_statuses_follow_the_real_repeat_order(self) -> None:
        queue = PlaybackQueue(
            ["first", "middle", "last"],
            current_index=2,
            repeat=RepeatMode.PLAYLIST,
        )

        self.assertEqual(queue_mode_status(queue).label, "Repeat queue")
        self.assertEqual(queue_item_status(queue, 0), "Up next · Queue loops here")
        self.assertEqual(queue_item_status(queue, 2), "Now playing")

        queue.current_index = 1
        queue.repeat = RepeatMode.TRACK
        self.assertEqual(queue_mode_status(queue).label, "Repeat track")
        self.assertEqual(
            queue_item_status(queue, 1), "Now playing · Repeats continuously"
        )
        self.assertEqual(queue_item_status(queue, 2), "Waiting · Repeat track is on")


if __name__ == "__main__":
    unittest.main()
