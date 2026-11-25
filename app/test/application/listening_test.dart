import "../support/temp.dart";
import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/listening.dart";
import "package:melody/application/models.dart";
import "package:melody/application/playback.dart";
import "package:melody/application/store.dart";
import "package:melody/core/library/manager.dart";
import "package:path/path.dart" as p;
import "package:sqlite3/sqlite3.dart";

/// Plays a track for the tracker as the controller would report it.
class _Player {
  final changes = StreamController<PlaybackChange>.broadcast(sync: true);
  String? trackId;
  bool playing = false;
  int position = 0;
  int duration = 0;

  PlaybackObservation observe() => (
    trackId: trackId,
    playing: playing,
    positionMs: position,
    durationMs: duration,
  );

  void select(String id, {int durationMs = 0}) {
    trackId = id;
    position = 0;
    duration = durationMs;
    playing = true;
    changes.add(PlaybackChange.track);
  }

  /// Moves the playhead forward in steps of [step].
  void play(Duration length, {Duration step = const Duration(seconds: 1)}) {
    for (var heard = Duration.zero; heard < length; heard += step) {
      position += step.inMilliseconds;
      changes.add(PlaybackChange.progress);
    }
  }

  void seek(int to) {
    position = to;
    changes.add(PlaybackChange.progress);
  }
}

void main() {
  group("ListeningTracker", () {
    late _Player player;
    late List<Listen> recorded;
    late ListeningTracker tracker;
    var clock = DateTime(2026, 11, 20, 9);

    setUp(() {
      player = _Player();
      recorded = [];
      clock = DateTime(2026, 11, 20, 9);
      tracker = ListeningTracker(
        player.changes.stream,
        player.observe,
        describe: (id) => id == "gone"
            ? null
            : (
                title: "Title $id",
                artist: "Artist",
                album: "Album",
                source: "https://music.youtube.com/watch?v=$id",
                durationMs: 0,
              ),
        record: recorded.add,
        clock: () => clock,
      );
    });

    tearDown(() => tracker.close());

    test("a play counts once, after half the track", () {
      final streamed = <Listen>[];
      tracker.listens.listen(streamed.add);
      player.select("a", durationMs: 200000);
      player.play(const Duration(seconds: 99));
      expect(recorded, isEmpty);
      player.play(const Duration(seconds: 2));
      expect(recorded, hasLength(1));
      player.play(const Duration(seconds: 90));
      expect(recorded, hasLength(1));
      final listen = recorded.single;
      expect(listen.trackId, "a");
      expect(listen.startedAt, DateTime(2026, 11, 20, 9));
      expect(listen.durationMs, 200000);
      expect(listen.album, "Album");
      expect(streamed.single, same(listen));
    });

    test("a long track counts after four minutes", () {
      player.select("a", durationMs: 20 * 60000);
      player.play(const Duration(minutes: 3, seconds: 59));
      expect(recorded, isEmpty);
      player.play(const Duration(seconds: 2));
      expect(recorded, hasLength(1));
    });

    test("with no known length, four minutes count", () {
      player.select("a");
      player.play(const Duration(minutes: 4));
      expect(recorded, hasLength(1));
    });

    test("seeking forward hears nothing", () {
      player.select("a", durationMs: 200000);
      player.play(const Duration(seconds: 10));
      player.seek(190000);
      player.play(const Duration(seconds: 9));
      expect(recorded, isEmpty);
    });

    test("paused time and a stale position do not count", () {
      player.select("a", durationMs: 60000);
      player.play(const Duration(seconds: 10));
      player.playing = false;
      player.play(const Duration(seconds: 40));
      expect(recorded, isEmpty);
    });

    test("skipping to another track starts over", () {
      player.select("a", durationMs: 60000);
      player.play(const Duration(seconds: 25));
      player.select("b", durationMs: 60000);
      player.play(const Duration(seconds: 25));
      expect(recorded, isEmpty);
      player.play(const Duration(seconds: 6));
      expect(recorded.single.trackId, "b");
    });

    test("repeating a counted track counts it again", () {
      player.select("a", durationMs: 60000);
      player.play(const Duration(seconds: 60));
      clock = clock.add(const Duration(minutes: 1));
      player.seek(0);
      player.play(const Duration(seconds: 31));
      expect(recorded.map((listen) => listen.trackId), ["a", "a"]);
      expect(recorded.last.startedAt, DateTime(2026, 11, 20, 9, 1));
    });

    test("a track the library no longer has is not counted", () {
      player.select("gone", durationMs: 10000);
      player.play(const Duration(seconds: 10));
      expect(recorded, isEmpty);
    });

    test("a failed write loses that listen only", () async {
      final failing = ListeningTracker(
        player.changes.stream,
        player.observe,
        describe: (id) =>
            (title: id, artist: "", album: "", source: "", durationMs: 0),
        record: (_) => throw StateError("disk full"),
      );
      final streamed = <Listen>[];
      failing.listens.listen(streamed.add);
      player.select("a", durationMs: 4000);
      player.play(const Duration(seconds: 3));
      expect(streamed, hasLength(1));
      await failing.close();
    });
  });

  group("periods and streaks", () {
    test("a week starts on Monday and a month on its first", () {
      final now = DateTime(2026, 11, 25, 15); // a Wednesday
      final week = StatsRange.of(StatsPeriod.week, now);
      expect(dayStart(week.firstDay), DateTime(2026, 11, 23));
      expect(dayStart(week.lastDay), DateTime(2026, 11, 29));
      final earlier = StatsRange.of(StatsPeriod.week, now, offset: 1);
      expect(dayStart(earlier.firstDay), DateTime(2026, 11, 16));

      final month = StatsRange.of(StatsPeriod.month, now);
      expect(dayStart(month.firstDay), DateTime(2026, 11, 1));
      expect(dayStart(month.lastDay), DateTime(2026, 11, 30));
      expect(month.length, 30);
      final january = StatsRange.of(StatsPeriod.month, now, offset: 10);
      expect(dayStart(january.firstDay), DateTime(2026, 1, 1));
      expect(january.length, 31);
    });

    test("local days ignore the time of day", () {
      expect(
        localDay(DateTime(2026, 3, 1, 0, 5)),
        localDay(DateTime(2026, 3, 1, 23, 55)),
      );
      expect(dayStart(localDay(DateTime(2026, 3, 1, 12))), DateTime(2026, 3));
    });

    test("streaks count consecutive days", () {
      expect(streaks([], today: 100), (0, 0));
      expect(streaks([1, 2, 3, 7, 8], today: 8), (2, 3));
      // Today has nothing yet: yesterday's run still counts.
      expect(streaks([5, 6, 7], today: 8), (3, 3));
      expect(streaks([5, 6], today: 8), (0, 2));
    });
  });

  group("statistics", () {
    late Directory root;
    late ApplicationStore store;
    final today = localDay(DateTime(2026, 11, 25));

    setUp(() async {
      root = await createTestDirectory("melody-listening");
      store = ApplicationStore.open(
        p.join(root.path, "library.db"),
        defaultDownloadDirectory: p.join(root.path, "music"),
      );
    });

    tearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });

    void listen(
      String track,
      DateTime at, {
      String artist = "Artist",
      String album = "",
      String? title,
      int ms = 180000,
    }) => store.recordListen(
      Listen(
        trackId: track,
        startedAt: at,
        listenedMs: ms,
        durationMs: ms,
        title: title ?? "Song $track",
        artist: artist,
        album: album,
      ),
    );

    ListeningStats read(StatsRange range) {
      final db = sqlite3.open(store.path, mode: OpenMode.readOnly);
      try {
        return ListeningStats.read(db, range, today: today);
      } finally {
        db.close();
      }
    }

    test("ranks tracks, artists, and albums within the period", () {
      final monday = DateTime(2026, 11, 23, 10);
      listen("a", monday, artist: "X", album: "First");
      listen("a", monday.add(const Duration(days: 1)), artist: "X");
      listen(
        "a",
        monday.add(const Duration(days: 2)),
        artist: "X",
        title: "Renamed",
      );
      listen("b", monday, artist: "Y", album: "Second", ms: 60000);
      listen("c", monday.add(const Duration(hours: 1)), artist: "");
      // Outside the week.
      listen("b", DateTime(2026, 11, 22, 23), artist: "Y");

      final stats = read(
        StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25)),
      );
      expect(stats.listens, 5);
      expect(stats.tracks, 3);
      expect(stats.listenedMs, 180000 * 4 + 60000);
      expect(stats.topTracks.first.trackId, "a");
      expect(stats.topTracks.first.name, "Renamed");
      expect(stats.topTracks.first.listens, 3);
      expect(stats.topArtists.map((entry) => entry.name), ["X", "Y"]);
      expect(stats.topAlbums.map((entry) => entry.name), ["First", "Second"]);
      expect(stats.days, hasLength(7));
      expect(stats.days.first.listens, 3);
      expect(stats.days.last.listens, 0);
      // Sunday the 22nd through Wednesday the 25th.
      expect(stats.currentStreak, 4);
      expect(stats.longestStreak, 4);
    });

    test("an empty history reads as empty", () {
      final stats = read(StatsRange.of(StatsPeriod.month, DateTime.now()));
      expect(stats.isEmpty, isTrue);
      expect(stats.topTracks, isEmpty);
      expect(stats.currentStreak, 0);
    });

    test("top lists hold at most ten rows", () {
      for (var index = 0; index < 15; index++) {
        listen("t$index", DateTime(2026, 11, 24, 8, index), artist: "A$index");
      }
      final stats = read(
        StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25)),
      );
      expect(stats.topTracks, hasLength(ListeningStats.topCount));
      expect(stats.topArtists, hasLength(ListeningStats.topCount));
      expect(stats.listens, 15);
    });

    test("loads in a background isolate beside the open store", () async {
      listen("a", DateTime(2026, 11, 24, 8));
      final stats = await loadListeningStats(
        store.path,
        StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25)),
        now: DateTime(2026, 11, 25),
      );
      expect(stats.listens, 1);
    });

    test(
      "removing a track's details, or library data, removes its listens",
      () {
        listen("a", DateTime(2026, 11, 24, 8));
        listen("b", DateTime(2026, 11, 24, 9));
        store.removeTrackDetails("a");
        // A late listen for a removed track is not recorded.
        listen("a", DateTime(2026, 11, 24, 10));
        final week = StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25));
        expect(read(week).topTracks.map((entry) => entry.trackId), ["b"]);
        store.clearLibraryData();
        expect(read(week).isEmpty, isTrue);
      },
    );

    test("reconciling drops listens of tracks the library lost", () {
      listen("kept", DateTime(2026, 11, 24, 8));
      listen("lost", DateTime(2026, 11, 24, 9));
      expect(store.reconcileTrackReferences({"kept"}), 1);
      final week = StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25));
      expect(read(week).topTracks.map((entry) => entry.trackId), ["kept"]);
    });

    test("deleting a library track deletes its listens in the same "
        "transaction", () async {
      final manager = MusicManager.open(store.path, p.join(root.path, "music"));
      addTearDown(manager.close);
      final file = File(p.join(root.path, "music", "one.mp3"));
      await file.create(recursive: true);
      await file.writeAsString("audio");
      final id = await manager.addTrack(file.path, title: "One");
      listen(id, DateTime(2026, 11, 24, 8));
      manager.deleteTrack(id);
      final week = StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25));
      expect(read(week).isEmpty, isTrue);
    });

    test("an earlier release's database gains the table on open", () async {
      await store.close();
      final db = sqlite3.open(store.path);
      db.execute("DROP TABLE listens");
      db.close();
      store = ApplicationStore.open(
        store.path,
        defaultDownloadDirectory: p.join(root.path, "music"),
      );
      listen("a", DateTime(2026, 11, 24, 8));
      final week = StatsRange.of(StatsPeriod.week, DateTime(2026, 11, 25));
      expect(read(week).listens, 1);
    });
  });
}
