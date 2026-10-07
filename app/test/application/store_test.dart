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
    root = await Directory.systemTemp.createTemp("melody-store");
    store = open();
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test("references to removed tracks are dropped and stay gone", () async {
    for (final id in ["kept", "gone"]) {
      store.recordPlay(id, playedAt: 1);
    }
    store.saveTrackDetails("orphan", TrackDetails(favorite: true));

    // "gone" has details and history; "orphan" only details.
    expect(store.reconcileTrackReferences({"kept"}), 2);

    store.recordPlay("gone", playedAt: 2);
    final reopened = await reopen();
    expect(reopened.get("recent_tracks"), ["kept"]);
    expect(reopened.get("playback_history"), ["kept"]);
    expect(reopened.hasTrackDetails("gone"), isFalse);
    expect(reopened.favoriteTrackIds(), isEmpty);
  });

  test("clearing library data keeps settings and search history", () async {
    store
      ..saveSettings(store.settings..theme = "dark")
      ..addRecent("search_history", "query")
      ..recordPlay(
        "track",
        playedAt: 1,
        playback: {
          "queue": ["track"],
          "current_index": 0,
          "position_ms": 1200,
          "repeat": "playlist",
        },
      );

    store.clearLibraryData();
    // A play batch that arrives late cannot bring the track back.
    store.savePlaybackUpdates(const {}, {"track": 1});

    final reopened = await reopen();
    expect(reopened.settings.theme, "dark");
    expect(reopened.get("search_history"), ["query"]);
    expect(reopened.get("recent_tracks"), isEmpty);
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
    expect(reopened.get("recent_tracks"), ["b", "a"]);
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
}
