import "dart:async";

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
      expect(replay.loadRequest!.initialIndex, 1);
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
      final gate = audio.loadGate = Completer<void>();
      final selection = setQueue(["c"], 0, generation: 4, autoplay: true);
      await _settle();

      engine.cancelLoad();
      gate.complete();
      await selection;
      await updateQueue(["b", "a"], 1);
      await _settle();

      expect(audio.last.sourceCount, 2);
      expect(audio.last.playing, isFalse);
      expect(playbackState().trackId, "a");
    },
  );

  test(
    "a removed active track plays before its successor in queue order",
    () async {
      await setQueue(["a", "b", "c", "d"], 1);
      await updateQueue(["a", "c", "d"], 1);

      final edited = audio.last;
      expect(edited.sourceCount, 4);
      expect(edited.loadRequest!.initialIndex, 1);
      expect(edited.loopMode, LoopModeMessage.off);
      var state = playbackState();
      expect(state.trackId, "b");
      expect(state.queueIndex, -1);

      edited.autoAdvance(2);
      await _settle();
      state = playbackState();
      expect(state.trackId, "c");
      expect(state.queueIndex, 1);
      expect(state.generation.isOdd, isTrue);
      expect(edited.sourceCount, 3);

      // The predecessor of the removed track stays reachable.
      await engine.handleMediaAction(MediaCommand.skipToPrevious);
      await _settle();
      state = playbackState();
      expect(state.trackId, "a");
      expect(state.queueIndex, 0);
    },
  );

  test(
    "a queue edit racing a native transition follows the new track",
    () async {
      await setQueue(["a", "b", "c"], 0, autoplay: true);
      final original = audio.last;
      final gate = audio.loadGate = Completer<void>();
      final edit = updateQueue(["a", "b", "c", "d"], 0);
      await _settle();

      original.autoAdvance(1);
      await _settle();
      gate.complete();
      await edit;
      await _settle();

      final state = playbackState();
      expect(state.trackId, "b");
      expect(state.queueIndex, 1);
      expect(audio.last.loadRequest!.initialIndex, 1);
      expect(audio.last.sourceCount, 4);
    },
  );

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
}
