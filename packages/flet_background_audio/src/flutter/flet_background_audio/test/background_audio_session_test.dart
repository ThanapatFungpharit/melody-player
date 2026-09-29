import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flet_background_audio/src/background_audio_session.dart";

class _RecordingMediaSessionPlatform extends FlutterMediaSessionPlatform {
  final List<PlaybackState> states = [];

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {}

  @override
  Future<void> updatePlaybackState(PlaybackState state) async {
    states.add(state);
  }

  @override
  Future<void> updateAvailableActions(Set<MediaAction>? actions) async {}

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> setSkipIntervals({
    int forwardSeconds = 10,
    int backwardSeconds = 10,
  }) async {}

  @override
  Future<void> setAutoHandleInterruptions(bool enabled) async {}

  @override
  Future<void> setWindowsAppUserModelId(
    String id, {
    String? displayName,
    String? iconPath,
  }) async {}

  @override
  Stream<MediaAction> get onMediaAction => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPlatform = FlutterMediaSessionPlatform.instance;
  final runtime = NativeMediaSessionRuntime.instance;
  late _RecordingMediaSessionPlatform platform;

  setUp(() {
    platform = _RecordingMediaSessionPlatform();
    FlutterMediaSessionPlatform.instance = platform;
  });

  tearDown(() async {
    await runtime.deactivateForStop();
    FlutterMediaSessionPlatform.instance = originalPlatform;
  });

  test("native transport state survives stale Python playback syncs", () async {
    await runtime.invokeMethod("sync", {
      "title": "Track",
      "position_ms": 1000,
      "duration_ms": 10000,
      "playing": true,
    });

    runtime.onNativePlaybackEvent("position_change", {"position": 1500});
    runtime.onNativePlaybackEvent("state_change", {"state": "paused"});
    await runtime.invokeMethod("sync", {
      "title": "Track",
      "position_ms": 1000,
      "duration_ms": 10000,
      "playing": true,
    });

    final state = platform.states.last;
    expect(state.status, PlaybackStatus.paused);
    expect(state.position, const Duration(milliseconds: 1500));
    expect(state.speed, greaterThan(0));

    runtime.onNativePlaybackEvent("state_change", {"state": "playing"});
    await runtime.invokeMethod("sync", {
      "title": "Track",
      "position_ms": 1500,
      "duration_ms": 10000,
      "playing": false,
    });
    expect(platform.states.last.status, PlaybackStatus.playing);
  });
}
