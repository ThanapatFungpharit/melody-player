import "dart:async";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter_test/flutter_test.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flet_background_audio/src/background_audio_session.dart";

class _RecordingMediaSessionPlatform extends FlutterMediaSessionPlatform {
  final List<PlaybackState> states = [];
  Completer<MediaMetadata>? nextMetadata;

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {
    final waiting = nextMetadata;
    if (waiting != null && !waiting.isCompleted) waiting.complete(metadata);
  }

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

Future<List<int>> _portraitArtwork() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  for (var x = 0; x < 20; x++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(x.toDouble(), 0, 1, 16),
      ui.Paint()
        ..color = x.isEven
            ? const ui.Color(0xffff0000)
            : const ui.Color(0xff00ff00),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(20, 60);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

Future<int> _centerRed(String uri) async {
  final bytes = await File.fromUri(Uri.parse(uri)).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final index = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  final red = pixels!.getUint8(index);
  image.dispose();
  codec.dispose();
  return red;
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

  test(
    "native track changes honor the automatic focal point setting",
    () async {
      final directory = await Directory.systemTemp.createTemp(
        "melody-session-art-",
      );
      try {
        final source = File("${directory.path}/art.png");
        await source.writeAsBytes(await _portraitArtwork());
        final uri = source.uri.toString();

        await runtime.invokeMethod("sync", {
          "title": "Setup",
          "auto_focal_point_live_notifications": true,
        });
        platform.nextMetadata = Completer<MediaMetadata>();
        runtime.onNativeTrack(
          title: "Automatic",
          artist: "Artist",
          album: "Album",
          artworkUri: uri,
        );
        final automatic = await platform.nextMetadata!.future.timeout(
          const Duration(seconds: 5),
        );
        expect(await _centerRed(automatic.artworkUri!), greaterThan(50));

        await runtime.invokeMethod("sync", {
          "title": "Setup",
          "auto_focal_point_live_notifications": false,
        });
        platform.nextMetadata = Completer<MediaMetadata>();
        runtime.onNativeTrack(
          title: "Centered",
          artist: "Artist",
          album: "Album",
          artworkUri: uri,
        );
        final centered = await platform.nextMetadata!.future.timeout(
          const Duration(seconds: 5),
        );
        expect(await _centerRed(centered.artworkUri!), 0);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
