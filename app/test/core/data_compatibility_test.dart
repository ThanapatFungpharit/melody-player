import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/store.dart";
import "package:melody/core/library/manager.dart";
import "package:path/path.dart" as p;

/// The fixtures were written by Melody's previous Python stores
/// (`library.db`, `state.db`) and its pre-SQLite formats.
void main() {
  final fixtures = p.join("test", "fixtures", "data");
  final expected =
      jsonDecode(File(p.join(fixtures, "expected.json")).readAsStringSync())
          as Map<String, Object?>;
  final ids = (expected["ids"] as Map).cast<String, String>();
  final legacy = (expected["legacy"] as Map).cast<String, String>();
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
    root = await Directory.systemTemp.createTemp("melody-compat");
    await copyTree(fixtures, root.path);
  });

  tearDown(() => root.delete(recursive: true));

  test("opens a library written by the Python MusicManager", () async {
    final manager = MusicManager.open(
      p.join(root.path, "library.db"),
      p.join(root.path, "music"),
    );
    addTearDown(manager.close);

    expect(manager.counts(), (3, 2));
    // Newest first, like the Python reader.
    expect(manager.listTracks().map((track) => track.id), [
      ids["gamma"],
      ids["beta"],
      ids["alpha"],
    ]);
    final gamma = manager.getTrack(ids["gamma"]!);
    expect(gamma.title, "Gamma ü");
    expect(gamma.filename, p.join("sub", "Gamma.opus"));
    expect(manager.trackPath(gamma.id), p.join(root.path, "music", "sub", "Gamma.opus"));
    expect(manager.getTrack(ids["beta"]!).displayTitle, "Beta");

    final mix = manager.getPlaylist(ids["mix"]!);
    expect(mix.name, "Mix");
    expect(mix.trackIds, [ids["gamma"], ids["beta"], ids["alpha"]]);

    // Identity lookups use the same canonical source keys.
    expect(
      manager.findTrackBySource("https://www.youtube.com/watch?v=alpha123456")?.id,
      ids["alpha"],
    );
    expect(manager.findTrackBySource("https://music.youtube.com/watch?v=beta1234567")?.id, ids["beta"]);
    // Hashes written by Python verify against the files.
    expect(await manager.checkTrackIntegrity(ids["alpha"]!), isNull);
    final copy = File(p.join(root.path, "copy.mp3"))
      ..writeAsBytesSync(utf8.encode("alpha audio"));
    expect((await manager.findTrackByContent(copy.path))?.id, ids["alpha"]);
  });

  test("keeps appending to playlists with position gaps", () async {
    final manager = MusicManager.open(
      p.join(root.path, "library.db"),
      p.join(root.path, "music"),
    );
    final empty = manager.listPlaylists().firstWhere((item) => item.name == "Empty");
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

  test("opens application state written by the Python store", () {
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
    expect(store.get("recent_tracks"), [ids["beta"], ids["alpha"]]);
    expect(store.get("search_history"), ["lofi"]);
    expect(store.get("playback"), {
      "queue": [ids["beta"], ids["alpha"]],
      "current_index": 1,
      "position_ms": 12345,
      "repeat": "playlist",
    });
    final download = store.downloads().single;
    expect(download.status, "completed");
    expect(download.trackIds, [ids["alpha"]]);
    expect(download.createdAt, 1699999999.0);
  });

  test("Dart writes stay readable after reopening", () {
    final path = p.join(root.path, "state.db");
    final store = ApplicationStore.open(path, defaultDownloadDirectory: "/unused");
    store.savePlaybackUpdates({
      "volume": {"volume": 10, "previous_volume": 10, "muted": false},
    }, {ids["beta"]!: 2});
    store.recordPlay(ids["gamma"]!, playedAt: 1.5);
    store.close();

    final reopened = ApplicationStore.open(path, defaultDownloadDirectory: "/unused");
    addTearDown(reopened.close);
    expect(reopened.settings.volume, 10);
    expect(reopened.settings.accentColor, "ocean");
    expect(reopened.trackDetails(ids["beta"]!).playCount, 3);
    expect(reopened.get("recent_tracks"), [ids["gamma"], ids["beta"], ids["alpha"]]);
  });

  test("imports the pre-SQLite library and state once", () {
    final directory = Directory(p.join(root.path, "fresh"))..createSync();
    final manager = MusicManager.open(
      p.join(directory.path, "library.db"),
      p.join(root.path, "music"),
      legacyMetadataPath: p.join(root.path, "library.mmdb"),
    );
    addTearDown(manager.close);
    expect(manager.counts(), (2, 1));
    expect(manager.getTrack(legacy["track1"]!).title, "Legacy Alpha");
    expect(manager.getTrack(legacy["track1"]!).addedAt, 1600000000.5);
    // The unknown member is dropped; order is preserved.
    expect(manager.getPlaylist(legacy["playlist"]!).trackIds, [
      legacy["track2"],
      legacy["track1"],
    ]);
    expect(File(p.join(root.path, "library.mmdb")).existsSync(), isFalse);
    expect(File(p.join(root.path, "library.mmdb.migrated")).existsSync(), isTrue);

    final store = ApplicationStore.open(
      p.join(directory.path, "state.db"),
      defaultDownloadDirectory: "/music",
      legacyPath: p.join(root.path, "state.json"),
    );
    addTearDown(store.close);
    expect(store.settings.volume, 7);
    expect(store.settings.downloadDirectory, "/music");
    final details = store.trackDetails(legacy["track1"]!);
    expect(details.uploader, "Old Artist");
    expect(details.favorite, isTrue);
    expect(store.downloads().single.uploader, "Old");
    expect((store.get("playback") as Map).containsKey("shuffle"), isFalse);
    expect(File(p.join(root.path, "state.json.migrated")).existsSync(), isTrue);
  });

  test("settings defaults and clamping match the Python model", () {
    final settings = AppSettings.fromJson({
      "volume": 300,
      "previous_volume": 0,
      "concurrent_downloads": 20,
      "notification_action_pair": "bogus",
      "skip_loading_delay": "yes",
    }, defaultDownloadDirectory: "/m");
    expect(settings.volume, 100);
    expect(settings.previousVolume, 1);
    expect(settings.concurrentDownloads, 8);
    expect(settings.notificationActionPair, "shuffle_favorite");
    expect(settings.skipLoadingDelay, isFalse);
    expect(settings.downloadDirectory, "/m");
  });
}
