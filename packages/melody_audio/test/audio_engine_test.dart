import "dart:async";
import "dart:collection";

import "package:melody_audio/src/audio_engine.dart";
import "package:melody_audio/src/system_media_session.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:just_audio_platform_interface/just_audio_platform_interface.dart";

import "support/fakes.dart";

List<AudioQueueItem> _items(List<String> ids) => [
  for (final id in ids)
    AudioQueueItem(trackId: id, source: "/music/$id.mp3", title: id),
];

/// The decoder's playlist, as track IDs.
List<String> _rowIds(FakeAudioPlayer player) => [
  for (final source in player.sources)
    source.split("/").last.replaceAll(".mp3", ""),
];

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audioSessionChannel = MethodChannel("com.ryanheise.audio_session");
  final engine = AudioEngine.instance;
  late FakeJustAudioPlatform audio;
  late RecordingMediaSessionPlatform session;

  Future<void> setQueue(
    List<String> ids,
    int index, {
    int generation = 2,
    bool autoplay = false,
    int positionMs = 0,
  }) async {
    await engine.setQueue(
      _items(ids),
      currentIndex: index,
      generation: generation,
      autoplay: autoplay,
      position: Duration(milliseconds: positionMs),
    );
  }

  Future<void> updateQueue(List<String> ids, int index) async {
    await engine.updateQueue(_items(ids), currentIndex: index);
  }

  AudioEngineSnapshot playbackState() => engine.snapshot();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
    audio = FakeJustAudioPlatform();
    JustAudioPlatform.instance = audio;
    session = RecordingMediaSessionPlatform();
    FlutterMediaSessionPlatform.instance = session;
  });

  tearDown(() async {
    await engine.clearSource();
    await SystemMediaSession.instance.deactivateForStop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  test(
    "a new source starts at its own position, not the old playhead",
    () async {
      await setQueue(["a"], 0);
      final first = audio.last;
      first.advanceTo(const Duration(seconds: 42));
      await _settle();

      await engine.loadSource(
        "/music/preview.mp3",
        generation: 4,
        position: const Duration(seconds: 5),
      );

      final preview = audio.last;
      expect(preview, isNot(same(first)));
      expect(preview.loadRequest!.initialPosition, const Duration(seconds: 5));
      expect(preview.seeks, isEmpty);
      expect(playbackState().position, const Duration(seconds: 5));
    },
  );

  test("Play and Resume restart a completed source", () async {
    await setQueue(["a"], 0, autoplay: true);
    final player = audio.last;
    await _settle();
    expect(player.playing, isTrue);

    player.complete();
    await _settle();
    await engine.play();
    await _settle();
    expect(player.seeks, [Duration.zero]);

    player.complete();
    await _settle();
    await engine.resume();
    await _settle();
    expect(player.seeks, [Duration.zero, Duration.zero]);
  });

  test("Play at a position after completion reaches the decoder", () async {
    await setQueue(["a"], 0, autoplay: true);
    final player = audio.last;
    await _settle();
    expect(player.playRequests, 1);

    // just_audio leaves `playing` set when a source completes.
    player.complete();
    await _settle();
    expect(player.playing, isTrue);
    await engine.play(position: const Duration(seconds: 30));
    await _settle();
    expect(player.seeks, [const Duration(seconds: 30)]);
    expect(player.playRequests, 2);
    expect(player.playing, isTrue);
  });

  test(
    "replaying a source media_kit keeps completed reloads it and reports both "
    "playing and the next completion",
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final states = <AudioPlaybackState>[];
      void listener(AudioEngineEvent event) {
        if (event is AudioStateChanged) states.add(event.state);
      }

      engine.attach(listener);
      addTearDown(() => engine.detach(listener));
      audio.completionOutlivesSeek = true;
      await setQueue(["a", "b"], 1, autoplay: true);
      final finished = audio.last;
      await _settle();
      finished.complete();
      await _settle();
      expect(states.last, AudioPlaybackState.completed);

      // A tapped lyric line after the end.
      states.clear();
      await engine.play(position: const Duration(seconds: 30));
      await _settle();
      final replay = audio.last;
      expect(replay, isNot(same(finished)));
      expect(finished.disposed, isTrue);
      expect(_rowIds(replay).first, "b");
      expect(replay.loadRequest!.initialIndex, 0);
      expect(replay.loadRequest!.initialPosition, const Duration(seconds: 30));
      expect(replay.playing, isTrue);
      expect(states, isNot(contains(AudioPlaybackState.paused)));
      expect(states.last, AudioPlaybackState.playing);

      replay.complete();
      await _settle();
      expect(states.last, AudioPlaybackState.completed);
    },
  );

  test(
    "Play without a position during preparation keeps the load position",
    () async {
      await setQueue(["a"], 0);
      final gate = audio.loadGate = Completer<void>();
      final selection = setQueue(["b"], 0, generation: 4, positionMs: 30000);
      await _settle();

      await engine.play();
      gate.complete();
      await selection;
      await _settle();

      final player = audio.last;
      expect(player.seeks, isEmpty);
      expect(player.playing, isTrue);
      expect(
        playbackState().position!.inMilliseconds,
        inInclusiveRange(30000, 31000),
      );
    },
  );

  test(
    "a cancelled selection's autoplay does not start later queue edits",
    () async {
      await setQueue(["a", "b"], 0);
      final original = audio.last;
      final gate = audio.loadGate = Completer<void>();
      final selection = setQueue(["c"], 0, generation: 4, autoplay: true);
      await _settle();

      engine.cancelLoad();
      gate.complete();
      await selection;
      await updateQueue(["b", "a"], 1);
      await _settle();

      expect(_rowIds(original), ["a"]);
      expect(original.playing, isFalse);
      expect(playbackState().trackId, "a");
    },
  );

  group("the decoder's window", () {
    List<String> tracks(int count) => [for (var i = 0; i < count; i++) "t$i"];

    test(
      "holds the playing row and the next few, however long the queue is",
      () async {
        await setQueue(tracks(5000), 1000);
        final player = audio.last;
        expect(player.sourceCount, AudioEngine.upcomingRows + 1);
        expect(_rowIds(player).first, "t1000");
        expect(_rowIds(player).last, "t${1000 + AudioEngine.upcomingRows}");
        expect(player.loadRequest!.initialIndex, 0);
        expect(playbackState().queueIndex, 1000);
      },
    );

    test("reads only the rows it needs", () async {
      final items = _CountingItems(tracks(5000));
      await engine.setQueue(items, currentIndex: 10, generation: 2);
      expect(items.reads, lessThan(40));
      items.reads = 0;
      await engine.updateQueue(items, currentIndex: 10);
      expect(items.reads, lessThan(40));
    });

    test("slides forward as tracks finish, without a new decoder", () async {
      final events = <AudioEngineEvent>[];
      engine.attach(events.add);
      addTearDown(() => engine.detach(events.add));
      await setQueue(tracks(50), 0, autoplay: true);
      final player = audio.last;
      await _settle();

      for (var row = 1; row <= 3; row++) {
        player.autoAdvance(row);
        await _settle();
        expect(playbackState().queueIndex, row);
        expect(playbackState().trackId, "t$row");
        expect(_rowIds(player).last, "t${row + AudioEngine.upcomingRows}");
      }
      expect(audio.players, hasLength(1));
      // Played rows stay, so the playing row's index never shifts.
      expect(player.index, 3);
      expect(_rowIds(player).first, "t0");
      expect(
        events.whereType<AudioTrackChanged>().map((event) => event.index),
        [1, 2, 3],
      );
      expect(player.playing, isTrue);
    });

    test("stops at the end of the queue", () async {
      final completed = <AudioStateChanged>[];
      void listener(AudioEngineEvent event) {
        if (event is AudioStateChanged &&
            event.state == AudioPlaybackState.completed) {
          completed.add(event);
        }
      }

      engine.attach(listener);
      addTearDown(() => engine.detach(listener));
      await setQueue(["a", "b"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      expect(_rowIds(player), ["a", "b"]);
      expect(completed, isEmpty);

      player.autoAdvance(1);
      await _settle();
      expect(_rowIds(player), ["a", "b"]);
      player.complete();
      await _settle();
      expect(completed, hasLength(1));
    });

    test("wraps with repeat, returning to the first rows", () async {
      await engine.setQueue(
        _items(["a", "b", "c"]),
        currentIndex: 2,
        generation: 2,
        repeatMode: AudioRepeatMode.queue,
        autoplay: true,
      );
      final player = audio.last;
      await _settle();
      expect(player.sourceCount, AudioEngine.upcomingRows + 1);
      expect(_rowIds(player).take(4), ["c", "a", "b", "c"]);
      expect(player.loopMode, LoopModeMessage.off);

      player.autoAdvance(1);
      await _settle();
      final state = playbackState();
      expect(state.trackId, "a");
      expect(state.queueIndex, 0);
    });

    test("repeats a one-row queue gaplessly", () async {
      await engine.setQueue(
        _items(["a"]),
        currentIndex: 0,
        generation: 2,
        repeatMode: AudioRepeatMode.queue,
        autoplay: true,
      );
      final player = audio.last;
      await _settle();
      expect(_rowIds(player).toSet(), {"a"});
      expect(player.sourceCount, AudioEngine.upcomingRows + 1);

      player.autoAdvance(1);
      await _settle();
      expect(playbackState().queueIndex, 0);
      expect(playbackState().trackId, "a");
    });

    test("repeat-track loops the decoder and Next still moves on", () async {
      await engine.setQueue(
        _items(["a", "b"]),
        currentIndex: 0,
        generation: 2,
        repeatMode: AudioRepeatMode.track,
        autoplay: true,
      );
      final player = audio.last;
      await _settle();
      expect(player.loopMode, LoopModeMessage.one);

      await engine.handleMediaAction(MediaCommand.skipToNext);
      await _settle();
      expect(playbackState().trackId, "b");
    });

    test("unplayable rows are skipped", () async {
      await engine.setQueue(
        const [
          AudioQueueItem(trackId: "a", source: "/music/a.mp3"),
          AudioQueueItem(trackId: "gone", source: ""),
          AudioQueueItem(trackId: "c", source: "/music/c.mp3"),
        ],
        currentIndex: 0,
        generation: 2,
      );
      final player = audio.last;
      expect(_rowIds(player), ["a", "c"]);
      player.autoAdvance(1);
      await _settle();
      // Queue rows keep their numbers, which the app's queue also uses.
      expect(playbackState().queueIndex, 2);
    });

    test("a selection of nothing playable releases the decoder", () async {
      await setQueue(["a"], 0);
      final player = audio.last;
      await engine.setQueue(
        const [AudioQueueItem(trackId: "gone", source: "")],
        currentIndex: 0,
        generation: 4,
      );
      await _settle();
      expect(player.disposed, isTrue);
      expect(playbackState().hasSource, isFalse);
    });
  });

  group("editing the queue", () {
    test("keeps the decoder and its position", () async {
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      player.advanceTo(const Duration(seconds: 42));

      await updateQueue(["a", "x", "b", "c"], 0);
      await _settle();

      expect(audio.players, hasLength(1));
      expect(_rowIds(player), ["a", "x", "b", "c"]);
      expect(player.playing, isTrue);
      expect(player.position, const Duration(seconds: 42));
      expect(player.seeks, isEmpty);
      expect(playbackState().trackId, "a");
    });

    test("touches only rows after the first difference", () async {
      await setQueue(["a", "b", "c", "d"], 0);
      final player = audio.last;

      await updateQueue(["a", "b", "x", "d"], 0);
      expect(_rowIds(player), ["a", "b", "x", "d"]);
      // One removal of c and d, then two appends.
      expect(player.edits, 3);

      player.edits = 0;
      await updateQueue(["a", "b", "x", "d"], 0);
      expect(player.edits, 0);
    });

    test("beyond the window needs no native work", () async {
      final queue = [for (var i = 0; i < 100; i++) "t$i"];
      await setQueue(queue, 0);
      final player = audio.last;

      await updateQueue([...queue, "added"], 0);
      expect(player.edits, 0);
      await updateQueue(queue.sublist(0, 50), 0);
      expect(player.edits, 0);
      expect(player.sourceCount, AudioEngine.upcomingRows + 1);
    });

    test("a track moved under the playing row keeps playing there", () async {
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final player = audio.last;
      await _settle();

      await updateQueue(["c", "a", "b"], 1);
      await _settle();

      final state = playbackState();
      expect(state.trackId, "a");
      expect(state.queueIndex, 1);
      expect(_rowIds(player), ["a", "b"]);
      player.autoAdvance(1);
      await _settle();
      expect(playbackState().queueIndex, 2);
    });

    test("a removed active track plays before its successor", () async {
      await setQueue(["a", "b", "c", "d"], 1);
      final player = audio.last;
      await updateQueue(["a", "c", "d"], 1);

      expect(audio.players, hasLength(1));
      expect(_rowIds(player), ["b", "c", "d"]);
      expect(player.index, 0);
      var state = playbackState();
      expect(state.trackId, "b");
      expect(state.queueIndex, -1);

      player.autoAdvance(1);
      await _settle();
      state = playbackState();
      expect(state.trackId, "c");
      expect(state.queueIndex, 1);
      expect(state.generation.isOdd, isTrue);

      // The predecessor of the removed track is the app's to select.
      expect(
        await engine.handleMediaAction(MediaCommand.skipToPrevious),
        isFalse,
      );
    });

    test("a removed active track does not repeat", () async {
      await engine.setQueue(
        _items(["a", "b"]),
        currentIndex: 0,
        generation: 2,
        repeatMode: AudioRepeatMode.track,
      );
      final player = audio.last;
      expect(player.loopMode, LoopModeMessage.one);

      await engine.updateQueue(
        _items(["b"]),
        currentIndex: 0,
        repeatMode: AudioRepeatMode.track,
      );
      expect(player.loopMode, LoopModeMessage.off);
      player.autoAdvance(1);
      await _settle();
      expect(player.loopMode, LoopModeMessage.one);
    });

    test("changing the repeat mode applies in place", () async {
      await setQueue(["a", "b"], 1);
      final player = audio.last;
      expect(_rowIds(player), ["b"]);

      await engine.updateQueue(
        _items(["a", "b"]),
        currentIndex: 1,
        repeatMode: AudioRepeatMode.queue,
      );
      expect(_rowIds(player).take(3), ["b", "a", "b"]);

      await engine.updateQueue(_items(["a", "b"]), currentIndex: 1);
      expect(_rowIds(player), ["b"]);
      expect(audio.players, hasLength(1));
    });

    test("a transition during an edit is followed", () async {
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      final gate = player.editGate = Completer<void>();
      final edit = updateQueue(["a", "b", "x", "y"], 0);
      await _settle();

      player.autoAdvance(1);
      await _settle();
      gate.complete();
      await edit;
      await _settle();

      final state = playbackState();
      expect(state.trackId, "b");
      expect(state.queueIndex, 1);
      expect(_rowIds(player), ["a", "b", "x", "y"]);
      expect(audio.players, hasLength(1));
    });

    test("a transition reports the row an edit has just moved", () async {
      final events = <AudioTrackChanged>[];
      void listener(AudioEngineEvent event) {
        if (event is AudioTrackChanged) events.add(event);
      }

      engine.attach(listener);
      addTearDown(() => engine.detach(listener));
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      // Holds the first edit's native work, so the second waits its turn.
      final gate = player.editGate = Completer<void>();
      final first = updateQueue(["a", "b", "x"], 0);
      await _settle();
      final second = updateQueue(["b", "a", "x"], 1);

      player.autoAdvance(1);
      await _settle();
      expect(events.single.trackId, "b");
      expect(events.single.index, 0);
      expect(playbackState().queueIndex, 0);

      gate.complete();
      await Future.wait([first, second]);
    });

    test("a row leaving the queue as the decoder reaches it", () async {
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      final gate = player.editGate = Completer<void>();
      final first = updateQueue(["a", "b", "x"], 0);
      await _settle();
      final second = updateQueue(["a", "x"], 0);

      player.autoAdvance(1);
      await _settle();
      final state = playbackState();
      expect(state.trackId, "b");
      expect(state.queueIndex, -1);

      gate.complete();
      await Future.wait([first, second]);
    });

    test("adding to a finished queue does not restart playback", () async {
      await setQueue(["a"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      player.complete();
      await _settle();
      final seeks = player.seeks.length;

      await updateQueue(["a", "b"], 0);
      await _settle();
      expect(_rowIds(player), ["a", "b"]);
      expect(player.index, 0);
      expect(player.seeks, hasLength(seeks));
      expect(playbackState().trackId, "a");
    });

    test("edits arriving together end at the last one", () async {
      await setQueue(["a", "b"], 0);
      final player = audio.last;
      await Future.wait([
        updateQueue(["a", "x"], 0),
        updateQueue(["a", "y"], 0),
        updateQueue(["a", "z"], 0),
      ]);
      expect(_rowIds(player), ["a", "z"]);
    });

    test("a hung edit on a retired decoder does not block the next", () async {
      await setQueue(["a", "b"], 0);
      final retired = audio.last;
      retired.editGate = Completer<void>();
      unawaited(updateQueue(["a", "x"], 0));
      await _settle();

      await setQueue(["c", "d"], 0, generation: 4);
      final player = audio.last;
      await updateQueue(["c", "e"], 0).timeout(const Duration(seconds: 2));
      expect(_rowIds(player), ["c", "e"]);
    });

    test(
      "a late edit on a retired decoder leaves the new rows alone",
      () async {
        await setQueue(["a", "b"], 0);
        final retired = audio.last;
        final gate = retired.editGate = Completer<void>();
        unawaited(updateQueue(["a", "x", "y"], 0));
        await _settle();

        await setQueue(["c", "d"], 0, generation: 4);
        final player = audio.last;
        gate.complete();
        await _settle();
        expect(_rowIds(player), ["c", "d"]);
        player.autoAdvance(1);
        await _settle();
        expect(playbackState().trackId, "d");
      },
    );

    test("an edit that fails is reported to its caller", () async {
      await setQueue(["a", "b"], 0);
      final player = audio.last;
      final gate = player.editGate = Completer<void>();
      final edit = updateQueue(["a", "x"], 0);
      await _settle();
      gate.completeError(StateError("gone"));
      await expectLater(edit, throwsStateError);
      // The app releases a decoder that fails, but the next edit still runs.
      await updateQueue(["a", "y"], 0).timeout(const Duration(seconds: 2));
      expect(_rowIds(player), contains("y"));
    });
  });

  group("skipping", () {
    test("Next plays the next row on the same decoder", () async {
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final player = audio.last;
      await _settle();

      expect(await engine.handleMediaAction(MediaCommand.skipToNext), isTrue);
      await _settle();
      expect(playbackState().trackId, "b");
      expect(audio.players, hasLength(1));
      expect(player.playing, isTrue);
    });

    test("Next at the end of the queue pauses and rewinds", () async {
      await setQueue(["a"], 0, autoplay: true);
      final player = audio.last;
      await _settle();

      expect(await engine.handleMediaAction(MediaCommand.skipToNext), isTrue);
      await _settle();
      expect(player.playing, isFalse);
      expect(player.seeks, [Duration.zero]);
    });

    test("Previous rewinds a track already under way", () async {
      await setQueue(["a", "b"], 1, autoplay: true);
      final player = audio.last;
      await _settle();
      player.advanceTo(const Duration(seconds: 30));
      await _settle();

      expect(
        await engine.handleMediaAction(MediaCommand.skipToPrevious),
        isTrue,
      );
      expect(player.seeks, [Duration.zero]);
    });

    test("Previous leaves earlier rows to the app", () async {
      await setQueue(["a", "b"], 1, autoplay: true);
      await _settle();
      expect(
        await engine.handleMediaAction(MediaCommand.skipToPrevious),
        isFalse,
      );
      expect(audio.last.seeks, isEmpty);
    });

    test("Previous on the first row rewinds, unless the queue wraps", () async {
      await setQueue(["a", "b"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      expect(
        await engine.handleMediaAction(MediaCommand.skipToPrevious),
        isTrue,
      );
      expect(player.seeks, [Duration.zero]);

      await engine.setQueue(
        _items(["a", "b"]),
        currentIndex: 0,
        generation: 4,
        repeatMode: AudioRepeatMode.queue,
      );
      expect(
        await engine.handleMediaAction(MediaCommand.skipToPrevious),
        isFalse,
      );
    });
  });

  group("a decoder that runs out of rows", () {
    test("continues with the queue instead of completing", () async {
      final states = <AudioPlaybackState>[];
      void listener(AudioEngineEvent event) {
        if (event is AudioStateChanged) states.add(event.state);
      }

      engine.attach(listener);
      addTearDown(() => engine.detach(listener));
      final queue = [for (var i = 0; i < 30; i++) "t$i"];
      await setQueue(queue, 0, autoplay: true);
      final player = audio.last;
      await _settle();
      states.clear();

      // It reached the end of its rows before this isolate could top them up.
      player.complete();
      await _settle();

      expect(states, isNot(contains(AudioPlaybackState.completed)));
      expect(playbackState().trackId, "t1");
      expect(player.index, 1);
      expect(player.playing, isTrue);
    });

    test("stays paused when the listener paused", () async {
      final queue = [for (var i = 0; i < 30; i++) "t$i"];
      await setQueue(queue, 0);
      final player = audio.last;
      await _settle();
      player.complete();
      await _settle();
      expect(playbackState().trackId, "t1");
      expect(player.playing, isFalse);
    });
  });

  test("negative seeks clamp to the start", () async {
    await setQueue(["a"], 0);
    await engine.seek(const Duration(seconds: -5));

    expect(audio.last.seeks, [Duration.zero]);
  });

  test(
    "advancing to an equally long track reports its duration after it loads",
    () async {
      final events = <AudioEngineEvent>[];
      engine.attach(events.add);
      addTearDown(() => engine.detach(events.add));
      await setQueue(["a", "b"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      expect(session.metadata.last.duration, FakeAudioPlayer.trackDuration);

      events.clear();
      // The fake reports the same duration for every row, which just_audio's
      // distinct durationStream never repeats.
      player.autoAdvance(1);
      await _settle();

      final generation = events
          .whereType<AudioTrackChanged>()
          .single
          .generation;
      final loaded = events.indexWhere(
        (event) => event is AudioLoaded && event.generation == generation,
      );
      final duration = events.lastIndexWhere(
        (event) =>
            event is AudioDurationChanged &&
            event.generation == generation &&
            event.duration == FakeAudioPlayer.trackDuration,
      );
      expect(loaded, isNonNegative);
      // The app ignores durations until the transition has loaded.
      expect(duration, greaterThan(loaded));
      expect(session.metadata.last.title, "b");
      expect(session.metadata.last.duration, FakeAudioPlayer.trackDuration);
    },
  );

  test(
    "every phase change anchors the system timeline at the exact playhead",
    () async {
      await setQueue(["a"], 0, autoplay: true);
      final player = audio.last;
      await _settle();
      player.advanceTo(const Duration(milliseconds: 10200));
      await _settle();
      // The same one-second tick: no position event is published.
      player.advanceTo(const Duration(milliseconds: 10900));
      await _settle();

      player.stall();
      await _settle();
      var state = session.states.last;
      expect(state.status, PlaybackStatus.buffering);
      expect(state.position, const Duration(milliseconds: 10900));

      player.recover();
      await _settle();
      state = session.states.last;
      expect(state.status, PlaybackStatus.playing);
      expect(state.position.inMilliseconds, inInclusiveRange(10900, 10999));

      await engine.pause();
      await _settle();
      final paused = session.states.last;
      expect(paused.status, PlaybackStatus.paused);
      await engine.resume();
      await _settle();
      state = session.states.last;
      expect(state.status, PlaybackStatus.playing);
      // The fake decoder's clock does not run, so allow for just_audio's
      // extrapolation between the last event and the pause.
      expect(
        (state.position - paused.position).abs(),
        lessThan(const Duration(milliseconds: 100)),
      );
    },
  );

  test("releasing the decoder stops the system playback state", () async {
    await setQueue(["a"], 0, autoplay: true);
    await _settle();
    expect(session.states.last.status, PlaybackStatus.playing);

    await engine.clearSource();
    await _settle();

    expect(session.states.last.status, PlaybackStatus.paused);
  });

  group("normalization gain", () {
    List<AudioQueueItem> gained(Map<String, double> gains) => [
      for (final MapEntry(key: id, value: gain) in gains.entries)
        AudioQueueItem(trackId: id, source: "/music/$id.mp3", gain: gain),
    ];

    tearDown(() => engine.setVolume(1));

    test("scales the volume and switches with the track", () async {
      engine.setVolume(0.8);
      await engine.setQueue(
        gained({"a": 0.5, "b": 0.25}),
        currentIndex: 0,
        generation: 2,
        autoplay: true,
      );
      final player = audio.last;
      await _settle();
      expect(player.volumes.last, closeTo(0.4, 1e-9));

      player.autoAdvance(1);
      await _settle();
      expect(player.volumes.last, closeTo(0.2, 1e-9));

      // The listener's volume stays the listener's: the gain scales it.
      engine.setVolume(0.4);
      await _settle();
      expect(player.volumes.last, closeTo(0.1, 1e-9));
    });

    test("a new gain for the playing track fades in", () async {
      await engine.setQueue(
        gained({"a": 1, "b": 1}),
        currentIndex: 0,
        generation: 2,
        autoplay: true,
      );
      final player = audio.last;
      await _settle();
      final before = player.volumes.length;

      await engine.updateQueue(gained({"a": 0.5, "b": 1}), currentIndex: 0);
      await Future<void>.delayed(AudioEngine.gainRamp ~/ 2);
      final halfway = player.volumes.last;
      expect(halfway, inExclusiveRange(0.5, 1));
      await Future<void>.delayed(AudioEngine.gainRamp);
      final steps = player.volumes.sublist(before);
      expect(steps.last, closeTo(0.5, 1e-9));
      expect(steps.length, greaterThan(10));
      // Only downwards, never a jump past the target.
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], lessThanOrEqualTo(steps[i - 1]));
        expect(steps[i], greaterThanOrEqualTo(0.5 - 1e-9));
      }
      // The same queue rebuilt (a reorder) keeps the reached level.
      await engine.updateQueue(gained({"b": 1, "a": 0.5}), currentIndex: 1);
      await _settle();
      expect(audio.last.volumes.last, closeTo(0.5, 1e-9));
    });

    test("a preview stream plays at its own gain", () async {
      await engine.loadSource("/music/preview.mp3", generation: 2, gain: 0.7);
      expect(audio.last.volumes.last, closeTo(0.7, 1e-9));
    });

    group("boosting quiet tracks", () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test(
        "Android adds gain above full volume with LoudnessEnhancer",
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          expect(AudioEngine.maxBoostDb, 12);
          expect(AudioEngine.limiterHeadroomDb, 6);
          final boost = AudioEngine.maxGain; // +12 dB
          await engine.setQueue(
            gained({"quiet": boost, "loud": 0.5}),
            currentIndex: 0,
            generation: 2,
            autoplay: true,
          );
          final player = audio.last;
          await _settle();
          expect(player.hasEnhancer, isTrue);
          expect(player.volumes.last, 1);
          expect(player.activeBoostDb, closeTo(12, 0.01));

          // A cut switches the effect off: the plain path, as before.
          player.autoAdvance(1);
          await _settle();
          expect(player.volumes.last, closeTo(0.5, 1e-9));
          expect(player.boostEnabled, isFalse);

          // Boosts only scale what the listener chose; mute stays silent.
          engine.setVolume(0);
          await _settle();
          expect(player.volumes.last, 0);
          expect(player.activeBoostDb, 0);
        },
      );

      test("mpv's cubic volume takes the cube root of a gain", () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        expect(AudioEngine.maxBoostDb, 6);
        expect(AudioEngine.limiterHeadroomDb, 0);
        engine.setVolume(0.8);
        await engine.setQueue(
          gained({"quiet": AudioEngine.maxGain, "loud": 0.125}),
          currentIndex: 0,
          generation: 2,
          autoplay: true,
        );
        final player = audio.last;
        await _settle();
        expect(player.hasEnhancer, isFalse);
        // mpv plays (volume/100)^3: 0.8^3 x 2 (+6 dB), within its 130%.
        final level = player.volumes.last;
        expect(level, closeTo(0.8 * 1.2599, 1e-3));
        expect(level, lessThanOrEqualTo(1.3));

        player.autoAdvance(1);
        await _settle();
        // -18 dB of amplitude is a factor of 0.5 on mpv's volume.
        expect(player.volumes.last, closeTo(0.4, 1e-9));
      });

      test("Apple decoders only attenuate", () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        expect(AudioEngine.maxBoostDb, 0);
        await engine.setQueue(
          gained({"quiet": 2}),
          currentIndex: 0,
          generation: 2,
          autoplay: true,
        );
        await _settle();
        expect(audio.last.volumes.last, 1);
      });
    });

    group("at a gapless transition", () {
      const end = FakeAudioPlayer.trackDuration;

      Future<FakeAudioPlayer> playing(Map<String, double> gains) async {
        await engine.setQueue(
          gained(gains),
          currentIndex: 0,
          generation: 2,
          autoplay: true,
        );
        await _settle();
        return audio.last;
      }

      Future<void> wait(int milliseconds) =>
          Future<void>.delayed(Duration(milliseconds: milliseconds));

      test("a quieter next track is reached by the boundary, before the "
          "engine reports the transition", () async {
        final player = await playing({"a": 1, "b": 0.25});
        // The fake's clock runs while playing: 600 ms remain.
        player.advanceTo(end - const Duration(milliseconds: 600));
        await wait(250);
        // Well before the lead: the outgoing track is untouched.
        expect(player.volumes.last, 1);
        await wait(450);
        // At the boundary, with no transition reported yet.
        expect(player.volumes.last, closeTo(0.25, 1e-9));

        final before = player.volumes.length;
        player.autoAdvance(1);
        await _settle();
        // The report changes nothing audible.
        expect(
          player.volumes.sublist(before),
          everyElement(closeTo(0.25, 1e-9)),
        );
      });

      test("a louder next track switches at the boundary", () async {
        final player = await playing({"a": 0.25, "b": 1});
        player.advanceTo(end - const Duration(milliseconds: 300));
        await wait(200);
        // A louder track never lifts the outgoing tail early.
        expect(player.volumes.last, closeTo(0.25, 1e-9));
        await wait(200);
        expect(player.volumes.last, 1);
        player.autoAdvance(1);
        await _settle();
        expect(player.volumes.last, 1);
      });

      test(
        "pausing or seeking away near the end undoes the approach",
        () async {
          final player = await playing({"a": 1, "b": 0.25});
          player.advanceTo(end - const Duration(milliseconds: 120));
          await wait(60);
          expect(player.volumes.last, lessThan(1));

          await engine.pause();
          await _settle();
          expect(player.volumes.last, 1);

          await engine.resume();
          await _settle();
          await engine.seek(const Duration(seconds: 10));
          await _settle();
          expect(player.volumes.last, 1);
        },
      );

      test("still fades when the backend forgets the duration", () async {
        // just_audio_media_kit clears it whenever the playlist changes, which
        // sliding the window does right after each transition; just_audio
        // keeps the row's last known duration.
        final player = await playing({"a": 1, "b": 0.25, "c": 1});
        player.forgetsDurationOnEdit = true;
        await engine.updateQueue(
          gained({"a": 1, "b": 0.25, "x": 1}),
          currentIndex: 0,
        );
        await _settle();

        player.advanceTo(end - const Duration(milliseconds: 300));
        await wait(450);
        expect(player.volumes.last, closeTo(0.25, 1e-9));
      });

      test("the gain of a row that became next is used", () async {
        final player = await playing({"a": 1, "b": 1});
        await engine.updateQueue(
          gained({"a": 1, "quiet": 0.25, "b": 1}),
          currentIndex: 0,
        );
        await _settle();
        player.advanceTo(end - const Duration(milliseconds: 300));
        await wait(450);
        expect(player.volumes.last, closeTo(0.25, 1e-9));
      });

      test("equal gains and repeat-one leave the volume alone", () async {
        var player = await playing({"a": 0.5, "b": 0.5});
        player.advanceTo(end - const Duration(milliseconds: 100));
        await wait(150);
        expect(player.volumes.toSet(), {0.5});

        await engine.setQueue(
          gained({"a": 1, "b": 0.25}),
          currentIndex: 0,
          generation: 4,
          autoplay: true,
          repeatMode: AudioRepeatMode.track,
        );
        await _settle();
        player = audio.last;
        player.advanceTo(end - const Duration(milliseconds: 100));
        await wait(150);
        expect(player.volumes.toSet(), {1});
      });
    });
  });
}

/// A queue that counts how many rows the engine reads.
class _CountingItems extends ListBase<AudioQueueItem> {
  _CountingItems(this._ids);

  final List<String> _ids;
  int reads = 0;

  @override
  int get length => _ids.length;

  @override
  set length(int value) => throw UnsupportedError("read-only");

  @override
  AudioQueueItem operator [](int index) {
    reads++;
    final id = _ids[index];
    return AudioQueueItem(trackId: id, source: "/music/$id.mp3");
  }

  @override
  void operator []=(int index, AudioQueueItem value) =>
      throw UnsupportedError("read-only");
}
