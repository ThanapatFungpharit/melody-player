from __future__ import annotations

import sqlite3
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from musicplayer.application.library_service import LibraryService
from musicplayer.application.store import ApplicationStore
from musicplayer.core.library import MusicManager
from musicplayer.core.library.config import HEADER, MAGIC, TRACK_FIXED, U32, UUID_ONLY
from musicplayer.core.library.manager import _copy_track
from musicplayer.core.storage import DatabaseError
from tests.storage_support import DataDirectory


class MusicManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = DataDirectory()
        self.root = Path(self.temporary.name)
        self.music = self.root / "music"
        self.music.mkdir()
        self.manager = MusicManager(self.root / "library.db", self.music)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def add_track(self, name: str, source: str = ""):
        path = self.music / name
        path.write_bytes(f"audio:{name}".encode())
        return self.manager.add_track(path, source=source, title=Path(name).stem)

    def test_tracks_and_playlist_order_survive_restart(self) -> None:
        first = self.add_track("first.mp3")
        second = self.add_track("second.mp3")
        playlist = self.manager.create_playlist("Focus")
        self.manager.add_to_playlist(playlist, first)
        self.manager.add_to_playlist(playlist, second)
        self.manager.reorder_playlist(playlist, [second, first])

        reloaded = MusicManager(self.root / "library.db", self.music)

        self.assertEqual(
            [track.id for track in reloaded.playlist_tracks(playlist)], [second, first]
        )

    def test_playlist_saves_keep_the_published_track_snapshot(self) -> None:
        track_id = self.add_track("song.mp3")
        tracks = self.manager._read_state.tracks
        playlist_id = self.manager.create_playlist("First")
        self.manager.add_to_playlist(playlist_id, track_id)
        self.manager.rename_playlist(playlist_id, "Updated")
        self.assertIs(self.manager._read_state.tracks, tracks)

        self.manager.rename_track(track_id, "Renamed song")
        self.assertIsNot(self.manager._read_state.tracks, tracks)
        self.manager.remove_from_playlist(playlist_id, track_id)

        reloaded = MusicManager(self.root / "library.db", self.music)
        self.assertEqual(reloaded.get_track(track_id).title, "Renamed song")
        self.assertEqual(reloaded.get_playlist(playlist_id).name, "Updated")
        self.assertEqual(reloaded.playlist_tracks(playlist_id), ())

    def test_failed_playlist_save_keeps_committed_snapshot(self) -> None:
        track_id = self.add_track("song.mp3")
        playlist_id = self.manager.create_playlist("Before")
        committed_tracks = self.manager._read_state.tracks

        with (
            patch.object(
                self.manager._db, "transaction", side_effect=OSError("disk full")
            ),
            self.assertRaisesRegex(OSError, "disk full"),
        ):
            self.manager.rename_playlist(playlist_id, "After")

        self.assertIs(self.manager._read_state.tracks, committed_tracks)
        self.assertEqual(self.manager.get_playlist(playlist_id).name, "Before")
        self.assertEqual(self.manager.get_track(track_id).title, "song")
        self.assertEqual(
            MusicManager(self.root / "library.db", self.music)
            .get_playlist(playlist_id)
            .name,
            "Before",
        )

    def test_interrupted_multi_statement_write_leaves_database_unchanged(
        self,
    ) -> None:
        track_id = self.add_track("song.mp3")
        source = self.manager.create_playlist("Source")
        target = self.manager.create_playlist("Target")
        self.manager.add_to_playlist(source, track_id)
        write = MusicManager._write_playlist_tracks
        calls = 0

        def fail_second_playlist(db, playlist) -> None:
            nonlocal calls
            calls += 1
            if calls == 2:
                raise sqlite3.OperationalError("disk I/O error")
            write(db, playlist)

        with (
            patch.object(
                MusicManager,
                "_write_playlist_tracks",
                side_effect=fail_second_playlist,
            ),
            self.assertRaisesRegex(DatabaseError, "disk I/O error"),
        ):
            self.manager.move_track_between_playlists(source, target, track_id)

        self.assertEqual(calls, 2)
        self.assertEqual(self.manager.get_playlist(source).track_ids, [track_id])
        self.assertEqual(self.manager.get_playlist(target).track_ids, [])
        reloaded = MusicManager(self.root / "library.db", self.music)
        self.assertEqual(reloaded.get_playlist(source).track_ids, [track_id])
        self.assertEqual(reloaded.get_playlist(target).track_ids, [])

    def test_playlist_appends_after_a_deleted_member(self) -> None:
        first, second, third = (
            self.add_track(name) for name in ("a.mp3", "b.mp3", "c.mp3")
        )
        playlist_id = self.manager.create_playlist("Gaps")
        self.manager.add_tracks_to_playlist(playlist_id, [first, second])
        self.manager.delete_track(first)
        self.manager.add_to_playlist(playlist_id, third)

        reloaded = MusicManager(self.root / "library.db", self.music)
        self.assertEqual(reloaded.get_playlist(playlist_id).track_ids, [second, third])

    def test_legacy_metadata_is_imported_once_and_kept_as_backup(self) -> None:
        audio = self.music / "legacy.mp3"
        audio.write_bytes(b"legacy audio")
        track_id, playlist_id = uuid4(), uuid4()
        legacy = self.root / "library-legacy.mmdb"
        # Version 2 predates content hashes, so the import captures one.
        legacy.write_bytes(
            b"".join(
                (
                    HEADER.pack(MAGIC, 2, 1),
                    TRACK_FIXED.pack(track_id.bytes, 5.0),
                    *(
                        _pack(value)
                        for value in ("legacy.mp3", "https://youtu.be/x", "Old")
                    ),
                    U32.pack(1),
                    UUID_ONLY.pack(playlist_id.bytes),
                    _pack("Mix"),
                    U32.pack(1),
                    UUID_ONLY.pack(track_id.bytes),
                )
            )
        )

        manager = MusicManager(
            self.root / "imported.db", self.music, legacy_metadata_path=legacy
        )

        self.assertEqual(manager.get_track(track_id).title, "Old")
        self.assertIsNone(manager.check_track_integrity(track_id))
        self.assertEqual(manager.playlist_tracks(playlist_id)[0].id, track_id)
        self.assertFalse(legacy.exists())
        self.assertTrue((self.root / "library-legacy.mmdb.migrated").is_file())
        reopened = MusicManager(
            self.root / "imported.db", self.music, legacy_metadata_path=legacy
        )
        self.assertEqual(reopened.get_playlist(playlist_id).name, "Mix")

    def test_invalid_legacy_metadata_creates_no_database_schema(self) -> None:
        legacy = self.root / "broken.mmdb"
        legacy.write_bytes(b"not a library")

        with self.assertRaisesRegex(ValueError, "not a valid MusicManager file"):
            MusicManager(self.root / "new.db", self.music, legacy_metadata_path=legacy)

        self.assertTrue(legacy.exists())

    def test_corrupt_database_is_reported_as_invalid(self) -> None:
        path = self.root / "corrupt.db"
        path.write_bytes(b"SQLite format 3\0" + b"\xff" * 4096)

        with self.assertRaisesRegex(ValueError, "not a valid database"):
            MusicManager(path, self.music)

    def test_search_keys_follow_track_changes_and_survive_playlist_saves(
        self,
    ) -> None:
        track_id = self.add_track("Alpha.mp3")
        self.assertEqual(len(self.manager.search_tracks("alpha")), 1)
        search_text = self.manager._read_state.search_text

        self.manager.create_playlist("Unrelated")
        self.assertIs(self.manager._read_state.search_text, search_text)

        self.manager.rename_track(track_id, "Ωmega Straße")
        self.assertEqual(
            [track.id for track in self.manager.search_tracks("STRASSE")], [track_id]
        )
        self.assertEqual(
            [
                track.id
                for track in self.manager.search_tracks("ωMEGA", sort="title", limit=1)
            ],
            [track_id],
        )
        # The filename still matches after the title stops matching.
        self.assertEqual(len(self.manager.search_tracks("alpha.mp3")), 1)

    def test_path_reference_check_ignores_excluded_and_unmanaged_paths(self) -> None:
        first = self.add_track("shared.mp3")
        second = self.manager.add_track(self.music / "shared.mp3", title="Copy")
        path = self.manager.track_path(first)

        self.assertTrue(self.manager.is_path_referenced(path, excluding=first))
        self.manager.delete_track(second)
        self.assertFalse(self.manager.is_path_referenced(path, excluding=first))
        self.assertTrue(self.manager.is_path_referenced(path))
        self.assertFalse(self.manager.is_path_referenced(self.music / "other.mp3"))
        self.assertFalse(self.manager.is_path_referenced(self.root / "outside.mp3"))

    def test_bounded_reads_copy_only_the_requested_library_slice(self) -> None:
        first = self.add_track("first-match.mp3")
        second = self.add_track("other.mp3")
        newest = self.add_track("newest-match.mp3")

        self.assertEqual(
            [track.id for track in self.manager.list_tracks(limit=2)],
            [newest, second],
        )
        self.assertEqual(
            [track.id for track in self.manager.search_tracks("match", limit=1)],
            [newest],
        )
        self.assertEqual(
            [
                track.id
                for track in self.manager.search_tracks("match", offset=1, limit=1)
            ],
            [first],
        )
        self.assertEqual(
            [
                track.id
                for track in self.manager.tracks_by_ids(
                    (str(first), "not-a-track-id", str(newest)), limit=1
                )
            ],
            [newest],
        )
        self.assertEqual(self.manager.list_tracks(limit=0), ())

    def test_sorted_library_pages_copy_only_visible_matches(self) -> None:
        oldest = self.add_track("zulu-match.mp3")
        middle = self.add_track("alpha-match.mp3")
        newest = self.add_track("beta-match.mp3")
        self.add_track("unrelated.mp3")
        library = LibraryService(self.manager, ApplicationStore(self.root / "state.db"))

        with patch(
            "musicplayer.core.library.manager._copy_track", wraps=_copy_track
        ) as copy:
            title_page = library.tracks(query="match", sort="title", offset=1, limit=1)
        self.assertEqual([track.id for track in title_page], [newest])
        self.assertEqual(copy.call_count, 1)

        self.assertEqual(
            [track.id for track in library.tracks(query="match", sort="oldest")],
            [oldest, middle, newest],
        )
        self.assertEqual(
            [track.id for track in library.tracks(query="match", sort="title")],
            [middle, newest, oldest],
        )
        self.assertEqual(library.tracks(sort="title", limit=0), ())
        self.assertEqual(library.tracks(sort="oldest", offset=99, limit=1), ())

    def test_selected_tracks_keep_library_order_after_membership_changes(self) -> None:
        oldest = self.add_track("oldest.mp3")
        middle = self.add_track("middle.mp3")
        newest = self.add_track("newest.mp3")
        selected = (str(oldest), middle, str(newest), str(oldest), "invalid")

        self.assertEqual(
            [track.id for track in self.manager.tracks_by_ids(selected, limit=2)],
            [newest, middle],
        )

        self.manager.delete_track(newest)
        latest = self.add_track("latest.mp3")
        self.assertEqual(
            [
                track.id
                for track in self.manager.tracks_by_ids((*selected, latest), limit=2)
            ],
            [latest, middle],
        )

    def test_source_duplicate_normalizes_youtube_urls(self) -> None:
        track_id = self.add_track(
            "song.mp3", "https://www.youtube.com/watch?v=abc123&utm_source=test"
        )
        found = self.manager.find_track_by_source("https://youtu.be/abc123")
        self.assertEqual(found.id, track_id)  # ty: ignore[unresolved-attribute]

    def test_move_between_playlists_is_atomic(self) -> None:
        track_id = self.add_track("song.mp3")
        source = self.manager.create_playlist("Source")
        target = self.manager.create_playlist("Target")
        self.manager.add_to_playlist(source, track_id)
        self.manager.move_track_between_playlists(source, target, track_id)
        self.assertEqual(self.manager.playlist_tracks(source), ())
        self.assertEqual(self.manager.playlist_tracks(target)[0].id, track_id)

    def test_bulk_add_to_playlist_is_ordered_and_duplicate_safe(self) -> None:
        first = self.add_track("first.mp3")
        second = self.add_track("second.mp3")
        third = self.add_track("third.mp3")
        playlist = self.manager.create_playlist("Bulk")
        self.manager.add_to_playlist(playlist, first)

        added = self.manager.add_tracks_to_playlist(
            playlist, [first, second, second, third]
        )
        repeated = self.manager.add_tracks_to_playlist(playlist, [second, third])

        self.assertEqual(added, 2)
        self.assertEqual(repeated, 0)
        self.assertEqual(
            [track.id for track in self.manager.playlist_tracks(playlist)],
            [first, second, third],
        )

    def test_merge_playlist_orders_imported_tracks_with_one_write(self) -> None:
        first = self.add_track("first.mp3")
        second = self.add_track("second.mp3")
        retained = self.add_track("retained.mp3")
        playlist = self.manager.create_playlist("Import")
        self.manager.add_to_playlist(playlist, retained)

        with patch.object(self.manager, "_commit", wraps=self.manager._commit) as save:
            added = self.manager.merge_tracks_into_playlist(
                playlist, [second, first, second]
            )

        self.assertEqual(added, 2)
        self.assertEqual(save.call_count, 1)
        self.assertEqual(
            [track.id for track in self.manager.playlist_tracks(playlist)],
            [second, first, retained],
        )

    def test_failed_track_update_rolls_back_metadata_and_source_index(self) -> None:
        track_id = self.add_track("rollback.mp3", "https://example.test/old")

        with (
            patch.object(self.manager, "_commit", side_effect=OSError("disk full")),
            self.assertRaisesRegex(OSError, "disk full"),
        ):
            self.manager.update_track(
                track_id,
                title="Changed",
                source="https://example.test/new",
            )

        track = self.manager.get_track(track_id)
        self.assertEqual(track.title, "rollback")
        self.assertEqual(track.source, "https://example.test/old")
        self.assertEqual(
            self.manager.find_track_by_source("https://example.test/old").id,  # ty: ignore[unresolved-attribute]
            track_id,
        )
        self.assertIsNone(self.manager.find_track_by_source("https://example.test/new"))

    def test_local_import_rolls_back_when_metadata_store_fails(self) -> None:
        source = self.root / "outside.mp3"
        source.write_bytes(b"local audio")
        store = ApplicationStore(self.root / "state.db")
        library = LibraryService(self.manager, store)

        with (
            patch.object(store, "save_track_details", side_effect=OSError("disk full")),
            self.assertRaisesRegex(OSError, "disk full"),
        ):
            library.import_local_file(source)

        self.assertEqual(self.manager.list_tracks(), ())
        self.assertFalse((self.music / source.name).exists())

    def test_delete_track_keeps_file(self) -> None:
        track_id = self.add_track("safe.mp3")
        path = self.manager.track_path(track_id)
        self.manager.delete_track(track_id)
        self.assertTrue(path.exists())

    def test_delete_track_and_file_removes_audio_and_playlist_reference(self) -> None:
        track_id = self.add_track("delete.mp3")
        path = self.manager.track_path(track_id)
        playlist_id = self.manager.create_playlist("Temporary")
        self.manager.add_to_playlist(playlist_id, track_id)
        library = LibraryService(self.manager, ApplicationStore(self.root / "state.db"))

        library.delete_track_and_file(track_id)

        self.assertFalse(path.exists())
        self.assertFalse(self.manager.has_track(track_id))
        self.assertEqual(self.manager.playlist_tracks(playlist_id), ())

    def test_delete_track_file_failure_keeps_library_entry(self) -> None:
        track_id = self.add_track("locked.mp3")
        path = self.manager.track_path(track_id)
        library = LibraryService(self.manager, ApplicationStore(self.root / "state.db"))

        with (
            patch.object(Path, "unlink", side_effect=PermissionError("file locked")),
            self.assertRaisesRegex(PermissionError, "file locked"),
        ):
            library.delete_track_and_file(track_id)

        self.assertTrue(path.exists())
        self.assertTrue(self.manager.has_track(track_id))

    def test_playlist_and_library_exports_preserve_order_and_file_uris(self) -> None:
        first = self.add_track("first song.mp3")
        second = self.add_track("second.mp3")
        playlist_id = self.manager.create_playlist("Reversed")
        self.manager.add_to_playlist(playlist_id, first)
        self.manager.add_to_playlist(playlist_id, second)
        library = LibraryService(self.manager, ApplicationStore(self.root / "state.db"))

        playlist_lines = (
            library.export_playlist_m3u8(playlist_id).decode("utf-8").splitlines()
        )
        library_lines = library.export_library_m3u8().decode("utf-8").splitlines()

        self.assertEqual(playlist_lines[0], "#EXTM3U")
        self.assertEqual(playlist_lines[1], "#EXTINF:-1,first song")
        self.assertEqual(playlist_lines[2], self.manager.track_path(first).as_uri())
        self.assertEqual(playlist_lines[4], self.manager.track_path(second).as_uri())
        self.assertEqual(library_lines[2], self.manager.track_path(second).as_uri())
        self.assertEqual(library_lines[4], self.manager.track_path(first).as_uri())

    def test_local_import_keeps_audio_when_registration_rollback_fails(self) -> None:
        source = self.root / "outside.mp3"
        source.write_bytes(b"local audio")
        store = ApplicationStore(self.root / "state.db")
        library = LibraryService(self.manager, store)

        with (
            patch.object(store, "save_track_details", side_effect=OSError("disk full")),
            patch.object(
                self.manager, "delete_track", side_effect=OSError("read only")
            ),
            self.assertLogs("musicplayer.application.library_service", level="ERROR"),
            self.assertRaisesRegex(OSError, "disk full"),
        ):
            library.import_local_file(source)

        tracks = self.manager.list_tracks()
        self.assertEqual(len(tracks), 1)
        self.assertEqual(
            self.manager.track_path(tracks[0].id).read_bytes(), b"local audio"
        )
        self.assertEqual(source.read_bytes(), b"local audio")

    def test_local_import_cleanup_failure_preserves_original_error(self) -> None:
        source = self.root / "outside.mp3"
        source.write_bytes(b"local audio")
        store = ApplicationStore(self.root / "state.db")
        library = LibraryService(self.manager, store)

        with (
            patch.object(store, "save_track_details", side_effect=OSError("disk full")),
            patch.object(Path, "unlink", side_effect=PermissionError("file locked")),
            self.assertLogs("musicplayer.application.library_service", level="WARNING"),
            self.assertRaisesRegex(OSError, "disk full"),
        ):
            library.import_local_file(source)

        self.assertEqual(self.manager.list_tracks(), ())
        self.assertEqual((self.music / source.name).read_bytes(), b"local audio")
        reloaded = MusicManager(self.root / "library.db", self.music)
        self.assertEqual(reloaded.list_tracks(), ())

    def test_clear_library_removes_tracks_and_playlists_but_keeps_files(self) -> None:
        track_id = self.add_track("kept.mp3")
        path = self.manager.track_path(track_id)
        playlist_id = self.manager.create_playlist("Temporary")
        self.manager.add_to_playlist(playlist_id, track_id)

        self.assertEqual(self.manager.clear_library(), (1, 1))

        self.assertEqual(self.manager.list_tracks(), ())
        self.assertEqual(self.manager.list_playlists(), ())
        self.assertTrue(path.exists())
        self.assertEqual(self.manager.clear_library(), (0, 0))
        reloaded = MusicManager(self.root / "library.db", self.music)
        self.assertEqual(reloaded.list_tracks(), ())
        self.assertEqual(reloaded.list_playlists(), ())

    def test_clear_playlists_preserves_library_tracks(self) -> None:
        track_id = self.add_track("library-track.mp3")
        self.manager.create_playlist("Temporary")

        self.assertEqual(self.manager.clear_playlists(), 1)

        self.assertTrue(self.manager.has_track(track_id))
        self.assertEqual(self.manager.list_playlists(), ())
        self.assertEqual(self.manager.clear_playlists(), 0)
        reloaded = MusicManager(self.root / "library.db", self.music)
        self.assertTrue(reloaded.has_track(track_id))
        self.assertEqual(reloaded.list_playlists(), ())

    def test_find_track_by_content_detects_local_duplicate(self) -> None:
        track_id = self.add_track("same.mp3")
        outside = self.root / "outside.mp3"
        outside.write_bytes(b"audio:same.mp3")
        self.assertEqual(self.manager.find_track_by_content(outside).id, track_id)  # ty: ignore[unresolved-attribute]

    def test_replace_track_file_updates_hash_and_preserves_track_identity(self) -> None:
        track_id = self.add_track("old.mp3")
        playlist_id = self.manager.create_playlist("Kept")
        self.manager.add_to_playlist(playlist_id, track_id)
        replacement = self.music / "replacement.mp3"
        replacement.write_bytes(b"replacement audio")

        self.manager.replace_track_file(track_id, replacement)

        self.assertTrue(self.manager.track_path(track_id).samefile(replacement))
        self.assertIsNone(self.manager.check_track_integrity(track_id))
        self.assertEqual(self.manager.playlist_tracks(playlist_id)[0].id, track_id)

    def test_track_can_move_to_an_explicit_public_music_root(self) -> None:
        track_id = self.add_track("private.mp3")
        public = self.root / "public" / "Music" / "Melody"
        public.mkdir(parents=True)
        published = public / "published.mp3"
        published.write_bytes(b"published audio")
        manager = MusicManager(
            self.root / "library.db",
            self.music,
            additional_music_folders=(public,),
        )

        manager.replace_track_file(track_id, published)

        self.assertEqual(manager.track_path(track_id), published.resolve())
        reloaded = MusicManager(
            self.root / "library.db",
            self.music,
            additional_music_folders=(public,),
        )
        self.assertEqual(reloaded.track_path(track_id), published.resolve())

    def test_track_rejects_an_absolute_path_outside_managed_roots(self) -> None:
        track_id = self.add_track("private.mp3")
        public = self.root / "public" / "Music" / "Melody"
        public.mkdir(parents=True)
        outside = self.root / "outside.mp3"
        outside.write_bytes(b"outside audio")
        manager = MusicManager(
            self.root / "library.db",
            self.music,
            additional_music_folders=(public,),
        )

        with self.assertRaisesRegex(ValueError, "configured music folder"):
            manager.replace_track_file(track_id, outside)

    def test_integrity_check_reports_a_registered_file_that_becomes_empty(
        self,
    ) -> None:
        track_id = self.add_track("emptied.mp3")
        self.manager.track_path(track_id).write_bytes(b"")

        problem = self.manager.check_track_integrity(track_id)

        assert problem is not None
        self.assertEqual(problem.kind, "empty")

    def test_lookup_indexes_follow_source_updates_and_deletion(self) -> None:
        track_id = self.add_track("indexed.mp3", "https://example.test/old")
        same_content = self.root / "same-content.mp3"
        same_content.write_bytes(b"audio:indexed.mp3")

        self.manager.update_track(track_id, source="https://example.test/new")

        self.assertIsNone(self.manager.find_track_by_source("https://example.test/old"))
        self.assertEqual(
            self.manager.find_track_by_source("https://example.test/new").id,  # ty: ignore[unresolved-attribute]
            track_id,
        )
        self.assertEqual(self.manager.find_track_by_content(same_content).id, track_id)  # ty: ignore[unresolved-attribute]

        self.manager.delete_track(track_id)

        self.assertIsNone(self.manager.find_track_by_content(same_content))


if __name__ == "__main__":
    unittest.main()


def _pack(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return U32.pack(len(encoded)) + encoded
