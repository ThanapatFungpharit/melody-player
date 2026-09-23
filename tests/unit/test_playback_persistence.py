from __future__ import annotations

import unittest
from unittest import mock

from musicplayer.application.playback_persistence import PlaybackPersistence


class PlaybackPersistenceTests(unittest.TestCase):
    def test_repeated_play_moves_track_to_latest_coalesced_position(self) -> None:
        store = mock.Mock()
        persistence = PlaybackPersistence(store, mock.Mock())
        try:
            with mock.patch.object(persistence, "_start_locked"):
                persistence.record_play("A")
                persistence.record_play("B")
                persistence.record_play("A")

            persistence._drain()

            store.save_playback_updates.assert_called_once_with({}, {"B": 1, "A": 2})
        finally:
            persistence.close(wait=True)


if __name__ == "__main__":
    unittest.main()
