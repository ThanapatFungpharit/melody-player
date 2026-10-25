import "../support/temp.dart";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/store.dart";
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
}

Map<String, Object?> _session(List<String> queue) => {
  "queue": queue,
  "current_index": 0,
  "position_ms": 0,
  "repeat": "off",
};
