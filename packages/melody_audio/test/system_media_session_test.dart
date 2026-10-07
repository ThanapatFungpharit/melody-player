import "dart:async";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:melody_audio/src/audio_engine.dart";
import "package:melody_audio/src/system_media_session.dart";

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
  final session = SystemMediaSession.instance;
  late RecordingMediaSessionPlatform platform;

  setUp(() {
    platform = RecordingMediaSessionPlatform();
    FlutterMediaSessionPlatform.instance = platform;
  });

  tearDown(() async {
    await session.deactivateForStop();
    FlutterMediaSessionPlatform.instance = originalPlatform;
  });

  test("platform action names map to media commands", () {
    expect(MediaCommand.parse("skipToNext"), MediaCommand.skipToNext);
    expect(MediaCommand.parse("toggleFavorite"), MediaCommand.toggleFavorite);
    expect(MediaCommand.parse("shuffle"), MediaCommand.shuffleUpcoming);
    expect(MediaCommand.parse("repeat"), MediaCommand.cycleRepeat);
    expect(MediaCommand.parse("somethingElse"), isNull);
  });

  group("built-in shuffle and repeat controls", () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    Set<String> published() => {
      for (final action in platform.availableActions.last!) action.name,
    };

    test("follow what the queue allows", () async {
      await session.sync(const MediaSessionState(title: "Track"));
      expect(published(), isNot(contains("shuffle")));
      expect(published(), isNot(contains("repeat")));
      await session.sync(
        const MediaSessionState(
          title: "Track",
          canShuffle: true,
          canRepeat: true,
          canFavorite: true,
          shortcuts: [MediaShortcut.favorite, MediaShortcut.shuffle],
        ),
      );
      expect(published(), containsAll(["shuffle", "repeat"]));
      // Custom buttons are Android only.
      expect(published(), isNot(contains("toggleFavorite")));
    });

    test("presses reach the app and reset the system toggles", () async {
      final received = <MediaCommand>[];
      void listener(MediaCommand command, Duration? _) => received.add(command);
      session.attach(listener);
      addTearDown(() => session.detach(listener));
      await session.sync(
        const MediaSessionState(
          title: "Track",
          canShuffle: true,
          canRepeat: true,
          repeatMode: AudioRepeatMode.queue,
        ),
      );
      final published = platform.states.length;

      platform.actions
        ..add(const MediaAction("shuffle"))
        ..add(const MediaAction("repeat"));
      await pumpEventQueue();

      expect(received, [
        MediaCommand.shuffleUpcoming,
        MediaCommand.cycleRepeat,
      ]);
      expect(platform.states.length, greaterThan(published));
      expect(platform.states.last.shuffleModeEnabled, isFalse);
      expect(platform.states.last.repeatMode, MediaRepeatMode.all);
    });
  });

  test("local artwork reaches each platform in a form it can open", () {
    const windowsUri = "file:///C:/Users/Me/My%20Music/art.png";
    const posixUri = "file:///Users/me/Library/Application%20Support/art.png";
    expect(
      platformArtwork(windowsUri, platform: TargetPlatform.windows),
      r"C:\Users\Me\My Music\art.png",
    );
    expect(
      platformArtwork(posixUri, platform: TargetPlatform.macOS),
      "/Users/me/Library/Application Support/art.png",
    );
    expect(
      platformArtwork(posixUri, platform: TargetPlatform.android),
      posixUri,
    );
    expect(
      platformArtwork(
        "https://i.ytimg.com/a.jpg",
        platform: TargetPlatform.windows,
      ),
      "https://i.ytimg.com/a.jpg",
    );
    expect(platformArtwork("", platform: TargetPlatform.windows), isNull);
  });

  test("commands the engine cannot carry out reach the app", () async {
    final received = <MediaCommand>[];
    void listener(MediaCommand command, Duration? _) => received.add(command);
    session.attach(listener);
    addTearDown(() => session.detach(listener));
    await session.sync(const MediaSessionState(title: "Track"));

    platform.actions
      ..add(
        MediaAction.custom(
          name: "toggleFavorite",
          customLabel: "Add favorite",
          customIconResource: "ic_melody_favorite_outline",
        ),
      )
      // Nothing is loaded, so the engine leaves Next to the app.
      ..add(MediaAction.skipToNext)
      ..add(const MediaAction("unsupported"));
    await pumpEventQueue();

    expect(received, [MediaCommand.toggleFavorite, MediaCommand.skipToNext]);
  });

  test("native transport state survives stale app snapshots", () async {
    const stale = MediaSessionState(
      title: "Track",
      position: Duration(seconds: 1),
      duration: Duration(seconds: 10),
      playing: true,
    );
    await session.sync(stale);

    session.onEngineEvent(
      const AudioPositionChanged(Duration(milliseconds: 1500), 0),
    );
    session.onEngineEvent(
      const AudioStateChanged(AudioPlaybackState.paused, 0),
    );
    await session.sync(stale);

    final state = platform.states.last;
    expect(state.status, PlaybackStatus.paused);
    expect(state.position, const Duration(milliseconds: 1500));
    expect(state.speed, greaterThan(0));

    session.onEngineEvent(
      const AudioStateChanged(AudioPlaybackState.playing, 0),
    );
    await session.sync(
      const MediaSessionState(
        title: "Track",
        position: Duration(milliseconds: 1500),
        duration: Duration(seconds: 10),
      ),
    );
    expect(platform.states.last.status, PlaybackStatus.playing);
  });

  test("decoder events during reactivation are not lost", () async {
    const snapshot = MediaSessionState(
      title: "Track",
      position: Duration(seconds: 1),
      duration: Duration(seconds: 200),
      playing: true,
    );
    await session.sync(snapshot);
    expect(platform.states.last.status, PlaybackStatus.playing);

    // The app returns to the foreground and republishes its last snapshot;
    // the decoder pauses while the platform session is being reattached.
    final gate = platform.activateGate = Completer<void>();
    final reattach = session.sync(snapshot, reattach: true);
    await pumpEventQueue();
    session
      ..onEngineEvent(
        const AudioPositionChanged(Duration(milliseconds: 42300), 0),
      )
      ..onEngineEvent(const AudioStateChanged(AudioPlaybackState.paused, 0));
    gate.complete();
    await reattach;

    final state = platform.states.last;
    expect(state.status, PlaybackStatus.paused);
    expect(state.position, const Duration(milliseconds: 42300));
  });

  test("a track change during reactivation restarts the timeline", () async {
    await session.sync(
      const MediaSessionState(
        title: "First",
        position: Duration(seconds: 150),
        duration: Duration(seconds: 200),
        playing: true,
      ),
    );
    session.onEngineEvent(
      const AudioPositionChanged(Duration(seconds: 151), 0),
    );

    final gate = platform.activateGate = Completer<void>();
    final reattach = session.sync(
      const MediaSessionState(title: "First", playing: true),
      reattach: true,
    );
    await pumpEventQueue();
    session.onEngineTrack(
      title: "Second",
      artist: "",
      album: "",
      artworkUri: "",
    );
    session
      ..onEngineEvent(const AudioTrackChanged("second", 1, 1))
      ..onEngineEvent(const AudioDurationChanged(Duration(seconds: 90), 1));
    gate.complete();
    await reattach;
    await session.sync(const MediaSessionState(title: "Second", playing: true));

    expect(platform.states.last.position, Duration.zero);
    expect(platform.metadata.last.title, "Second");
    expect(platform.metadata.last.duration, const Duration(seconds: 90));
  });

  test(
    "a failed deactivate still republishes metadata on reactivation",
    () async {
      await session.sync(const MediaSessionState(title: "Track"));
      expect(platform.metadata, hasLength(1));

      platform.failNextDeactivate = true;
      await expectLater(session.deactivateForStop(), throwsStateError);
      await session.sync(const MediaSessionState(title: "Track"));

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

        await session.sync(
          const MediaSessionState(title: "Setup", automaticFocalPoint: true),
        );
        platform.nextMetadata = Completer<MediaMetadata>();
        session.onEngineTrack(
          title: "Automatic",
          artist: "Artist",
          album: "Album",
          artworkUri: uri,
        );
        final automatic = await platform.nextMetadata!.future.timeout(
          const Duration(seconds: 5),
        );
        expect(await _centerRed(automatic.artworkUri!), greaterThan(50));

        await session.sync(const MediaSessionState(title: "Setup"));
        platform.nextMetadata = Completer<MediaMetadata>();
        session.onEngineTrack(
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

      await session.sync(
        MediaSessionState(
          title: "Automatic",
          artworkUri: uri,
          automaticFocalPoint: true,
        ),
      );
      final automatic = platform.metadata.last.artworkUri!;
      expect(automatic, isNot(uri));
      // Only the notification receives the square copy; the app keeps its
      // own uncropped thumbnail when it reattaches to the session.
      expect(session.currentMetadata.artworkUri, uri);
      // The whole 70x100 subject survives, scaled from 360 to 512 pixels.
      expect(await _redPixels(automatic), greaterThan(13000));

      await session.sync(
        MediaSessionState(title: "Automatic", artworkUri: uri),
      );
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
      await session.sync(
        MediaSessionState(
          title: "Paused stream",
          artworkUri: uri,
          automaticFocalPoint: true,
        ),
      );
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
