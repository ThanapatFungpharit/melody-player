from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from musicplayer.app import MusicPlayerApp
from musicplayer.core.library import MusicManager


class AndroidMusicExportTests(unittest.TestCase):
    def test_public_copy_becomes_canonical_before_private_copy_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / "data" / "Music"
            public = root / "shared" / "Music" / "Melody"
            private.mkdir(parents=True)
            public.mkdir(parents=True)
            source = private / "song.mp3"
            source.write_bytes(b"audio")
            published = public / "song.mp3"
            published.write_bytes(source.read_bytes())
            manager = MusicManager(
                root / "data" / "library.mmdb",
                private,
                additional_music_folders=(public,),
            )
            track_id = str(manager.add_track(source, title="Song"))
            app = MusicPlayerApp.__new__(MusicPlayerApp)
            app.manager = manager

            with patch("musicplayer.app.public_music_directory", return_value=public):
                old_source = app._adopt_published_track(track_id, source, published)

            self.assertEqual(old_source, source)
            self.assertEqual(manager.track_path(track_id), published.resolve())
            self.assertTrue(source.exists())
            app._remove_unreferenced_file(source)
            self.assertFalse(source.exists())
            self.assertEqual(published.read_bytes(), b"audio")


if __name__ == "__main__":
    unittest.main()
