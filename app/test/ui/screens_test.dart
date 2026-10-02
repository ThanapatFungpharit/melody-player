import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody/app/app_state.dart";
import "package:melody/app/services.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/library_service.dart";
import "package:melody/application/models.dart";
import "package:melody/application/providers.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/application/yt_dlp_runtime.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/platform/paths.dart";
import "package:melody/ui/desktop/shell.dart";
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
  Future<void> setSkipIntervals({int forwardSeconds = 10, int backwardSeconds = 10}) async {}
  @override
  Future<void> setAutoHandleInterruptions(bool enabled) async {}
  @override
  Future<void> setBackgroundKeepAlive(bool enabled) async {}
  @override
  Future<void> setWindowsAppUserModelId(String id, {String? displayName, String? iconPath}) async {}
  @override
  Stream<MediaAction> get onMediaAction => const Stream.empty();
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final file in files) {
      if (File(file).existsSync()) {
        loader.addFont(Future.value(ByteData.sublistView(File(file).readAsBytesSync())));
      }
    }
    await loader.load();
  }

  // flutter_tester lives under bin/cache/artifacts/engine/<platform>/.
  var directory = p.dirname(Platform.resolvedExecutable);
  while (!Directory(p.join(directory, "material_fonts")).existsSync() && p.dirname(directory) != directory) {
    directory = p.dirname(directory);
  }
  final material = p.join(directory, "material_fonts");
  await family("MaterialIcons", [p.join(material, "materialicons-regular.otf")]);
  await family("Roboto", [
    for (final weight in ["regular", "medium", "bold"]) p.join(material, "roboto-$weight.ttf"),
  ]);
  await family("Segoe UI", [
    for (final name in ["segoeui", "seguisb", "segoeuib", "segoeuii"]) "C:/Windows/Fonts/$name.ttf",
  ]);
}

Future<MelodyApp> _app(Directory root, {required bool mobile}) async {
  final music = p.join(root.path, "Music");
  final paths = AppPaths(dataDirectory: root.path, defaultMusicDirectory: music);
  final store = ApplicationStore.open(paths.stateDatabase, defaultDownloadDirectory: music);
  final manager = MusicManager.open(paths.libraryDatabase, music);
  final library = LibraryService(manager, store);
  final ids = <String>[];
  for (final (index, title) in ["Midnight City", "Weightless", "Clair de Lune"].indexed) {
    final path = p.join(music, "$title.mp3");
    await File("test/fixtures/artwork/cover.mp3").copy(path);
    await File(path).writeAsBytes([index], mode: FileMode.append);
    final id = await manager.addTrack(path, title: title, source: "https://youtu.be/abcdefghij$index");
    store.saveTrackDetails(
      id,
      TrackDetails(uploader: "Artist $index", duration: 200.0 + index, favorite: index != 1, sourceName: "YouTube Music"),
    );
    ids.add(id);
  }
  final playlist = manager.createPlaylist("Late night");
  manager.addTracksToPlaylist(playlist, ids);
  store.set("recent_tracks", ids.reversed.toList());
  store.set("playback", {"queue": ids, "current_index": 1, "position_ms": 64000, "repeat": "playlist"});
  store.saveDownloads([
    DownloadRecord(id: "d1", url: "https://youtu.be/abcdefghij0", title: "Midnight City", status: "completed", progress: 1, trackIds: [ids[0]]),
    DownloadRecord(id: "d2", url: "https://youtu.be/zzzzzzzzzzz", title: "A failed song", status: "failed", error: "The network request failed. Check your connection and retry."),
  ]);
  final worker = WorkerClient(FakeWorkerTransport());
  final thumbnails = ThumbnailCache(paths.thumbnails);
  final downloads = await DownloadCoordinator.open(manager, store, store.settings, worker, thumbnails: thumbnails);
  final services = AppServices(
    paths: paths,
    store: store,
    manager: manager,
    library: library,
    thumbnails: thumbnails,
    worker: worker,
    providers: ProviderRegistry(worker, const {}),
    downloads: downloads,
    ytDlp: YtDlpRuntime(store, worker),
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
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
      await expectLater(find.byType(MaterialApp), matchesGoldenFile("screenshots/$name.png"));
    }
  }

  Future<MelodyApp> pumpShell(WidgetTester tester, {required bool mobile, required Size size, String theme = "light"}) async {
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

  testWidgets("desktop screens render", (tester) async {
    final app = await pumpShell(tester, mobile: false, size: const Size(1540, 960));
    await shoot(tester, "desktop_home");
    for (final (index, name) in [(1, "search"), (2, "library"), (3, "playlists")]) {
      app.navigate(index);
      await shoot(tester, "desktop_$name");
    }
    app.playlists.openPlaylist(app.services.manager.listPlaylists().single.id);
    await shoot(tester, "desktop_playlist_detail");
    for (final panel in [AppPanel.queue, AppPanel.downloads, AppPanel.settings]) {
      app.openPanel(panel);
      await shoot(tester, "desktop_${panel.name}");
    }
  });

  testWidgets("narrow desktop window collapses the rail", (tester) async {
    final app = await pumpShell(tester, mobile: false, size: const Size(1040, 700), theme: "dark");
    await shoot(tester, "desktop_narrow_home");
    app.openPanel(AppPanel.queue);
    await shoot(tester, "desktop_narrow_queue");
  });

  testWidgets("mobile screens render", (tester) async {
    final app = await pumpShell(tester, mobile: true, size: const Size(390, 844));
    await shoot(tester, "mobile_home");
    for (final (index, name) in [(1, "search"), (2, "library"), (3, "playlists")]) {
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
