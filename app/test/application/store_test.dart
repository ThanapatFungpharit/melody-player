import "../support/temp.dart";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/store.dart";
import "package:melody/core/media.dart";
import "package:melody/core/storage.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;
  late ApplicationStore store;

  ApplicationStore open() => ApplicationStore.open(
    p.join(root.path, "state.db"),
    defaultDownloadDirectory: p.join(root.path, "music"),
  );

  Future<ApplicationStore> reopen() async {
    await store.close();
    return store = open();
  }

  setUp(() async {
    root = await createTestDirectory("melody-store");
    store = open();
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test("references to removed tracks are dropped and stay gone", () async {
    store.savePlaybackUpdates(
      {
        "playback": _session(["kept", "gone"]),
      },
      {"kept": 1, "gone": 1},
    );
    store.saveTrackDetails("orphan", TrackDetails(favorite: true));

    // "gone" has details and history; "orphan" only details.
    expect(store.reconcileTrackReferences({"kept"}), 2);

    store.savePlaybackUpdates(const {}, {"gone": 1});
    final reopened = await reopen();
    expect(reopened.recentTrackIds(), ["kept"]);
    expect(reopened.get("playback_history"), ["kept"]);
    expect(reopened.hasTrackDetails("gone"), isFalse);
    expect(reopened.favoriteTrackIds(), isEmpty);
  });

  test("the music source survives a restart", () async {
    expect(store.settings.musicSource, MusicSource.youtubeMusic);
    store.saveSettings(store.settings..musicSource = MusicSource.youtube);
    expect(store.settings.musicSource, MusicSource.youtube);
    final reopened = await reopen();
    expect(reopened.settings.musicSource, MusicSource.youtube);
  });

  test("clearing library data keeps settings and search history", () async {
    store
      ..saveSettings(store.settings..theme = "dark")
      ..addSearch("query")
      ..savePlaybackUpdates(
        {
          "playback": {
            "queue": ["track"],
            "current_index": 0,
            "position_ms": 1200,
            "repeat": "playlist",
          },
        },
        {"track": 1},
      );

    store.clearLibraryData();
    // A play batch that arrives late cannot bring the track back.
    store.savePlaybackUpdates(const {}, {"track": 1});

    final reopened = await reopen();
    expect(reopened.settings.theme, "dark");
    expect(reopened.searchHistory(), ["query"]);
    expect(reopened.recentTrackIds(), isEmpty);
    expect(reopened.hasTrackDetails("track"), isFalse);
    expect(reopened.get("playback"), {
      "queue": <Object?>[],
      "current_index": -1,
      "position_ms": 0,
      "repeat": "playlist",
    });
  });

  test("favoriting several tracks writes only the new ones", () async {
    store.saveTrackDetails("a", TrackDetails(favorite: true, playCount: 3));

    expect(store.favoriteTracks(["a", "b", "b", "c"]), 2);

    final reopened = await reopen();
    expect(reopened.favoriteTrackIds(), {"a", "b", "c"});
    expect(reopened.trackDetails("a").playCount, 3);
  });

  test("coalesced plays count exactly and order recents", () async {
    store.savePlaybackUpdates(
      {
        "playback": {
          "queue": ["a", "b"],
          "current_index": 1,
          "position_ms": 0,
          "repeat": "off",
        },
      },
      // Oldest to newest.
      {"a": 2, "b": 1},
    );

    final reopened = await reopen();
    expect(reopened.trackDetails("a").playCount, 2);
    expect(reopened.trackDetails("b").playCount, 1);
    expect(reopened.recentTrackIds(), ["b", "a"]);
  });

  test("download history keeps only the newest records", () async {
    store.saveDownloads([
      for (var i = 0; i < 260; i++)
        DownloadRecord(id: "$i", url: "https://example.com/$i", title: "$i"),
    ]);

    final records = (await reopen()).downloads();
    expect(records, hasLength(250));
    expect(records.first.id, "10");
    expect(records.last.id, "259");
  });

  test("unusable stored numbers fall back to safe values", () {
    final details = TrackDetails.fromJson({
      "duration": double.infinity,
      "play_count": -3,
      "last_played": "NaN",
    });
    expect(details.duration, 0);
    expect(details.playCount, 0);
    expect(details.lastPlayed, 0);
    final record = DownloadRecord.fromJson({
      "id": "1",
      "progress": 7.5,
      "total_bytes": double.nan,
      "downloaded_bytes": "12.0",
    });
    expect(record.progress, 1.0);
    expect(record.totalBytes, 0);
    expect(record.downloadedBytes, 12);
  });

  test("a value written back to an earlier state is saved", () async {
    store
      ..saveSearchHistory(["a"])
      ..saveSearchHistory(["b"])
      ..saveSearchHistory(["a"]);
    expect((await reopen()).searchHistory(), ["a"]);
    // Writing what is stored changes nothing.
    store.saveSearchHistory(["a"]);
    expect((await reopen()).searchHistory(), ["a"]);
  });

  test("clearing library data again removes details added since", () async {
    store
      ..saveTrackDetails("first", TrackDetails(favorite: true))
      ..clearLibraryData()
      ..saveTrackDetails("second", TrackDetails(favorite: true))
      ..clearLibraryData();
    final reopened = await reopen();
    expect(reopened.hasTrackDetails("first"), isFalse);
    expect(reopened.hasTrackDetails("second"), isFalse);
  });

  test("state nothing reads any more goes at the next launch", () async {
    store.set("lyrics_not_embedded", {"track": "hash"});
    await reopen();
    expect(store.get("lyrics_not_embedded"), isNull);
    await store.close();
    final db = SqliteStore.open(p.join(root.path, "state.db"));
    expect(
      db.query("SELECT 1 FROM state WHERE key = 'lyrics_not_embedded'"),
      isEmpty,
    );
    await db.close();
    await reopen();
  });

  group("playback position", () {
    /// The stored rows themselves, read over a second connection.
    Future<Map<String, Object?>> rawRows() async {
      final db = SqliteStore.open(p.join(root.path, "state.db"));
      try {
        return {
          for (final row in db.query("SELECT key, value FROM state"))
            row["key"] as String: jsonDecode(row["value"] as String),
        };
      } finally {
        await db.close();
      }
    }

    Map<String, Object?> session() =>
        (store.get("playback") as Map).cast<String, Object?>();

    void saveSession(int positionMs) => store.savePlaybackUpdates({
      "playback": {
        "queue": ["a", "b"],
        "current_index": 1,
        "position_ms": positionMs,
        "duration_ms": 9000,
        "repeat": "off",
      },
    }, const {});

    void savePosition(int positionMs) => store.savePlaybackUpdates({
      "position": {"position_ms": positionMs, "duration_ms": 9000},
    }, const {});

    test("is saved without the queue and read back over it", () async {
      saveSession(1000);
      savePosition(5000);
      expect(session()["position_ms"], 5000);
      expect(session()["queue"], ["a", "b"]);

      await reopen();
      expect(session()["position_ms"], 5000);
      expect(session()["queue"], ["a", "b"]);
    });

    test("gives way to a later session save", () async {
      saveSession(1000);
      savePosition(5000);
      saveSession(2000);
      expect(session()["position_ms"], 2000);
      await reopen();
      expect(session()["position_ms"], 2000);
    });

    test("seeking back to the saved value is not lost", () async {
      saveSession(1000);
      savePosition(5000);
      // The same session row as stored, so it needs no rewrite, but the
      // newer position must still go.
      saveSession(1000);
      expect(session()["position_ms"], 1000);
      await reopen();
      expect(session()["position_ms"], 1000);
    });

    test("moving through the queue leaves the queue's row alone", () async {
      saveSession(1000);
      final rowOf = await rawRows();
      expect(rowOf["playback"], {
        "queue": ["a", "b"],
        "repeat": "off",
      });
      expect(rowOf["playback_position"], {
        "current_index": 1,
        "position_ms": 1000,
        "duration_ms": 9000,
      });
    });

    test("a position saved alone keeps the place in the queue", () async {
      saveSession(1000);
      savePosition(5000);
      expect(session()["current_index"], 1);
      expect((await rawRows())["playback_position"], {
        "current_index": 1,
        "position_ms": 5000,
        "duration_ms": 9000,
      });
    });

    for (final (name, cursor) in [
      ("an empty position row", <String, Object?>{}),
      ("only a position", <String, Object?>{"position_ms": 5000}),
    ]) {
      test("a session saved before the split reads back with $name", () async {
        await store.close();
        final db = SqliteStore.open(p.join(root.path, "state.db"));
        final old = {
          "queue": ["a", "b"],
          "current_index": 1,
          "position_ms": 1000,
          "repeat": "playlist",
        };
        db.transaction((db) {
          for (final (key, value) in [
            ("playback", old),
            ("playback_position", cursor),
          ]) {
            db.execute(
              "INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)",
              [key, jsonEncode(value)],
            );
          }
        });
        await db.close();

        await reopen();

        expect(session(), {...old, ...cursor});
        // The next save moves it to the two rows without losing anything.
        savePosition(7000);
        expect(session(), {
          ...old,
          ...cursor,
          "position_ms": 7000,
          "duration_ms": 9000,
        });
        saveSession(2000);
        expect(session()["position_ms"], 2000);
      });
    }

    test("is cleared with the library", () async {
      saveSession(1000);
      savePosition(5000);
      store.clearLibraryData();
      expect(session()["position_ms"], 0);
      await reopen();
      expect(session()["position_ms"], 0);
      expect(session()["queue"], isEmpty);
    });
  });

  test("a failed commit leaves track details as they were", () async {
    store.saveTrackDetails("a", TrackDetails(uploader: "One"));
    store.saveTrackDetails("b", TrackDetails(uploader: "Two"));
    store.removeTrackDetails("a");
    expect(store.hasTrackDetails("a"), isFalse);
    expect(store.trackDetails("b").uploader, "Two");

    await store.close();
    expect(
      () => store.saveTrackDetails("b", TrackDetails(uploader: "Three")),
      throwsA(anything),
    );
    expect(store.trackDetails("b").uploader, "Two");
    store = open();
    expect(store.trackDetails("b").uploader, "Two");
    expect(store.hasTrackDetails("a"), isFalse);
  });
}

Map<String, Object?> _session(List<String> queue) => {
  "queue": queue,
  "current_index": 0,
  "position_ms": 0,
  "repeat": "off",
};
