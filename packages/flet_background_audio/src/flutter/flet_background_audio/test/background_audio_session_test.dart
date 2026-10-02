import "dart:async";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter_test/flutter_test.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flet_background_audio/src/background_audio_session.dart";

import "support/fakes.dart";

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

/// A 4:3 video thumbnail with black letterbox bars around 16:9 content: a
/// gray scene with a red subject well right of center.
Future<List<int>> _letterboxedThumbnail() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 45, 480, 270),
    ui.Paint()..color = const ui.Color(0xff606060),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(400, 130, 70, 100),
    ui.Paint()..color = const ui.Color(0xffff0000),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(480, 360);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

Future<int> _redPixels(String uri) async {
  final bytes = await File.fromUri(Uri.parse(uri)).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  var count = 0;
  for (var i = 0; i < pixels!.lengthInBytes; i += 4) {
    if (pixels.getUint8(i) > 200 && pixels.getUint8(i + 1) < 60) count++;
  }
  image.dispose();
  codec.dispose();
  return count;
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
  late RecordingMediaSessionPlatform platform;

  setUp(() {
    platform = RecordingMediaSessionPlatform();
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
    "a failed deactivate still republishes metadata on reactivation",
    () async {
      await runtime.invokeMethod("sync", {"title": "Track"});
      expect(platform.metadata, hasLength(1));

      platform.failNextDeactivate = true;
      await expectLater(runtime.deactivateForStop(), throwsStateError);
      await runtime.invokeMethod("sync", {"title": "Track"});

      expect(platform.metadata, hasLength(2));
      expect(platform.metadata.last.title, "Track");
    },
  );

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

  test("synced video thumbnails are cropped around the subject", () async {
    final directory = await Directory.systemTemp.createTemp(
      "melody-session-thumb-",
    );
    try {
      final source = File("${directory.path}/thumb.png");
      await source.writeAsBytes(await _letterboxedThumbnail());
      final uri = source.uri.toString();

      await runtime.invokeMethod("sync", {
        "title": "Automatic",
        "artwork_uri": uri,
        "auto_focal_point_live_notifications": true,
      });
      final automatic = platform.metadata.last.artworkUri!;
      expect(automatic, isNot(uri));
      // Only the notification receives the square copy; the app keeps its
      // own uncropped thumbnail when it reattaches to the session.
      expect(runtime.currentMetadata["artwork_uri"], uri);
      // The whole 70x100 subject survives, scaled from 360 to 512 pixels.
      expect(await _redPixels(automatic), greaterThan(13000));

      await runtime.invokeMethod("sync", {
        "title": "Automatic",
        "artwork_uri": uri,
        "auto_focal_point_live_notifications": false,
      });
      final centered = platform.metadata.last.artworkUri!;
      expect(centered, isNot(automatic));
      expect(await _redPixels(centered), lessThan(5000));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test("slow remote artwork is replaced with the cropped copy", () async {
    final artwork = await _letterboxedThumbnail();
    // The test binding answers every HttpClient request with 400.
    final httpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      request.response
        ..headers.contentType = ContentType("image", "png")
        ..add(artwork);
      await request.response.close();
    });
    try {
      final uri = "http://127.0.0.1:${server.port}/thumb.png";
      await runtime.invokeMethod("sync", {
        "title": "Paused stream",
        "artwork_uri": uri,
        "playing": false,
        "auto_focal_point_live_notifications": true,
      });
      expect(platform.metadata.last.artworkUri, uri);

      platform.nextMetadata = Completer<MediaMetadata>();
      final replaced = await platform.nextMetadata!.future.timeout(
        const Duration(seconds: 10),
      );
      expect(replaced.title, "Paused stream");
      expect(replaced.artworkUri, isNot(uri));
      expect(await _redPixels(replaced.artworkUri!), greaterThan(13000));
    } finally {
      await server.close(force: true);
      HttpOverrides.global = httpOverrides;
    }
  });
}
