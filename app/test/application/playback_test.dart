import "../support/temp.dart";
import "dart:io";
import "dart:math";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/library_service.dart";
import "package:melody/application/loudness.dart";
import "package:melody/application/models.dart";
import "package:melody/application/playback.dart";
import "package:melody/application/queue.dart";
import "package:melody/application/store.dart";
import "package:melody/audio/audio_backend.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/loudness.dart";
import "package:melody_audio/melody_audio.dart" show AudioQueueItem;
import "package:path/path.dart" as p;

class FakeBackend implements TrackPlayerBackend {
  String source = "";
  final List<int> playedAt = [];
  double volume = 0;
  int pauseCount = 0;
  final List<int> seekedTo = [];
  final List<(List<AudioQueueItem>, int, RepeatMode)> queues = [];
  final List<(List<AudioQueueItem>, int, RepeatMode)> queueUpdates = [];
  int cancelledLoads = 0;
  int discardedSources = 0;

  double loadGain = 1;

  @override
  void load(
    String source, {
    bool autoplay = false,
    int positionMs = 0,
    double gain = 1,
  }) {
    this.source = source;
    loadGain = gain;
    if (autoplay) playedAt.add(positionMs);
  }

  @override
  void play([int positionMs = 0]) => playedAt.add(positionMs);

  @override
  void pause() => pauseCount++;

  @override
  void resume() => playedAt.add(-1);

  @override
  void seek(int positionMs) => seekedTo.add(positionMs);

  @override
  void setVolume(double value) => volume = value;

  @override
  void setQueue(
    List<AudioQueueItem> items,
    int currentIndex, {
    required RepeatMode repeat,
    bool autoplay = false,
    int positionMs = 0,
  }) {
    queues.add((items, currentIndex, repeat));
    if (autoplay) playedAt.add(positionMs);
  }

  @override
  void updateQueue(
    List<AudioQueueItem> items,
    int currentIndex, {
    required RepeatMode repeat,
  }) => queueUpdates.add((items, currentIndex, repeat));

  @override
  void cancelLoad() => cancelledLoads++;

  @override
  void discardSource() => discardedSources++;
}

/// Makes List.shuffle the identity permutation.
class IdentityRandom implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

void main() {
  late Directory root;
  late String music;
  late MusicManager manager;
  late ApplicationStore store;
  late FakeBackend backend;

  setUp(() async {
    root = await createTestDirectory("melody-playback");
    music = p.join(root.path, "music");
    manager = MusicManager.open(p.join(root.path, "library.db"), music);
    store = ApplicationStore.open(
      p.join(root.path, "state.db"),
      defaultDownloadDirectory: music,
    );
    backend = FakeBackend();
  });

  tearDown(() async {
    manager.close();
    store.close();
    await root.delete(recursive: true);
  });

  Future<List<String>> tracks(List<String> names) async => [
    for (final name in names)
      await () async {
        final path = p.join(music, name);
        await File(path).writeAsString(name);
        return manager.addTrack(path, title: name);
      }(),
  ];

  PlaybackController controller({void Function(String)? onError}) =>
      PlaybackController(
        manager,
        LibraryService(manager, store),
        store,
        backend,
        onError: onError,
      );

  Map<String, Object?> saved() =>
      (store.get("playback") as Map).cast<String, Object?>();

  test(
    "the native queue owns completion and the controller mirrors track changes",
    () async {
      final ids = await tracks(["one.mp3", "two.mp3"]);
      final playback = controller();
      playback.playTracks(ids);
      final (items, index, repeat) = backend.queues.last;
      expect(items.map((item) => item.trackId), ids);
      expect((index, repeat), (0, RepeatMode.off));
      expect(backend.playedAt, [0]);

      playback
        ..onLoaded()
        ..onDuration(1000)
        ..onCompleted();
      expect(playback.currentTrackId, ids[0]);
      expect(playback.playing, isFalse);
      expect(backend.queues, hasLength(1));

      playback.onTrackChanged(ids[1], 1);
      expect(playback.currentTrackId, ids[1]);
      expect(playback.playing, isTrue);
      expect(playback.loading, isTrue);
      expect(saved()["current_index"], 1);

      playback.onStopped();
      expect(playback.playing, isFalse);
      expect(playback.mediaSessionActive, isFalse);
      expect(playback.positionMs, 0);
      expect(playback.currentTrackId, isNull);
      expect(playback.queue.items, isEmpty);
    },
  );

  test("queue mutations update the native queue without reloading", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller()
      ..playTrack(ids[0])
      ..addLast(ids[1])
      ..cycleRepeat();
    expect(backend.queues, hasLength(1));
    expect(backend.queueUpdates, hasLength(2));
    final (latest, index, repeat) = backend.queueUpdates.last;
    expect(latest.map((item) => item.trackId), ids);
    expect((index, repeat), (0, RepeatMode.track));
    expect(playback.queue.repeat, RepeatMode.track);
  });

  test(
    "shuffle upcoming reorders on every tap and is never persisted as a mode",
    () async {
      final ids = await tracks(["one.mp3", "two.mp3", "three.mp3", "four.mp3"]);
      final playback = controller()..playTracks(ids);
      playback.queue = PlaybackQueue(
        items: playback.queue.items,
        currentIndex: playback.queue.currentIndex,
        random: IdentityRandom(),
      );
      expect(playback.shuffleUpcoming(), isTrue);
      expect(playback.queue.items, [ids[0], ids[2], ids[3], ids[1]]);
      expect(playback.shuffleUpcoming(), isTrue);
      expect(playback.queue.items, [ids[0], ids[3], ids[1], ids[2]]);
      expect(backend.queues, hasLength(1));
      expect(backend.queueUpdates, hasLength(2));
      expect(
        backend.queueUpdates.last.$1.map((item) => item.trackId),
        playback.queue.items,
      );
      expect(saved().containsKey("shuffle"), isFalse);
    },
  );

  test("events from a retiring player cannot corrupt a handoff", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller()
      ..playTracks(ids)
      ..onPosition(9000)
      ..onDuration(99000)
      ..onPlaying(false)
      ..onCompleted();
    expect(playback.currentTrackId, ids[0]);
    expect(playback.positionMs, 0);
    expect(playback.durationMs, 0);
    expect(playback.playing, isTrue);
    playback
      ..onLoaded()
      ..onDuration(99000)
      ..onPosition(9000);
    expect(playback.durationMs, 99000);
    expect(playback.positionMs, 9000);
  });

  test("stop is distinct from pause and unloads the music", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTrack(id)
      ..toggle();
    expect(playback.mediaSessionActive, isTrue);
    playback.toggle();
    expect(playback.mediaSessionActive, isTrue);
    playback.stop();
    expect(playback.mediaSessionActive, isFalse);
    expect(playback.playing, isFalse);
    expect(playback.loading, isFalse);
    expect(playback.currentTrackId, isNull);
    expect(playback.queue.items, isEmpty);
    expect(playback.positionMs, 0);
    expect(backend.discardedSources, 1);
    expect(saved()["queue"], isEmpty);
  });

  test("stop releases a selection that is still preparing", () async {
    final playback = controller();
    playback.beginPendingTrack("Remote song");
    expect(playback.loading, isTrue);
    playback.stop();
    expect(playback.loading, isFalse);
    expect(playback.externalTitle, isEmpty);
  });

  test("a failed pending selection leaves the preparing state", () async {
    final playback = controller();
    final generation = playback.beginPendingTrack("Remote song");
    expect(playback.isCurrentRequest(generation), isTrue);
    playback.onBackendError("Couldn’t play Remote song.");
    expect(playback.loading, isFalse);
    expect(playback.playing, isFalse);
    expect(playback.externalTitle, isEmpty);
    expect(playback.isCurrentRequest(generation), isFalse);
  });

  test("bulk queue updates notify once each", () async {
    final ids = await tracks([
      "current.mp3",
      "next-one.mp3",
      "next-two.mp3",
      "last-one.mp3",
      "last-two.mp3",
    ]);
    final playback = controller();
    playback.queue.replace([ids[0]]);
    final changes = <PlaybackChange>[];
    playback.changes.listen(changes.add);
    playback
      ..addNextMany([ids[1], ids[2]])
      ..addLastMany([ids[3], ids[4]]);
    expect(playback.queue.items, ids);
    expect(changes, [PlaybackChange.queue, PlaybackChange.queue]);
  });

  test(
    "queueing a track that left the library keeps the engine in sync",
    () async {
      final ids = await tracks(["one.mp3", "two.mp3"]);
      final errors = <String>[];
      final playback = controller(onError: errors.add)..playTrack(ids[0]);
      const removed = "00000000-0000-4000-8000-000000000000";

      playback
        ..addNext(removed)
        ..addLast(removed);
      expect(playback.queue.items, [ids[0]]);
      expect(backend.queueUpdates, isEmpty);
      expect(errors, [
        "This track is no longer in your library.",
        "This track is no longer in your library.",
      ]);

      // A stale id among others is skipped; the rest still reach the engine.
      expect(playback.addLastMany([removed, ids[1]]), 1);
      expect(playback.addNextMany([removed]), 0);
      expect(playback.queue.items, ids);
      expect(backend.queueUpdates.last.$1.map((item) => item.trackId), ids);
    },
  );

  test("library playback sends file paths to the native player", () async {
    final ids = await tracks(["song.mp3", "next.mp3"]);
    controller().playTracks(ids);
    final (items, index, repeat) = backend.queues.last;
    expect(items.map((item) => item.source), [
      p.join(p.normalize(p.absolute(music)), "song.mp3"),
      p.join(p.normalize(p.absolute(music)), "next.mp3"),
    ]);
    expect((index, repeat), (0, RepeatMode.off));
    expect(backend.source, "");
    expect(backend.playedAt, [0]);
  });

  test(
    "a replacement cancels preparation and installs the new queue",
    () async {
      final ids = await tracks(["one.mp3", "two.mp3"]);
      controller()
        ..playTrack(ids[0])
        ..playTrack(ids[1]);
      expect(backend.cancelledLoads, 1);
      expect(backend.queues, hasLength(2));
      final (items, index, _) = backend.queues.last;
      expect(items[index].trackId, ids[1]);
    },
  );

  test(
    "the requested start survives filtering and duplicate removal",
    () async {
      final ids = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
      final playback = controller()
        ..playTracks(["not-a-uuid", ids[0], ids[1]], startIndex: 1);
      expect(playback.currentTrackId, ids[0]);
      playback.playTracks([ids[0], ids[0], ids[1], ids[2]], startIndex: 2);
      expect(playback.queue.items, ids);
      expect(playback.currentTrackId, ids[1]);
    },
  );

  test("next at the end of the queue stops and rewinds", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTracks([id])
      ..next();
    expect(playback.playing, isFalse);
    expect(playback.positionMs, 0);
    expect(backend.pauseCount, 1);
    expect(backend.seekedTo, [0]);
  });

  test("next at the end keeps the current track's pending load", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller()
      ..playTracks(ids)
      ..onLoaded()
      ..next();
    expect(playback.currentTrackId, ids[1]);
    expect(playback.loading, isTrue);
    playback.next();
    // Cancelling would leave the first track's decoder active, so the pause
    // and rewind (and a later resume) would play the wrong song.
    expect(backend.cancelledLoads, 0);
    expect(playback.currentTrackId, ids[1]);
    expect(playback.playing, isFalse);
    expect(backend.pauseCount, 1);
    expect(backend.seekedTo, [0]);
  });

  test("playing a repeated queue row sends that row to the engine", () async {
    final ids = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    final playback = controller()
      ..playTracks(ids)
      ..addNext(ids[2]);
    expect(playback.queue.items, [ids[0], ids[2], ids[1], ids[2]]);
    playback.playQueueIndex(3);
    expect(playback.queue.currentIndex, 3);
    final (items, index, _) = backend.queues.last;
    expect(index, 3);
    expect(items[index].trackId, ids[2]);
  });

  test("the queue's track plays while a remote selection is pending", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTracks([id])
      ..onLoaded()
      ..onPlaying(true);
    final generation = playback.beginPendingTrack("Remote song");
    expect(playback.currentTrackId, id);
    playback.playTrack(id);
    expect(backend.queues, hasLength(2));
    expect(playback.externalTitle, isEmpty);
    expect(playback.isCurrentRequest(generation), isFalse);
  });

  test("next after an unqueued stream releases the source", () {
    final playback = controller()
      ..playStream("https://example.test/stream", title: "Stream")
      ..next();
    expect(playback.playing, isFalse);
    expect(playback.mediaSessionActive, isFalse);
    expect(playback.externalTitle, "");
    expect(backend.discardedSources, 1);
  });

  test("clearing library state stops audio and empties the queue", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()..playTracks([id]);
    playback.positionMs = 400;
    playback
      ..clearLibraryState()
      ..clearLibraryState();
    expect(playback.queue.items, isEmpty);
    expect(playback.queue.currentIndex, -1);
    expect(playback.playing, isFalse);
    expect(playback.positionMs, 0);
    expect(backend.pauseCount, 0);
    expect(backend.discardedSources, 1);
    expect(playback.mediaSessionActive, isFalse);
    expect(saved()["queue"], isEmpty);
  });

  test("clearing library state keeps an active stream", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTrack(id)
      ..playStream("https://example.test/stream", title: "Stream")
      ..clearLibraryState();
    expect(playback.queue.items, isEmpty);
    expect(playback.externalTitle, "Stream");
    expect(playback.playing, isTrue);
    expect(backend.discardedSources, 0);
  });

  test(
    "a restored queue drops invalid tracks and keeps the current one",
    () async {
      final [id] = await tracks(["song.mp3"]);
      store.set("playback", {
        "queue": ["not-a-uuid", id],
        "current_index": 1,
        "position_ms": 3456,
        "repeat": "off",
      });
      final playback = controller();
      expect(playback.queue.items, [id]);
      expect(playback.currentTrackId, id);
      expect(playback.positionMs, 3456);
    },
  );

  test("a restored track shows its saved progress before playing", () async {
    final [id] = await tracks(["song.mp3"]);
    store.set("playback", {
      "queue": [id],
      "current_index": 0,
      "position_ms": 3456,
      "duration_ms": 200000,
    });
    final playback = controller();
    expect(playback.playing, isFalse);
    expect(playback.positionMs, 3456);
    expect(playback.durationMs, 200000);
    playback.seek(500000);
    expect(playback.positionMs, 200000);
    expect(saved()["duration_ms"], 200000);
  });

  test("an invalid restored position does not prevent startup", () async {
    final [id] = await tracks(["song.mp3"]);
    store.set("playback", {
      "queue": [id],
      "current_index": 0,
      "position_ms": "invalid",
    });
    final playback = controller();
    expect(playback.currentTrackId, id);
    expect(playback.positionMs, 0);
  });

  test(
    "a restored queue loads its source before resuming at the saved position",
    () async {
      final [id] = await tracks(["song.mp3"]);
      store.set("playback", {
        "queue": [id],
        "current_index": 0,
        "position_ms": 3456,
      });
      controller().toggle();
      final (items, index, _) = backend.queues.last;
      expect(
        items[index].source,
        p.join(p.normalize(p.absolute(music)), "song.mp3"),
      );
      expect(backend.playedAt, [3456]);
    },
  );

  test("a native failure repairs optimistic play intent", () async {
    final [id] = await tracks(["song.mp3"]);
    store.set("playback", {
      "queue": [id],
      "current_index": 0,
      "position_ms": 1234,
    });
    final playback = controller()
      ..toggle()
      ..onBackendError("native source is missing");
    expect(playback.playing, isFalse);
    expect(backend.playedAt, [1234]);
  });

  test("removing the only current item releases the source", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTracks([id])
      ..removeQueueItem(0);
    expect(playback.queue.items, isEmpty);
    expect(playback.playing, isFalse);
    expect(backend.pauseCount, 0);
    expect(backend.discardedSources, 1);
    expect(playback.mediaSessionActive, isFalse);
  });

  test("removing a row that is already gone does nothing", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller()..playTracks(ids);
    final loads = backend.queues.length;
    playback
      ..removeQueueItem(2)
      ..removeQueueItem(-1);
    expect(playback.queue.items, ids);
    expect(backend.queues, hasLength(loads));
  });

  test("removing a track drops every row of it with one reload", () async {
    final [one, two, three] = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    final playback = controller()..playTracks([one, two, three]);
    playback
      ..addLast(one)
      ..addNext(one);
    final loads = backend.queues.length;
    playback.removeTrack(one);
    expect(playback.queue.items, [two, three]);
    expect(playback.currentTrackId, two);
    expect(backend.queues, hasLength(loads + 1));
    expect(playback.playing, isTrue);
  });

  test("playing a track missing from the library keeps the queue", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final errors = <String>[];
    final playback = controller(onError: errors.add)..playTracks(ids);
    playback.playTrack("00000000-0000-4000-8000-000000000000");
    expect(playback.queue.items, ids);
    expect(playback.currentTrackId, ids[0]);
    expect(errors, ["This track is no longer in your library."]);
  });

  test("an unavailable selection starts at the next available track", () async {
    final [one, two, three] = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    const missing = "00000000-0000-4000-8000-000000000000";
    final playback = controller()
      ..playTracks([one, missing, two], startIndex: 1);
    expect(playback.queue.items, [one, two]);
    expect(playback.currentTrackId, two);
    playback.playTracks([one, three, missing], startIndex: 2);
    expect(playback.currentTrackId, three);
  });

  test("a queued track deleted elsewhere does not block the queue", () async {
    final [one, two, three] = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    final playback = controller();
    playback.queue.replace([one, two, three]);
    manager.deleteTrack(two);
    playback.playQueueIndex(0);
    expect(playback.queue.items, [one, three]);
    final (items, index, _) = backend.queues.last;
    expect(items.map((item) => item.trackId), [one, three]);
    expect(index, 0);

    // A deleted selection plays its successor from the start.
    manager.deleteTrack(one);
    playback
      ..onBackendError("decoder lost")
      ..seek(4000)
      ..toggle();
    expect(playback.currentTrackId, three);
    expect(backend.queues.last.$1.map((item) => item.trackId), [three]);
    expect(backend.playedAt.last, 0);
  });

  test("a queue whose tracks all left the library releases", () async {
    final [one] = await tracks(["one.mp3"]);
    final errors = <String>[];
    final playback = controller(onError: errors.add)..playTracks([one]);
    manager.deleteTrack(one);
    playback.playQueueIndex(0);
    expect(playback.queue.items, isEmpty);
    expect(playback.playing, isFalse);
    expect(backend.discardedSources, greaterThan(0));
    expect(errors, ["This track is no longer in your library."]);
  });

  test("clear queue keeps the current track until it is removed", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller()
      ..playTracks(ids)
      ..clearQueue();
    expect(playback.queue.items, [ids[0]]);
    expect(playback.playing, isTrue);
    expect(backend.discardedSources, 0);
    playback.removeQueueItem(0);
    expect(playback.currentTrackId, isNull);
    expect(playback.mediaSessionActive, isFalse);
    expect(backend.discardedSources, 1);
    expect(saved()["queue"], isEmpty);
  });

  test("drag reordering persists and keeps the current track", () async {
    final ids = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    final playback = controller();
    playback.queue.replace(ids, startIndex: 1);
    playback.reorderQueue(0, 3);
    expect(playback.queue.items, [ids[1], ids[2], ids[0]]);
    expect(playback.currentTrackId, ids[1]);
    expect(saved()["queue"], playback.queue.items);
  });

  test("playing a queue row keeps the queue order", () async {
    final ids = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    final playback = controller();
    playback.queue.replace(ids);
    playback.playQueueIndex(2);
    expect(playback.queue.items, ids);
    expect(playback.currentTrackId, ids[2]);
  });

  test("seeking before the source loads updates the resume position", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller();
    playback.queue.replace([id]);
    playback.seek(4567);
    expect(playback.positionMs, 4567);
    expect(backend.seekedTo, isEmpty);
    playback.toggle();
    expect(backend.playedAt, [4567]);
  });

  test("playing from a position restarts a finished track there", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTrack(id)
      ..onLoaded()
      ..onDuration(9000)
      ..onCompleted();
    expect(playback.playing, isFalse);
    backend.playedAt.clear();
    playback.playFrom(3000);
    expect(playback.playing, isTrue);
    expect(playback.positionMs, 3000);
    expect(backend.playedAt, [3000]);
  });

  test("playing from the start of a paused track rewinds first", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTrack(id)
      ..onLoaded()
      ..onDuration(9000)
      ..onPosition(4000)
      ..toggle();
    backend.playedAt.clear();
    playback.playFrom(0);
    expect(playback.playing, isTrue);
    expect(backend.seekedTo, [0]);
    expect(backend.playedAt, [-1]);
  });

  test("playing from a position reloads a released track there", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTrack(id)
      ..onLoaded()
      ..onBackendError("The decoder failed.");
    backend.playedAt.clear();
    playback.playFrom(2500);
    expect(playback.playing, isTrue);
    expect(backend.queues, hasLength(2));
    expect(backend.playedAt, [2500]);
  });

  test("timeline events and seeks are clamped to the duration", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()
      ..playTrack(id)
      ..onLoaded()
      ..onDuration(1000)
      ..seek(2000)
      ..onPosition(1500);
    expect(playback.positionMs, 1000);
    expect(backend.seekedTo, [1000]);
    playback.onDuration(500);
    expect(playback.positionMs, 500);
    expect(saved()["position_ms"], 500);
  });

  test("mute restores the exact previous volume", () {
    final playback = controller()
      ..setVolume(41)
      ..toggleMute();
    expect(backend.volume, 0);
    playback.toggleMute();
    expect(playback.volume, 41);
    expect(backend.volume, 0.41);
  });

  test("volume previews skip persistence until committed", () {
    final changes = <PlaybackChange>[];
    final playback = controller();
    final saved = store.settings.volume;
    playback.changes.listen(changes.add);
    playback.setVolume(35, persist: false);
    expect(store.settings.volume, saved);
    playback.setVolume(35);
    expect(store.settings.volume, 35);
    expect(changes, [PlaybackChange.volume, PlaybackChange.volume]);
  });

  test("a failure repairs loaded state and the next toggle reloads", () async {
    final [id] = await tracks(["song.mp3"]);
    final errors = <String>[];
    final playback = controller(onError: errors.add)
      ..playTrack(id)
      ..onBackendError("native load failed");
    expect(playback.playing, isFalse);
    expect(playback.mediaSessionActive, isFalse);
    expect(errors, ["native load failed"]);
    expect(store.trackDetails(id).playCount, 0);
    expect(backend.discardedSources, 1);
    expect(playback.loading, isFalse);
    playback.toggle();
    expect(backend.playedAt, [0, 0]);
    playback
      ..onLoaded()
      ..onPlaying(true);
    expect(store.trackDetails(id).playCount, 1);
  });

  test("a failed stream clears its unresumable selection", () {
    final playback = controller()
      ..playStream("https://example.test/stream", title: "Stream")
      ..onBackendError("native load failed");
    expect(playback.externalTitle, "");
    expect(playback.playing, isFalse);
    expect(playback.mediaSessionActive, isFalse);
    expect(backend.discardedSources, 1);
  });

  test("a playing event clears a missing loaded event", () async {
    final [id] = await tracks(["song.mp3"]);
    final playback = controller()..playTrack(id);
    expect(playback.loading, isTrue);
    playback.onPlaying(true);
    expect(playback.playing, isTrue);
    expect(playback.loading, isFalse);
  });

  test(
    "coalesced persistence records repeated plays at their latest position",
    () async {
      final ids = await tracks(["one.mp3", "two.mp3"]);
      final persistence = PlaybackPersistence(store, (_) {});
      persistence.save(
        playback: {
          "queue": ids,
          "current_index": 0,
          "position_ms": 0,
          "repeat": "off",
        },
      );
      persistence
        ..recordPlay(ids[0])
        ..recordPlay(ids[1])
        ..recordPlay(ids[0])
        ..flush();
      expect(store.trackDetails(ids[0]).playCount, 2);
      expect(store.get("recent_tracks"), [ids[0], ids[1]]);
    },
  );

  group("loudness normalization", () {
    late Map<String, double> lufs;
    late LoudnessNormalizer loudness;

    setUp(() {
      lufs = {};
      loudness = LoudnessNormalizer(
        manager,
        p.join(root.path, "loudness.json"),
        (path, {cancel}) async {
          final value = lufs[p.basename(path)];
          if (value == null) throw const LoudnessUnmeasurable("Invalid data");
          return LoudnessMeasurement(integratedLufs: value, truePeakDb: -3);
        },
        enabled: true,
        targetLufs: -14,
        saveDelay: Duration.zero,
        notifyDelay: Duration.zero,
      );
    });

    tearDown(() => loudness.close());

    PlaybackController normalized() => PlaybackController(
      manager,
      LibraryService(manager, store),
      store,
      backend,
      loudness: loudness,
    );

    Future<void> measure(Iterable<String> ids) async {
      loudness.analyze(ids);
      await loudness.idle;
      // Announcements are batched on a timer.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test("every queue row carries its gain; the volume is untouched", () async {
      final ids = await tracks(["loud.mp3", "quiet.mp3"]);
      lufs.addAll({"loud.mp3": -8, "quiet.mp3": -20});
      await measure(ids);
      final playback = normalized()..setVolume(40);
      playback.playTracks(ids);

      final items = backend.queues.last.$1;
      expect(items[0].gain, closeTo(linearGain(-6), 1e-9));
      expect(items[1].gain, 1);
      expect(backend.volume, 0.4);
      expect(playback.volume, 40);
    });

    test(
      "a measurement reaches upcoming rows but not the playing track",
      () async {
        final ids = await tracks(["a.mp3", "b.mp3"]);
        final playback = normalized();
        playback.playTracks(ids);
        expect(backend.queues.last.$1.map((item) => item.gain), [1, 1]);

        lufs.addAll({"a.mp3": -10, "b.mp3": -8});
        await measure(ids);
        var items = backend.queueUpdates.last.$1;
        // The playing track keeps the level it started at.
        expect(items[0].gain, 1);
        expect(items[1].gain, closeTo(linearGain(-6), 1e-9));

        // Once the engine moves on, the new track holds the gain it was
        // given, and the first track's measurement applies next time.
        playback.onTrackChanged(ids[1], 1);
        await measure(ids);
        playback.playQueueIndex(0);
        items = backend.queues.last.$1;
        expect(items[0].gain, closeTo(linearGain(-4), 1e-9));
      },
    );

    test("settings changes reach the playing track", () async {
      final ids = await tracks(["a.mp3"]);
      lufs["a.mp3"] = -8;
      await measure(ids);
      final playback = normalized();
      playback.playTracks(ids);
      expect(backend.queues.last.$1.single.gain, lessThan(1));

      loudness.configure(enabled: false, targetLufs: -14);
      expect(backend.queueUpdates.last.$1.single.gain, 1);
      loudness.configure(enabled: true, targetLufs: -18);
      expect(
        backend.queueUpdates.last.$1.single.gain,
        closeTo(linearGain(-10), 1e-9),
      );
    });

    test(
      "unanalyzed tracks and streams play at the typical library gain",
      () async {
        final ids = await tracks(["a.mp3", "b.mp3", "c.mp3", "new.mp3"]);
        lufs.addAll({"a.mp3": -10, "b.mp3": -11, "c.mp3": -12});
        await measure(ids.take(3));
        final playback = normalized();
        playback.playTracks([ids[3]]);
        expect(
          backend.queues.last.$1.single.gain,
          closeTo(linearGain(-3), 1e-9),
        );

        playback.playStream("https://example.com/stream", title: "Preview");
        expect(backend.loadGain, closeTo(linearGain(-3), 1e-9));
      },
    );
  });
}
