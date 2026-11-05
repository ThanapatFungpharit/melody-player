import "../support/temp.dart";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/core/media.dart";
import "package:melody/application/storage_upgrade.dart";
import "package:melody/application/store.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
import "package:melody/platform/paths.dart";
import "package:path/path.dart" as p;

/// The fixtures were written by earlier Melody releases (`library.db` and
/// `state.db`), not by this code. Never regenerate them.
void main() {
  final fixtures = p.join("test", "fixtures", "data");
  final expected =
      jsonDecode(File(p.join(fixtures, "expected.json")).readAsStringSync())
          as Map<String, Object?>;
  final ids = (expected["ids"] as Map).cast<String, String>();
  late Directory root;

  Future<void> copyTree(String from, String to) async {
    await for (final entity in Directory(from).list(recursive: true)) {
      final target = p.join(to, p.relative(entity.path, from: from));
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
      }
    }
  }

  setUp(() async {
    root = await createTestDirectory("melody-compat");
    await copyTree(fixtures, root.path);
  });

  tearDown(() => root.delete(recursive: true));

  test("opens a library written by an earlier release", () async {
    final manager = MusicManager.open(
      p.join(root.path, "library.db"),
      p.join(root.path, "music"),
    );
    addTearDown(manager.close);

    expect(manager.counts(), (3, 2));
    // Newest first, as earlier releases listed them.
    expect(manager.listTracks().map((track) => track.id), [
      ids["gamma"],
      ids["beta"],
      ids["alpha"],
    ]);
    final gamma = manager.getTrack(ids["gamma"]!);
    expect(gamma.title, "Gamma ü");
    // The fixture was written on Windows, so its separators are backslashes.
    String portable(String path) => path.replaceAll(r"\", "/");
    expect(portable(gamma.filename), "sub/Gamma.opus");
    expect(
      portable(manager.trackPath(gamma.id)),
      portable(p.join(root.path, "music", "sub", "Gamma.opus")),
    );
    expect(manager.getTrack(ids["beta"]!).displayTitle, "Beta");

    final mix = manager.getPlaylist(ids["mix"]!);
    expect(mix.name, "Mix");
    expect(mix.trackIds, [ids["gamma"], ids["beta"], ids["alpha"]]);

    // Identity lookups use the same canonical source keys.
    expect(
      manager
          .findTrackBySource("https://www.youtube.com/watch?v=alpha123456")
          ?.id,
      ids["alpha"],
    );
    expect(
      manager
          .findTrackBySource("https://music.youtube.com/watch?v=beta1234567")
          ?.id,
      ids["beta"],
    );
    // Hashes written by an earlier release verify against the files.
    expect(
      manager.getTrack(ids["alpha"]!).contentHash,
      await sha256File(manager.trackPath(ids["alpha"]!)),
    );
    final copy = File(p.join(root.path, "copy.mp3"))
      ..writeAsBytesSync(utf8.encode("alpha audio"));
    expect((await manager.findTrackByContent(copy.path))?.id, ids["alpha"]);
  });

  test("keeps appending to playlists with position gaps", () async {
    final manager = MusicManager.open(
      p.join(root.path, "library.db"),
      p.join(root.path, "music"),
    );
    final empty = manager.listPlaylists().firstWhere(
      (item) => item.name == "Empty",
    );
    manager.addToPlaylist(empty.id, ids["beta"]!);
    manager.removeFromPlaylist(ids["mix"]!, ids["beta"]!);
    manager.addToPlaylist(ids["mix"]!, ids["beta"]!);
    manager.close();

    final reopened = MusicManager.open(
      p.join(root.path, "library.db"),
      p.join(root.path, "music"),
    );
    addTearDown(reopened.close);
    expect(reopened.getPlaylist(ids["mix"]!).trackIds, [
      ids["gamma"],
      ids["alpha"],
      ids["beta"],
    ]);
    expect(reopened.getPlaylist(empty.id).trackIds, [ids["beta"]]);
  });

  test("opens application state written by an earlier release", () {
    final store = ApplicationStore.open(
      p.join(root.path, "state.db"),
      defaultDownloadDirectory: "/unused",
    );
    addTearDown(store.close);

    final settings = store.settings;
    expect(settings.downloadDirectory, "C:/Music/Melody");
    expect(settings.volume, 42);
    expect(settings.accentColor, "ocean");
    expect(settings.theme, "dark");

    final details = store.trackDetails(ids["alpha"]!);
    expect(details.uploader, "Artist A");
    expect(details.duration, 181.5);
    expect(details.favorite, isTrue);
    expect(details.playCount, 1);
    expect(details.lastPlayed, 1700000000.25);
    expect(store.favoriteTrackIds(), {ids["alpha"]});
    expect(store.recentTrackIds(), [ids["beta"], ids["alpha"]]);
    expect(store.searchHistory(), ["lofi"]);
    expect(store.get("playback"), {
      "queue": [ids["beta"], ids["alpha"]],
      "current_index": 1,
      "position_ms": 12345,
      "repeat": "playlist",
    });
    final download = store.downloads().single;
    expect(download.status, DownloadStatus.completed);
    expect(download.trackIds, [ids["alpha"]]);
    expect(download.createdAt, 1699999999.0);
  });

  test("Dart writes stay readable after reopening", () {
    final path = p.join(root.path, "state.db");
    final store = ApplicationStore.open(
      path,
      defaultDownloadDirectory: "/unused",
    );
    store.savePlaybackUpdates(
      {
        "volume": {"volume": 10, "previous_volume": 10, "muted": false},
      },
      // Oldest to newest.
      {ids["beta"]!: 2, ids["gamma"]!: 1},
    );
    store.close();

    final reopened = ApplicationStore.open(
      path,
      defaultDownloadDirectory: "/unused",
    );
    addTearDown(reopened.close);
    expect(reopened.settings.volume, 10);
    expect(reopened.settings.accentColor, "ocean");
    expect(reopened.trackDetails(ids["beta"]!).playCount, 3);
    expect(reopened.recentTrackIds(), [
      ids["gamma"],
      ids["beta"],
      ids["alpha"],
    ]);
  });

  group("an earlier release's two databases", () {
    late AppPaths paths;
    late File state;
    late File merged;

    ApplicationStore openStore() => ApplicationStore.open(
      paths.database,
      defaultDownloadDirectory: "/unused",
    );

    MusicManager openLibrary() =>
        MusicManager.open(paths.database, p.join(root.path, "music"));

    setUp(() {
      paths = AppPaths(
        dataDirectory: root.path,
        defaultMusicDirectory: p.join(root.path, "music"),
      );
      state = File(p.join(root.path, "state.db"));
      merged = File("${state.path}.merged");
    });

    test("become one, with everything in them", () async {
      mergeStateDatabase(paths);

      expect(state.existsSync(), isFalse);
      expect(merged.existsSync(), isTrue);
      final store = openStore();
      final manager = openLibrary();
      addTearDown(store.close);
      addTearDown(manager.close);
      expect(store.settings.downloadDirectory, "C:/Music/Melody");
      expect(store.settings.volume, 42);
      expect(store.settings.accentColor, "ocean");
      final details = store.trackDetails(ids["alpha"]!);
      expect(details.uploader, "Artist A");
      expect(details.favorite, isTrue);
      expect(details.playCount, 1);
      expect(store.favoriteTrackIds(), {ids["alpha"]});
      expect(store.recentTrackIds(), [ids["beta"], ids["alpha"]]);
      expect(store.searchHistory(), ["lofi"]);
      expect(store.get("playback"), {
        "queue": [ids["beta"], ids["alpha"]],
        "current_index": 1,
        "position_ms": 12345,
        "repeat": "playlist",
      });
      expect(store.downloads().single.trackIds, [ids["alpha"]]);
      expect(manager.counts(), (3, 2));
      expect(manager.getTrack(ids["gamma"]!).title, "Gamma ü");
    });

    test("leave no second file behind once used", () async {
      mergeStateDatabase(paths);
      final store = openStore();
      final manager = openLibrary();
      store.set("anything", 1);
      manager.createPlaylist("New");
      await store.close();
      await manager.close();

      expect(state.existsSync(), isFalse);
      final reopened = openStore();
      addTearDown(reopened.close);
      expect(reopened.get("anything"), 1);
    });

    test("share commits in any order across a restart", () async {
      mergeStateDatabase(paths);
      final store = openStore();
      final manager = openLibrary();
      for (var i = 0; i < 20; i++) {
        store.set("turn", i);
        manager.createPlaylist("Playlist $i");
      }
      await store.close();
      await manager.close();

      final reopenedStore = openStore();
      final reopenedLibrary = openLibrary();
      addTearDown(reopenedStore.close);
      addTearDown(reopenedLibrary.close);
      expect(reopenedStore.get("turn"), 19);
      expect(reopenedLibrary.counts().$2, 22);
    });

    test("delete a track's details with the track", () async {
      mergeStateDatabase(paths);
      final store = openStore();
      final manager = openLibrary();
      expect(store.hasTrackDetails(ids["alpha"]!), isTrue);

      // Nothing tells the store: a crash right here must lose nothing else.
      manager.deleteTrack(ids["alpha"]!);
      await store.close();
      await manager.close();

      final reopened = openStore();
      addTearDown(reopened.close);
      expect(reopened.hasTrackDetails(ids["alpha"]!), isFalse);
      expect(reopened.hasTrackDetails(ids["beta"]!), isTrue);
    });

    test("delete every track's details when the library clears", () async {
      mergeStateDatabase(paths);
      final manager = openLibrary();
      manager.clearLibrary();
      await manager.close();

      final reopened = openStore();
      addTearDown(reopened.close);
      expect(reopened.hasTrackDetails(ids["beta"]!), isFalse);
    });

    test("drop only details of tracks already gone", () async {
      const gone = "99999999-9999-4999-8999-999999999999";
      final earlier = SqliteStore.open(state.path);
      earlier.transaction(
        (db) => db.execute(
          "INSERT INTO track_details (track_id, value) VALUES (?, '{}')",
          [gone],
        ),
      );
      await earlier.close();

      mergeStateDatabase(paths);

      final store = openStore();
      addTearDown(store.close);
      expect(store.hasTrackDetails(gone), isFalse);
      for (final name in ["alpha", "beta"]) {
        expect(store.hasTrackDetails(ids[name]!), isTrue, reason: name);
      }
    });

    test("merged again keep what changed since", () async {
      mergeStateDatabase(paths);
      // A file another program held open is not renamed: it comes round again.
      merged.renameSync(state.path);
      final store = openStore();
      store.saveSettings(store.settings..volume = 7);
      await store.close();

      mergeStateDatabase(paths);

      final reopened = openStore();
      addTearDown(reopened.close);
      expect(reopened.settings.volume, 7);
      expect(reopened.settings.accentColor, "ocean");
      expect(state.existsSync(), isFalse);
    });

    test("stay as they were if the old file is damaged", () async {
      final garbage = List.generate(8192, (i) => i % 251);
      state.writeAsBytesSync(garbage);

      expect(() => mergeStateDatabase(paths), throwsA(anything));

      expect(state.readAsBytesSync(), garbage);
      expect(merged.existsSync(), isFalse);
      final db = SqliteStore.open(paths.database);
      addTearDown(db.close);
      expect(db.hasTable("state"), isFalse);
      expect(db.hasTable("tracks"), isTrue);
    });

    test("stay as they were if the merge fails partway", () async {
      // A table with this name but not this shape makes the copy fail.
      final db = SqliteStore.open(paths.database);
      db.transaction(
        (db) => db.execute("CREATE TABLE state (key TEXT PRIMARY KEY) STRICT"),
      );
      await db.close();

      expect(() => mergeStateDatabase(paths), throwsA(anything));

      expect(state.existsSync(), isTrue);
      expect(merged.existsSync(), isFalse);
      final after = SqliteStore.open(paths.database);
      addTearDown(after.close);
      expect(after.hasTable("track_details"), isFalse);
    });

    test("merge into a new file when the library never opened", () async {
      File(paths.database).deleteSync();

      mergeStateDatabase(paths);

      final store = openStore();
      final manager = openLibrary();
      addTearDown(store.close);
      addTearDown(manager.close);
      expect(store.settings.volume, 42);
      expect(manager.counts().$1, 0);
    });

    test("are nothing to do once merged, or on a new install", () async {
      File(paths.database).deleteSync();
      state.deleteSync();

      mergeStateDatabase(paths);

      expect(File(paths.database).existsSync(), isFalse);
    });
  });

  test("settings defaults and clamping match earlier releases", () {
    final settings = AppSettings.fromJson({
      "volume": 300,
      "previous_volume": 0,
      "concurrent_downloads": 20,
      "notification_action_pair": "bogus",
    }, defaultDownloadDirectory: "/m");
    expect(settings.volume, 100);
    expect(settings.previousVolume, 1);
    expect(settings.concurrentDownloads, 8);
    expect(settings.notificationActionPair, "shuffle_favorite");
    expect(settings.downloadDirectory, "/m");
  });

  test("loudness settings default on, and odd values fall back", () {
    // Settings saved before normalization existed.
    final earlier = AppSettings.fromJson({}, defaultDownloadDirectory: "/m");
    expect(earlier.normalizeLoudness, isTrue);
    expect(earlier.loudnessTarget, -14);

    final odd = AppSettings.fromJson({
      "normalize_loudness": "no",
      "loudness_target": -3,
    }, defaultDownloadDirectory: "/m");
    expect(odd.normalizeLoudness, isTrue);
    expect(odd.loudnessTarget, -14);

    final saved = AppSettings.fromJson(
      (earlier
            ..normalizeLoudness = false
            ..loudnessTarget = -18)
          .toJson(),
      defaultDownloadDirectory: "/m",
    );
    expect(saved.normalizeLoudness, isFalse);
    expect(saved.loudnessTarget, -18);
  });

  test("the music source defaults to YouTube Music, and is kept", () {
    final earlier = AppSettings.fromJson({}, defaultDownloadDirectory: "/m");
    expect(earlier.musicSource, MusicSource.youtubeMusic);

    final odd = AppSettings.fromJson({
      "music_source": 7,
    }, defaultDownloadDirectory: "/m");
    expect(odd.musicSource, MusicSource.youtubeMusic);

    final saved = AppSettings.fromJson(
      (earlier..musicSource = MusicSource.youtube).toJson(),
      defaultDownloadDirectory: "/m",
    );
    expect(saved.musicSource, MusicSource.youtube);
    expect(earlier.copy().sameAs(saved), isTrue);
  });
}
