import "dart:io";
import "dart:math";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/library_service.dart";
import "package:melody/application/models.dart";
import "package:melody/application/playback.dart";
import "package:melody/application/queue.dart";
import "package:melody/application/store.dart";
import "package:melody/audio/audio_backend.dart";
import "package:melody/core/library/manager.dart";
import "package:path/path.dart" as p;

class FakeBackend implements TrackPlayerBackend {
  String source = "";
  final List<int> playedAt = [];
  double volume = 0;
  int pauseCount = 0;
  final List<int> seekedTo = [];
  final List<(List<Map<String, String>>, int, String)> queues = [];
  final List<(List<Map<String, String>>, int, String)> queueUpdates = [];
  int cancelledLoads = 0;
  int discardedSources = 0;

  @override
  void load(String source, {bool autoplay = false, int positionMs = 0}) {
    this.source = source;
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
    List<Map<String, String>> items,
    int currentIndex, {
    required String repeatMode,
    bool autoplay = false,
    int positionMs = 0,
  }) {
    queues.add((items, currentIndex, repeatMode));
    if (autoplay) playedAt.add(positionMs);
  }

  @override
  void updateQueue(List<Map<String, String>> items, int currentIndex, {required String repeatMode}) =>
      queueUpdates.add((items, currentIndex, repeatMode));

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
    root = await Directory.systemTemp.createTemp("melody-playback");
    music = p.join(root.path, "music");
    manager = MusicManager.open(p.join(root.path, "library.db"), music);
    store = ApplicationStore.open(p.join(root.path, "state.db"), defaultDownloadDirectory: music);
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

  PlaybackController controller({void Function(String)? onError}) => PlaybackController(
    manager,
    LibraryService(manager, store),
    store,
    backend,
    onError: onError,
  );

  Map<String, Object?> saved() => (store.get("playback") as Map).cast<String, Object?>();

  test("the native queue owns completion and the controller mirrors track changes", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller();
    playback.playTracks(ids);
    final (items, index, repeat) = backend.queues.last;
    expect(items.map((item) => item["track_id"]), ids);
    expect((index, repeat), (0, "off"));
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
    expect(playback.snapshot.loading, isTrue);
    expect(saved()["current_index"], 1);

    playback.onStopped();
    expect(playback.playing, isFalse);
    expect(playback.mediaSessionActive, isFalse);
    expect(playback.positionMs, 0);
    expect(playback.currentTrackId, ids[1]);
  });

  test("queue mutations update the native queue without reloading", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final playback = controller()
      ..playTrack(ids[0])
      ..addLast(ids[1])
      ..cycleRepeat();
    expect(backend.queues, hasLength(1));
    expect(backend.queueUpdates, hasLength(2));
    final (latest, index, repeat) = backend.queueUpdates.last;
    expect(latest.map((item) => item["track_id"]), ids);
    expect((index, repeat), (0, "track"));
    expect(playback.queue.repeat, RepeatMode.track);
  });

  test("shuffle upcoming reorders on every tap and is never persisted as a mode", () async {
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
    expect(backend.queueUpdates.last.$1.map((item) => item["track_id"]), playback.queue.items);
    expect(saved().containsKey("shuffle"), isFalse);
  });

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

  test("stop is distinct from pause and ends the media session", () async {
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
    expect(playback.currentTrackId, id);
    expect(playback.positionMs, 0);
  });

  test("bulk queue updates notify once each", () async {
    final playback = controller();
    playback.queue.replace(["current"]);
    final changes = <String>[];
    playback.changes.listen(changes.add);
    playback
      ..addNextMany(["next-one", "next-two"])
      ..addLastMany(["last-one", "last-two"]);
    expect(playback.queue.items, ["current", "next-one", "next-two", "last-one", "last-two"]);
    expect(changes, ["queue", "queue"]);
  });

  test("library playback sends file paths to the native player", () async {
    final ids = await tracks(["song.mp3", "next.mp3"]);
    controller().playTracks(ids);
    final (items, index, repeat) = backend.queues.last;
    expect(items.map((item) => item["source"]), [
      p.join(p.normalize(p.absolute(music)), "song.mp3"),
      p.join(p.normalize(p.absolute(music)), "next.mp3"),
    ]);
    expect((index, repeat), (0, "off"));
    expect(backend.source, "");
    expect(backend.playedAt, [0]);
  });

  test("a replacement cancels preparation and installs the new queue", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    controller()
      ..playTrack(ids[0])
      ..playTrack(ids[1]);
    expect(backend.cancelledLoads, 1);
    expect(backend.queues, hasLength(2));
    final (items, index, _) = backend.queues.last;
    expect(items[index]["track_id"], ids[1]);
  });

  test("the requested start survives filtering and duplicate removal", () async {
    final ids = await tracks(["one.mp3", "two.mp3", "three.mp3"]);
    final playback = controller()..playTracks(["not-a-uuid", ids[0], ids[1]], startIndex: 1);
    expect(playback.currentTrackId, ids[0]);
    playback.playTracks([ids[0], ids[0], ids[1], ids[2]], startIndex: 2);
    expect(playback.queue.items, ids);
    expect(playback.currentTrackId, ids[1]);
  });

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

  test("a restored queue drops invalid tracks and keeps the current one", () async {
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
  });

  test("an invalid restored position does not prevent startup", () async {
    final [id] = await tracks(["song.mp3"]);
    store.set("playback", {"queue": [id], "current_index": 0, "position_ms": "invalid"});
    final playback = controller();
    expect(playback.currentTrackId, id);
    expect(playback.positionMs, 0);
  });

  test("a restored queue loads its source before resuming at the saved position", () async {
    final [id] = await tracks(["song.mp3"]);
    store.set("playback", {"queue": [id], "current_index": 0, "position_ms": 3456});
    controller().toggle();
    final (items, index, _) = backend.queues.last;
    expect(items[index]["source"], p.join(p.normalize(p.absolute(music)), "song.mp3"));
    expect(backend.playedAt, [3456]);
  });

  test("a native failure repairs optimistic play intent", () async {
    final [id] = await tracks(["song.mp3"]);
    store.set("playback", {"queue": [id], "current_index": 0, "position_ms": 1234});
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
    final changes = <String>[];
    final playback = controller();
    playback.changes.listen(changes.add);
    playback.setVolume(35, persist: false);
    expect(store.settings.volume, 5);
    playback.setVolume(35);
    expect(store.settings.volume, 35);
    expect(changes, ["volume", "volume"]);
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
    expect(playback.snapshot.loading, isFalse);
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
    expect(playback.snapshot.loading, isTrue);
    playback.onPlaying(true);
    expect(playback.playing, isTrue);
    expect(playback.snapshot.loading, isFalse);
  });

  test("coalesced persistence records repeated plays at their latest position", () async {
    final ids = await tracks(["one.mp3", "two.mp3"]);
    final persistence = PlaybackPersistence(store, (_) {});
    persistence.save(playback: {"queue": ids, "current_index": 0, "position_ms": 0, "repeat": "off"});
    persistence
      ..recordPlay(ids[0])
      ..recordPlay(ids[1])
      ..recordPlay(ids[0])
      ..flush();
    expect(store.trackDetails(ids[0]).playCount, 2);
    expect(store.get("recent_tracks"), [ids[0], ids[1]]);
  });
}
