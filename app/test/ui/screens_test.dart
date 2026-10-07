import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/melody_audio.dart" show AudioEngineSnapshot;
import "package:melody/ui/app_state.dart";
import "package:melody/services.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/library_service.dart";
import "package:melody/application/models.dart";
import "package:melody/application/catalog.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/application/package_runtime.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/platform/paths.dart";
import "package:melody/ui/desktop/player_bar.dart";
import "package:melody/ui/desktop/shell.dart";
import "package:melody/ui/mobile/player.dart";
import "package:melody/ui/mobile/shell.dart";
import "package:melody/ui/shared/theme.dart";
import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

import "../support/fake_worker.dart";

/// Renders every screen of both presentations. Any overflow or framework
/// error fails the test. Set MELODY_SCREENSHOTS=1 with --update-goldens to
/// write PNGs under test/ui/screenshots for visual review.
final _screenshots = Platform.environment["MELODY_SCREENSHOTS"] == "1";

class _QuietMediaSession extends FlutterMediaSessionPlatform {
  @override
  Future<void> activate() async {}
  @override
  Future<void> deactivate() async {}
  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {}
  @override
  Future<void> updatePlaybackState(PlaybackState state) async {}
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
  Future<void> setBackgroundKeepAlive(bool enabled) async {}
  @override
  Future<void> setWindowsAppUserModelId(
    String id, {
    String? displayName,
    String? iconPath,
  }) async {}
  @override
  Stream<MediaAction> get onMediaAction => const Stream.empty();
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final file in files) {
      if (File(file).existsSync()) {
        loader.addFont(
          Future.value(ByteData.sublistView(File(file).readAsBytesSync())),
        );
      }
    }
    await loader.load();
  }

  // flutter_tester lives under bin/cache/artifacts/engine/<platform>/.
  var directory = p.dirname(Platform.resolvedExecutable);
  while (!Directory(p.join(directory, "material_fonts")).existsSync() &&
      p.dirname(directory) != directory) {
    directory = p.dirname(directory);
  }
  final material = p.join(directory, "material_fonts");
  await family("MaterialIcons", [
    p.join(material, "materialicons-regular.otf"),
  ]);
  await family("Roboto", [
    for (final weight in ["regular", "medium", "bold"])
      p.join(material, "roboto-$weight.ttf"),
  ]);
  await family("Segoe UI", [
    for (final name in ["segoeui", "seguisb", "segoeuib", "segoeuii"])
      "C:/Windows/Fonts/$name.ttf",
  ]);
}

/// [defaultMusic] is the platform default folder, when the library was
/// set up in a different one.
Future<MelodyApp> _app(
  Directory root, {
  required bool mobile,
  String? defaultMusic,
}) async {
  final music = p.join(root.path, "Music");
  final paths = AppPaths(
    dataDirectory: root.path,
    defaultMusicDirectory: defaultMusic ?? music,
  );
  final store = ApplicationStore.open(
    paths.stateDatabase,
    defaultDownloadDirectory: music,
  );
  final manager = MusicManager.open(paths.libraryDatabase, music);
  final library = LibraryService(manager, store);
  final ids = <String>[];
  for (final (index, title) in [
    "Midnight City",
    "Weightless",
    "Clair de Lune",
  ].indexed) {
    final path = p.join(music, "$title.mp3");
    await File("test/fixtures/artwork/cover.mp3").copy(path);
    await File(path).writeAsBytes([index], mode: FileMode.append);
    final id = await manager.addTrack(
      path,
      title: title,
      source: "https://youtu.be/abcdefghij$index",
    );
    store.saveTrackDetails(
      id,
      TrackDetails(
        uploader: "Artist $index",
        duration: 200.0 + index,
        favorite: index != 1,
        sourceName: "YouTube Music",
      ),
    );
    ids.add(id);
  }
  final playlist = manager.createPlaylist("Late night");
  manager.addTracksToPlaylist(playlist, ids);
  store.set("recent_tracks", ids.reversed.toList());
  store.set("playback", {
    "queue": ids,
    "current_index": 1,
    "position_ms": 64000,
    "repeat": "playlist",
  });
  store.saveDownloads([
    DownloadRecord(
      id: "d1",
      url: "https://youtu.be/abcdefghij0",
      title: "Midnight City",
      status: DownloadStatus.completed,
      progress: 1,
      trackIds: [ids[0]],
    ),
    DownloadRecord(
      id: "d2",
      url: "https://youtu.be/zzzzzzzzzzz",
      title: "A failed song",
      status: DownloadStatus.failed,
      error: "The network request failed. Check your connection and retry.",
    ),
  ]);
  final worker = WorkerClient(FakeWorkerTransport());
  final thumbnails = ThumbnailCache(paths.thumbnails);
  final downloads = await DownloadCoordinator.open(
    manager,
    store,
    store.settings,
    worker,
    thumbnails: thumbnails,
  );
  final catalog = MusicCatalog(worker, () => const {});
  final services = AppServices(
    paths: paths,
    store: store,
    manager: manager,
    library: library,
    thumbnails: thumbnails,
    worker: worker,
    catalog: catalog,
    downloads: downloads,
    ytDlp: PackageRuntime(ytDlpRuntimeInfo, store, worker),
    ytMusic: PackageRuntime(ytMusicRuntimeInfo, store, worker),
    lyrics: LyricsLibrary(paths.lyrics, catalog.lyrics),
    lyricsEmbedder: null,
    availableTrackIds: ids.toSet(),
  );
  return MelodyApp(services, mobile: mobile);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(_loadFonts);

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-screens");
    FlutterMediaSessionPlatform.instance = _QuietMediaSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel("com.ryanheise.audio_session"),
          (_) async => null,
        );
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // SQLite may still hold the files on Windows; the OS cleans temp.
    }
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 400));
    if (_screenshots) {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile("screenshots/$name.png"),
      );
    }
  }

  Future<MelodyApp> pumpShell(
    WidgetTester tester, {
    required bool mobile,
    required Size size,
    String theme = "light",
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = (await tester.runAsync(() => _app(root, mobile: mobile)))!;
    addTearDown(app.close);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme("violet", Brightness.light),
        darkTheme: buildTheme("violet", Brightness.dark),
        themeMode: themeModeFor(theme),
        home: mobile ? MobileShell(app) : DesktopShell(app),
      ),
    );
    return app;
  }

  test("resetting settings keeps the music folder of a library", () async {
    final defaultMusic = p.join(root.path, "Default Music");
    final app = await _app(root, mobile: false, defaultMusic: defaultMusic);
    addTearDown(app.close);
    final folder = app.settings.downloadDirectory;
    expect(folder, isNot(defaultMusic));

    await app.settingsDraft.runDataAction("settings");
    // The library's files live in its folder; moving it would lose them.
    expect(app.settings.downloadDirectory, folder);
    expect(app.services.store.settings.downloadDirectory, folder);
    final tracks = app.services.manager.listTracks();
    expect(tracks, isNotEmpty);
    expect(
      p.isWithin(folder, app.services.manager.trackPath(tracks.first.id)),
      isTrue,
    );

    // Once the library is empty, the default folder applies again.
    await app.settingsDraft.runDataAction("everything");
    expect(app.settings.downloadDirectory, defaultMusic);
    expect(app.services.store.settings.downloadDirectory, defaultMusic);
    // Applied without a restart, so new downloads land where it records.
    expect(app.services.manager.musicFolder, defaultMusic);
  });

  test("a new music folder applies immediately, stored absolute", () async {
    final app = await _app(root, mobile: false);
    addTearDown(app.close);
    final original = app.settings.downloadDirectory;
    final requested = p.join(root.path, "Elsewhere", "..", "New Music");
    final expected = p.join(root.path, "New Music");

    app.settingsDraft.draft.downloadDirectory = requested;
    await expectLater(
      app.settingsDraft.save(),
      throwsA(isA<FormatException>()),
    );
    // A library's files stay where they are recorded.
    expect(app.services.manager.musicFolder, original);
    expect(app.services.store.settings.downloadDirectory, original);

    await app.settingsDraft.runDataAction("library");
    app.settingsDraft.draft.downloadDirectory = requested;
    await app.settingsDraft.save();
    expect(app.settings.downloadDirectory, expected);
    expect(app.services.store.settings.downloadDirectory, expected);
    expect(app.services.manager.musicFolder, expected);
    expect(Directory(expected).existsSync(), isTrue);
  });

  testWidgets("desktop screens render", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    await shoot(tester, "desktop_home");
    for (final (index, name) in [
      (1, "search"),
      (2, "library"),
      (3, "playlists"),
    ]) {
      app.navigate(index);
      await shoot(tester, "desktop_$name");
    }
    app.playlists.openPlaylist(app.services.manager.listPlaylists().single.id);
    await shoot(tester, "desktop_playlist_detail");
    for (final panel in [
      AppPanel.queue,
      AppPanel.lyrics,
      AppPanel.downloads,
      AppPanel.settings,
    ]) {
      app.openPanel(panel);
      await shoot(tester, "desktop_${panel.name}");
    }
  });

  for (final mobile in [false, true]) {
    testWidgets("${mobile ? "mobile" : "desktop"} messages leave the player "
        "controls uncovered", (tester) async {
      await pumpShell(
        tester,
        mobile: mobile,
        size: mobile ? const Size(390, 844) : const Size(1540, 960),
      );
      final shell = find.byType(mobile ? MobileShell : DesktopShell);
      ScaffoldMessenger.of(
        tester.element(shell),
      ).showSnackBar(const SnackBar(content: Text("Now playing: Weightless")));
      await tester.pump(const Duration(milliseconds: 500));

      final player = find.byType(mobile ? MiniPlayer : DesktopPlayerBar);
      expect(
        tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(tester.getRect(player).top),
      );
    });
  }

  for (final mobile in [false, true]) {
    testWidgets("${mobile ? "mobile" : "desktop"} audio formats explain "
        "themselves", (tester) async {
      final app = await pumpShell(
        tester,
        mobile: mobile,
        size: mobile ? const Size(390, 844) : const Size(1540, 960),
      );
      if (mobile) {
        await tester.tap(find.byTooltip("Settings"));
        await tester.pumpAndSettle();
        await tester.tap(find.text("Downloads"));
      } else {
        app.openPanel(AppPanel.settings);
      }
      await tester.pumpAndSettle();
      final field = find.text(DownloadFormat.mp3.label);
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      // The closed field explains the current choice.
      expect(find.text(DownloadFormat.mp3.reason), findsOneWidget);
      await shoot(
        tester,
        "${mobile ? "mobile" : "desktop"}_audio_format_field",
      );
      await tester.tap(field);
      await tester.pumpAndSettle();
      for (final format in DownloadFormat.values) {
        expect(find.text(format.reason), findsWidgets);
      }
      await shoot(tester, "${mobile ? "mobile" : "desktop"}_audio_formats");
    });

    testWidgets("${mobile ? "mobile" : "desktop"} playback draws only when the "
        "position visibly moves", (tester) async {
      final app = await pumpShell(
        tester,
        mobile: mobile,
        size: mobile ? const Size(390, 844) : const Size(1540, 960),
      );
      // The library, not Home, whose recommendations never load here.
      app.navigate(2);
      if (mobile) {
        await tester.tap(find.byTooltip("Open Now Playing"));
      }
      final trackId = app.playback.currentTrackId!;
      app.playback.onNativeReattach(
        AudioEngineSnapshot(
          generation: 0,
          trackId: trackId,
          source: app.services.manager.trackPath(trackId),
          position: const Duration(seconds: 64),
          duration: const Duration(seconds: 200),
          playing: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(app.positionAdvancing, isTrue);
      // A per-frame ticker would already have asked for the next frame.
      expect(tester.binding.hasScheduledFrame, isFalse);
      app.playback.onPosition(65000);
      await tester.pump();
      expect(find.text("1:05"), findsWidgets);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets("narrow desktop window collapses the rail", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1040, 700),
      theme: "dark",
    );
    await shoot(tester, "desktop_narrow_home");
    app.openPanel(AppPanel.queue);
    await shoot(tester, "desktop_narrow_queue");
  });

  testWidgets("mobile dark theme renders", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(390, 844),
      theme: "dark",
    );
    await shoot(tester, "mobile_dark_home");
    app.navigate(3);
    app.playlists.openPlaylist(app.services.manager.listPlaylists().single.id);
    await shoot(tester, "mobile_dark_playlist_detail");
    await tester.tap(find.byTooltip("Open Now Playing"));
    await tester.pumpAndSettle();
    await shoot(tester, "mobile_dark_now_playing");
  });

  testWidgets("small phone fits Now Playing", (tester) async {
    await pumpShell(tester, mobile: true, size: const Size(320, 568));
    await tester.tap(find.byTooltip("Open Now Playing"));
    await tester.pumpAndSettle();
    await shoot(tester, "mobile_small_now_playing");
  });

  for (final (name, size) in [
    ("tablet", const Size(820, 1180)),
    ("landscape", const Size(844, 390)),
  ]) {
    testWidgets("$name fits the mobile screens", (tester) async {
      final app = await pumpShell(tester, mobile: true, size: size);
      await shoot(tester, "mobile_${name}_home");
      for (final index in [1, 2, 3]) {
        app.navigate(index);
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.tap(find.byTooltip("Open Now Playing"));
      await tester.pumpAndSettle();
      await shoot(tester, "mobile_${name}_now_playing");
    });
  }

  testWidgets("mobile screens render", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(390, 844),
    );
    await shoot(tester, "mobile_home");
    for (final (index, name) in [
      (1, "search"),
      (2, "library"),
      (3, "playlists"),
    ]) {
      app.navigate(index);
      await shoot(tester, "mobile_$name");
    }
    await tester.tap(find.byTooltip("Open Now Playing"));
    await tester.pumpAndSettle();
    await shoot(tester, "mobile_now_playing");
    await tester.tap(find.text("Queue"));
    await tester.pumpAndSettle();
    await shoot(tester, "mobile_queue");
    await tester.tap(find.byTooltip("Back"));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip("Lyrics"));
    await tester.pump();
    // Saved lyrics are read from disk, which needs real async time.
    for (var attempt = 0; attempt < 50; attempt++) {
      if (find.text("Second line").evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text("Second line"), findsOneWidget);
    await shoot(tester, "mobile_lyrics");
    await tester.tap(find.byTooltip("Close lyrics"));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip("Close Now Playing"));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip("Settings"));
    await tester.pumpAndSettle();
    await shoot(tester, "mobile_settings");
    await tester.tap(find.text("Appearance"));
    await tester.pumpAndSettle();
    await shoot(tester, "mobile_settings_appearance");
  });
}
