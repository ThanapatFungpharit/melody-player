import "dart:async";

import "package:melody_audio/src/background_audio_session.dart";
import "package:melody_audio/src/managed_audio.dart";
import "package:flutter/services.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:just_audio_platform_interface/just_audio_platform_interface.dart";

import "support/fakes.dart";

Map<String, Object?> _item(String id) => {
  "track_id": id,
  "source": "/music/$id.mp3",
  "title": id,
};

List<Map<String, Object?>> _items(List<String> ids) =>
    ids.map(_item).toList(growable: false);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audioSessionChannel = MethodChannel("com.ryanheise.audio_session");
  final runtime = NativeAudioRuntime.instance;
  late FakeJustAudioPlatform audio;
  late RecordingMediaSessionPlatform session;

  Future<void> setQueue(
    List<String> ids,
    int index, {
    int generation = 2,
    bool autoplay = false,
    int positionMs = 0,
  }) async {
    await runtime.invokeMethod("set_queue", {
      "items": _items(ids),
      "current_index": index,
      "generation": generation,
      "repeat_mode": "off",
      "autoplay": autoplay,
      "position_ms": positionMs,
    });
  }

  Future<void> updateQueue(List<String> ids, int index) async {
    await runtime.invokeMethod("update_queue", {
      "items": _items(ids),
      "current_index": index,
      "repeat_mode": "off",
    });
  }

  Future<Map<String, Object?>> playbackState() async => Map.of(
    await runtime.invokeMethod("get_playback_state", null)
        as Map<String, Object?>,
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
    audio = FakeJustAudioPlatform();
    JustAudioPlatform.instance = audio;
    session = RecordingMediaSessionPlatform();
    FlutterMediaSessionPlatform.instance = session;
  });

  tearDown(() async {
    await runtime.invokeMethod("clear_source", null);
    await NativeMediaSessionRuntime.instance.deactivateForStop();
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

      await runtime.invokeMethod("load_source", {
        "source": "/music/preview.mp3",
        "generation": 4,
        "autoplay": false,
        "position_ms": 5000,
      });

      final preview = audio.last;
      expect(preview, isNot(same(first)));
      expect(preview.loadRequest!.initialPosition, const Duration(seconds: 5));
      expect(preview.seeks, isEmpty);
      expect((await playbackState())["position_ms"], 5000);
    },
  );

  test("Play and Resume restart a completed source", () async {
    await setQueue(["a"], 0, autoplay: true);
    final player = audio.last;
    await _settle();
    expect(player.playing, isTrue);

    player.complete();
    await _settle();
    await runtime.invokeMethod("play", {"position": 0});
    await _settle();
    expect(player.seeks, [Duration.zero]);

    player.complete();
    await _settle();
    await runtime.invokeMethod("resume", null);
    await _settle();
    expect(player.seeks, [Duration.zero, Duration.zero]);
  });

  test(
    "Play without a position during preparation keeps the load position",
    () async {
      await setQueue(["a"], 0);
      final gate = audio.loadGate = Completer<void>();
      final selection = setQueue(["b"], 0, generation: 4, positionMs: 30000);
      await _settle();

      await runtime.invokeMethod("play", {"position": 0});
      gate.complete();
      await selection;
      await _settle();

      final player = audio.last;
      expect(player.seeks, isEmpty);
      expect(player.playing, isTrue);
      expect(
        (await playbackState())["position_ms"],
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

      await runtime.invokeMethod("cancel_load", null);
      gate.complete();
      await selection;
      await updateQueue(["b", "a"], 1);
      await _settle();

      expect(audio.last.sourceCount, 2);
      expect(audio.last.playing, isFalse);
      expect((await playbackState())["track_id"], "a");
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
      var state = await playbackState();
      expect(state["track_id"], "b");
      expect(state["queue_index"], -1);

      edited.autoAdvance(2);
      await _settle();
      state = await playbackState();
      expect(state["track_id"], "c");
      expect(state["queue_index"], 1);
      expect((state["generation"] as int).isOdd, isTrue);
      expect(edited.sourceCount, 3);

      // The predecessor of the removed track stays reachable.
      await runtime.invokeMethod("skip_previous", null);
      await _settle();
      state = await playbackState();
      expect(state["track_id"], "a");
      expect(state["queue_index"], 0);
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

      final state = await playbackState();
      expect(state["track_id"], "b");
      expect(state["queue_index"], 1);
      expect(audio.last.loadRequest!.initialIndex, 1);
      expect(audio.last.sourceCount, 4);
    },
  );

  test("negative seeks clamp to the start", () async {
    await setQueue(["a"], 0);
    await runtime.invokeMethod("seek", {"position": -5000});

    expect(audio.last.seeks, [Duration.zero]);
  });

  test("releasing the decoder stops the system playback state", () async {
    await setQueue(["a"], 0, autoplay: true);
    await _settle();
    expect(session.states.last.status, PlaybackStatus.playing);

    await runtime.invokeMethod("clear_source", null);
    await _settle();

    expect(session.states.last.status, PlaybackStatus.paused);
  });
}
