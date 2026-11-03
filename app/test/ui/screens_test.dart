import "../support/temp.dart";
import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/melody_audio.dart" show AudioEngineSnapshot;
import "package:melody/ui/app_state.dart";
import "package:melody/services.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/library_service.dart";
import "package:melody/application/loudness.dart";
import "package:melody/core/loudness.dart";
import "package:melody/application/models.dart";
import "package:melody/application/catalog.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/application/package_runtime.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/library/models.dart";
import "package:melody/platform/paths.dart";
import "package:melody/ui/desktop/controls.dart";
import "package:melody/ui/desktop/pages/library_page.dart";
import "package:melody/ui/desktop/player_bar.dart";
import "package:melody/ui/desktop/shell.dart";
import "package:melody/ui/mobile/controls.dart" show TrackRow;
import "package:melody/ui/mobile/player.dart";
import "package:melody/ui/mobile/shell.dart";
import "package:melody/ui/shared/dialogs.dart";
import "package:melody/ui/shared/actions.dart"
    show playlistActions, queueDropSlot;
import "package:melody/ui/shared/theme.dart";
import "package:melody/ui/startup.dart";
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
  FakeWorkerTransport? transport,
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
  final worker = WorkerClient(transport ?? FakeWorkerTransport());
  final thumbnails = ThumbnailCache(paths.artworkCache);
  final downloads = await DownloadCoordinator.open(
    manager,
    store,
    store.settings,
    worker,
    thumbnails: thumbnails,
    stagingDirectory: paths.downloadStaging,
    receiptDirectory: paths.downloadReceipts,
  );
  final catalog = MusicCatalog(worker);
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
    loudness: LoudnessNormalizer(
      manager,
      paths.loudnessCache,
      (path, {cancel}) async =>
          throw const LoudnessUnmeasurable("Not measured in screen tests"),
      enabled: true,
      targetLufs: -14,
    ),
    availableTrackIds: ids.toSet(),
  );
  return MelodyApp(services, mobile: mobile);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(_loadFonts);

  setUp(() async {
    root = await createTestDirectory("melody-screens");
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
    // The first frame starts page transitions; the second finishes them.
    await tester.pump();
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
    FakeWorkerTransport? transport,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = (await tester.runAsync(
      () => _app(root, mobile: mobile, transport: transport),
    ))!;
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

  test("Reset everything deletes library audio, not originals", () async {
    final app = await _app(root, mobile: false);
    addTearDown(app.close);
    final manager = app.services.manager;
    final downloaded = manager.trackPath(manager.listTracks().first.id);
    final original = p.join(root.path, "Original.mp3");
    await File("test/fixtures/artwork/cover.mp3").copy(original);
    await File(original).writeAsBytes([9], mode: FileMode.append);
    final imported = manager.trackPath(
      await app.services.library.importLocalFile(original),
    );
    expect(File(downloaded).existsSync(), isTrue);
    expect(File(imported).existsSync(), isTrue);

    await app.settingsDraft.runDataAction("everything");

    expect(File(downloaded).existsSync(), isFalse);
    expect(File(imported).existsSync(), isFalse);
    expect(File(original).existsSync(), isTrue);
  });

  group("a playlist imported from a link", () {
    const link = "https://music.youtube.com/watch?v=x&list=PLroad&si=tracking";
    const stored = "https://music.youtube.com/playlist?list=PLroad";

    Map<String, Object?> song(String id, String title) => {
      "videoId": id,
      "title": title,
      "artists": [
        {"name": "Band"},
      ],
    };

    late FakeWorkerTransport transport;
    late MelodyApp app;

    /// Runs one import, or update, through to its end.
    Future<void> imported() async {
      await app.playlists.importFromUrl(link);
      expect(app.playlists.importing, isFalse);
    }

    setUp(() async {
      transport = FakeWorkerTransport()
        ..ytMusicResults["get_playlist"] = {
          "title": "Road trip",
          "tracks": [song("roadsong001", "One")],
        };
      app = await _app(root, mobile: false, transport: transport);
      addTearDown(app.close);
    });

    Playlist road() => app.services.manager.findPlaylistBySource(stored)!;

    test("keeps its link, and importing it again updates it", () async {
      await imported();
      final playlist = road();
      expect(playlist.name, "Road trip");
      expect(playlist.trackIds, hasLength(1));
      final before = app.services.manager.counts().$2;

      // The link gained a song; the fake's identical bytes need a new name.
      transport
        ..audioFixture = "test/fixtures/artwork/cover_v24.mp3"
        ..downloadedName = "Two.mp3"
        ..ytMusicResults["get_playlist"] = {
          "title": "Road trip",
          "tracks": [song("roadsong001", "One"), song("roadsong002", "Two")],
        };
      await imported();

      expect(app.services.manager.counts().$2, before);
      expect(road().id, playlist.id);
      expect(road().trackIds, hasLength(2));
      expect(road().trackIds.first, playlist.trackIds.first);
    });

    test("an update keeps a name and tracks given here", () async {
      await imported();
      final playlist = road();
      app.services.manager.renamePlaylist(playlist.id, "My road trip");
      final mine = app.services.manager.listTracks().last.id;
      app.services.manager.addToPlaylist(playlist.id, mine);

      await app.playlists.updateFromSource(road());

      expect(road().name, "My road trip");
      expect(road().trackIds, hasLength(2));
      expect(road().trackIds.last, mine);
    });

    test("an update tries again what failed", () async {
      transport.audioFixture = "missing-file.mp3";
      await imported();
      expect(road().trackIds, isEmpty);

      transport.audioFixture = "test/fixtures/artwork/cover_v24.mp3";
      await app.playlists.updateFromSource(road());
      expect(road().trackIds, hasLength(1));
    });

    test("reports its progress and can be stopped", () async {
      transport.downloadGate = Completer();
      final import = app.playlists.importFromUrl(link);
      while (app.playlists.importProgress(
            app.services.manager.findPlaylistBySource(stored)?.id ?? "",
          ) ==
          null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final progress = app.playlists.importProgress(road().id)!;
      expect(progress.done, 0);
      expect(progress.total, 1);

      app.playlists.cancelImport(road().id);
      transport.downloadGate!.complete();
      await import;
      expect(app.playlists.importing, isFalse);
      expect(app.playlists.importProgress(road().id), isNull);
    });

    test("a plain playlist has no link to update from", () async {
      final id = app.services.manager.createPlaylist("Mine");
      expect(app.services.manager.getPlaylist(id).source, isEmpty);
    });
  });

  test(
    "a playlist import finishes when a download leaves the history unseen",
    () async {
      final transport = FakeWorkerTransport()
        ..downloadedName = "Road song.mp3"
        ..ytMusicResults["get_playlist"] = {
          "title": "Road trip",
          "tracks": [
            {
              "videoId": "roadsong001",
              "title": "Road song",
              "artists": [
                {"name": "Band"},
              ],
            },
          ],
        };
      final app = await _app(root, mobile: false, transport: transport);
      addTearDown(app.close);
      final downloads = app.services.downloads;
      final publish = downloads.onRecord!;
      downloads.onRecord = (record) {
        // Clear finished, pressed before the importer looked at the record.
        if (record.status.isFinished) downloads.clearFinished();
        publish(record);
      };

      await app.playlists
          .importFromUrl("https://music.youtube.com/playlist?list=PLroad")
          .timeout(const Duration(seconds: 20));

      expect(app.playlists.importing, isFalse);
      final playlist = app.services.manager.listPlaylists().singleWhere(
        (item) => item.name == "Road trip",
      );
      final track = app.services.manager.findTrackBySource(
        "https://music.youtube.com/watch?v=roadsong001",
      );
      expect(track, isNotNull);
      expect(playlist.trackIds, [track!.id]);
    },
  );

  test("leaving Settings unsaved drops an appearance preview", () async {
    final app = await _app(root, mobile: false);
    addTearDown(app.close);
    final saved = (app.settings.theme, app.settings.accentColor);
    expect(saved.$2, isNot("rose"));

    app.openPanel(AppPanel.settings);
    app.settingsDraft.previewAppearance(theme: "dark", accent: "rose");
    expect(app.appearance.value, ("dark", "rose"));
    app.closePanel();
    expect(app.appearance.value, saved);

    app.openPanel(AppPanel.settings);
    app.settingsDraft.reset();
    app.settingsDraft.previewAppearance(accent: "rose");
    await app.settingsDraft.save();
    app.openPanel(AppPanel.downloads);
    expect(app.appearance.value, (saved.$1, "rose"));
    expect(app.services.store.settings.accentColor, "rose");
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
    app.playlists.openPlaylist(favoritesPlaylistId);
    await shoot(tester, "desktop_favorites");
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

  testWidgets("Stop is offered only while something is loaded", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    IconButton stop() => tester.widget(
      find.ancestor(
        of: find.byIcon(Icons.stop_rounded),
        matching: find.byType(IconButton),
      ),
    );
    final queue = List.of(app.playback.queue.items);
    expect(queue, isNotEmpty);
    expect(stop().onPressed, isNull);

    app.playback.toggle();
    await tester.pump();
    expect(stop().onPressed, isNotNull);

    app.playback.stop();
    await tester.pump();
    expect(stop().onPressed, isNull);
    expect(app.playback.queue.items, queue);
    // The real engine has no decoder here; let its calls time out.
    await tester.pump(const Duration(seconds: 13));
  });

  test("shuffling the queue offers to put it back", () async {
    final app = await _app(root, mobile: false);
    addTearDown(app.close);
    final messages = <AppMessage>[];
    final subscription = app.messages.listen(messages.add);
    addTearDown(subscription.cancel);
    final before = List.of(app.playback.queue.items);
    final current = app.playback.currentTrackId;

    app.shuffleQueue();
    await Future<void>.delayed(Duration.zero);

    expect(app.playback.currentTrackId, current);
    expect(app.playback.queue.currentIndex, 0);
    final (label, undo) = messages.single.action!;
    expect(label, "Undo");
    undo();
    expect(app.playback.queue.items, before);
    expect(app.playback.currentTrackId, current);
  });

  testWidgets("a track can go to a playlist picked or made from its menu", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    final track = app.services.manager.listTracks().first;
    final existing = app.services.manager.listPlaylists().single;
    Future<void> pick() async {
      showPlaylistPicker(
        tester.element(find.byType(DesktopShell)),
        app,
        title: "Add to playlist",
        onChosen: (id) => app.playlists.addTrack(id, track.id),
      );
      await tester.pumpAndSettle();
    }

    await pick();
    await tester.tap(find.text("New playlist…"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, "Fresh");
    await tester.tap(find.text("Create"));
    await tester.pumpAndSettle();
    final fresh = app.services.manager.listPlaylists().firstWhere(
      (playlist) => playlist.name == "Fresh",
    );
    expect(fresh.trackIds, [track.id]);
    expect(app.playlists.selectedPlaylistId, isNull);

    await pick();
    expect(find.text(existing.name), findsWidgets);
    await tester.tap(find.text("Fresh").last);
    await tester.pumpAndSettle();
    expect(app.services.manager.getPlaylist(fresh.id).trackIds, [track.id]);
  });

  testWidgets("Select all picks only the tracks a search shows", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    final playlist = app.services.manager.getPlaylist(
      app.playlists.create("Empty", open: false),
    );
    showBulkAddTracksDialog(
      tester.element(find.byType(DesktopShell)),
      app,
      playlist,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, "weightless");
    await tester.pumpAndSettle();
    await tester.tap(find.text("Select all 1 shown"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Add selected"));
    await tester.pumpAndSettle();
    final added = app.services.manager.getPlaylist(playlist.id).trackIds;
    expect(added, hasLength(1));
    expect(app.services.manager.getTrack(added.single).title, "Weightless");
  });

  /// Adds [count] tracks named "Extra <n>" to the library.
  Future<List<String>> addTracks(
    WidgetTester tester,
    MelodyApp app,
    int count,
  ) async => (await tester.runAsync(() async {
    final manager = app.services.manager;
    final ids = <String>[];
    for (var index = 0; index < count; index++) {
      final path = p.join(manager.musicFolder, "Extra $index.mp3");
      await File(path).writeAsString("Extra $index");
      ids.add(await manager.addTrack(path, title: "Extra $index"));
    }
    app.touchLibrary();
    return ids;
  }))!;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets("a long library scrolls instead of paging", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    await addTracks(tester, app, 120);
    app.navigate(2);
    await settle(tester);
    expect(find.text("Next"), findsNothing);
    expect(find.byType(LibraryTrackRow).evaluate().length, lessThan(40));
    // The oldest tracks are last, in view after a long scroll.
    await tester.dragUntilVisible(
      find.text("Extra 0"),
      find.byType(ListView).last,
      const Offset(0, -2000),
    );
    expect(find.text("Extra 0"), findsOneWidget);
  });

  testWidgets("the library can pick several tracks to act on", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    app.navigate(2);
    await settle(tester);
    final library = app.library;
    await tester.tap(find.byTooltip("Select tracks"));
    await settle(tester);
    expect(library.selecting, isTrue);
    await tester.tap(find.text("Clair de Lune"));
    await tester.tap(find.text("Midnight City"));
    await settle(tester);
    expect(find.text("2 selected"), findsOneWidget);
    await tester.tap(find.text("Clair de Lune"));
    await settle(tester);
    expect(find.text("1 selected"), findsOneWidget);

    await tester.tap(find.text("Select all"));
    await settle(tester);
    expect(find.text("3 selected"), findsOneWidget);
    final queued = app.playback.queue.items.length;
    await tester.tap(find.byTooltip("Add to queue"));
    await settle(tester);
    expect(app.playback.queue.items, hasLength(queued + 3));
    expect(library.selecting, isFalse);
    await tester.pump(const Duration(seconds: 13));
  });

  test("deleting the selected tracks removes them and their files", () async {
    final app = await _app(root, mobile: false);
    addTearDown(app.close);
    final manager = app.services.manager;
    final ids = List.of(app.library.visibleIds());
    final paths = [for (final id in ids.take(2)) manager.trackPath(id)];
    app.library
      ..startSelecting(ids[0])
      ..toggleSelected(ids[1]);

    await app.library.deleteSelected();

    expect(manager.counts().$1, ids.length - 2);
    expect(manager.hasTrack(ids[2]), isTrue);
    for (final path in paths) {
      expect(File(path).existsSync(), isFalse);
    }
    expect(app.library.selecting, isFalse);
    expect(app.library.selected, isEmpty);
  });

  testWidgets("a mobile row starts selecting on a long press", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(420, 900),
    );
    app.navigate(2);
    await settle(tester);
    await tester.longPress(find.text("Clair de Lune"));
    await settle(tester);
    expect(app.library.selecting, isTrue);
    expect(find.text("1 selected"), findsOneWidget);
    await tester.tap(find.text("Midnight City"));
    await settle(tester);
    expect(find.text("2 selected"), findsOneWidget);
  });

  testWidgets("a track's title and artist can be edited", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    final track = app.services.manager.listTracks().first;
    showEditTrackDialog(tester.element(find.byType(DesktopShell)), app, track);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, "Title"), "");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    // An empty title is refused, and the dialog stays open to say so.
    expect(find.text("Song title cannot be empty"), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, "Title"), "New name");
    await tester.enterText(find.widgetWithText(TextField, "Artist"), "Someone");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(app.services.manager.getTrack(track.id).title, "New name");
    expect(app.services.library.details(track.id).uploader, "Someone");
  });

  testWidgets("the queue opens at the current track and finds rows", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    final ids = await addTracks(tester, app, 200);
    final queue = app.playback.queue
      ..items = ids
      ..currentIndex = 150;
    app.openPanel(AppPanel.queue);
    await settle(tester);
    await tester.pump();
    expect(find.widgetWithText(TrackListRow, "Extra 150"), findsOneWidget);
    expect(find.widgetWithText(TrackListRow, "Extra 0"), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, "Find in the queue"),
      "Extra 7",
    );
    await settle(tester);
    expect(find.widgetWithText(TrackListRow, "Extra 7"), findsOneWidget);
    expect(find.widgetWithText(TrackListRow, "Extra 150"), findsNothing);
    // A found row still plays from its real place in the queue.
    final row = tester.widget<TrackListRow>(
      find.widgetWithText(TrackListRow, "Extra 7"),
    );
    row.onPlay!();
    expect(queue.currentIndex, 7);
    await tester.pump(const Duration(seconds: 13));
  });

  testWidgets("a playlist finds rows and keeps their real places", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(420, 900),
    );
    final ids = await addTracks(tester, app, 60);
    final playlist = app.services.manager.createPlaylist("Long");
    app.services.manager.addTracksToPlaylist(playlist, ids);
    app.playlists.openPlaylist(playlist);
    await settle(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, "Find in this playlist"),
      "Extra 42",
    );
    await settle(tester);
    expect(find.widgetWithText(TrackRow, "Extra 42"), findsOneWidget);
    expect(find.widgetWithText(TrackRow, "Extra 0"), findsNothing);
    await tester.tap(find.widgetWithText(TrackRow, "Extra 42"));
    await settle(tester);
    expect(app.playback.queue.items, ids);
    expect(app.playback.queue.currentIndex, 42);
    await tester.pump(const Duration(seconds: 13));
  });

  testWidgets("a library row plays the list from there", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    app.navigate(2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final ids = app.library.visibleIds();
    app.playback.queue.replace([ids.first]);

    app.library.playFrom(1);

    expect(app.playback.queue.items, ids);
    expect(app.playback.currentTrackId, ids[1]);
    await tester.pump(const Duration(seconds: 13));
  });

  testWidgets("Reset everything says it deletes the library's audio", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
    );
    app.openPanel(AppPanel.settings);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.textContaining(
        "delete every downloaded and imported audio file",
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining("Audio files", skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets("scrolling lyrics by hand stops following playback", (
    tester,
  ) async {
    final transport = FakeWorkerTransport()
      ..ytMusicResults["get_lyrics"] = {
        "lyrics": [
          for (var line = 0; line < 60; line++)
            {
              "text": line == 1 ? "" : "Line $line",
              "start_time": line * 2000,
              "end_time": line * 2000 + 2000,
            },
        ],
        "source": "Source: Test",
      };
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1540, 960),
      transport: transport,
    );
    app.openPanel(AppPanel.lyrics);
    await tester.pump();
    // Saved lyrics are read from disk, which needs real async time.
    for (var attempt = 0; attempt < 50; attempt++) {
      if (find.text("Line 0").evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // A blank timed line is an instrumental break.
    expect(find.text("♪"), findsOneWidget);
    expect(find.text("Back to current line"), findsNothing);

    // Playback is at 64 s, so line 32 is the one in view.
    await tester.drag(find.text("Line 32"), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text("Back to current line"), findsOneWidget);

    await tester.tap(find.text("Back to current line"));
    await tester.pumpAndSettle();
    expect(find.text("Back to current line"), findsNothing);
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
      // The position's update repaints its own layer, not the window.
      var painted = 0;
      debugProfilePaintsEnabled = true;
      debugOnProfilePaint = (_) => painted++;
      app.playback.onPosition(65000);
      await tester.pump();
      debugProfilePaintsEnabled = false;
      debugOnProfilePaint = null;
      expect(painted, lessThan(60));
      expect(find.text("1:05"), findsWidgets);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  for (final mobile in [false, true]) {
    final layout = mobile ? "mobile" : "desktop";
    testWidgets("$layout search offers recent searches", (tester) async {
      final app = await pumpShell(
        tester,
        mobile: mobile,
        size: mobile ? const Size(390, 844) : const Size(1540, 960),
      );
      final search = app.search;
      for (final query in ["old tune", "lofi beats", "night drive"]) {
        app.services.store.addSearch(query);
      }
      app.navigate(1);
      await tester.pumpAndSettle();
      expect(find.text("Recent searches"), findsOneWidget);
      await shoot(tester, "${layout}_recent_searches");

      await tester.tap(
        find.byTooltip("Remove from recent searches").last, // "old tune"
      );
      await tester.pumpAndSettle();
      expect(find.text("old tune"), findsNothing);
      expect(search.recentSearches, ["night drive", "lofi beats"]);

      await tester.tap(find.text("lofi beats"));
      await tester.pump();
      for (var attempt = 0; attempt < 50 && search.busy; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(search.queryText, "lofi beats");
      expect(find.text("Recent searches"), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        "lofi beats",
      );
      expect(search.recentSearches.first, "lofi beats");

      await tester.tap(find.byTooltip("Clear search"));
      await tester.pumpAndSettle();
      expect(search.queryText, isEmpty);
      expect(search.results, isEmpty);
      expect(find.text("Recent searches"), findsOneWidget);

      await tester.tap(find.text("Clear all"));
      await tester.pumpAndSettle();
      expect(search.recentSearches, isEmpty);
      expect(find.text("Recent searches"), findsNothing);
    });
  }

  testWidgets("mobile player follows swipes", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(390, 844),
    );
    final playback = app.playback;
    final first = playback.currentTrackId;
    final mini = find.byTooltip("Open Now Playing");
    await tester.fling(mini, const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(playback.currentTrackId, isNot(first));

    await tester.fling(mini, const Offset(0, -200), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(NowPlaying), findsOneWidget);

    await tester.fling(find.text("NOW PLAYING"), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(NowPlaying), findsNothing);
    // The skipped-to track never loads here; let its load watchdog lapse.
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
  });

  testWidgets("desktop shortcuts control playback but leave typing alone", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1440, 900),
    );
    final playback = app.playback;
    playback.setVolume(50);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(playback.volume, 55);

    // In a text field, Ctrl+→ moves the caret instead of skipping.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
    );
    final track = playback.currentTrackId;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(playback.currentTrackId, track);
    expect(find.text("Keyboard shortcuts"), findsOneWidget);
    expect(find.text("Volume up"), findsOneWidget);
    await tester.tap(find.text("Close"));
    await tester.pumpAndSettle();
  });

  testWidgets("desktop sleep timer starts and turns off from its menu", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1440, 900),
    );
    await tester.tap(find.byTooltip("Sleep timer"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("30 minutes"));
    await tester.pumpAndSettle();
    expect(app.sleepTimer.active, isTrue);
    expect(find.byTooltip("Sleep timer: 30 min left"), findsOneWidget);

    await tester.tap(find.byTooltip("Sleep timer: 30 min left"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Turn off"));
    await tester.pumpAndSettle();
    expect(app.sleepTimer.active, isFalse);
  });

  testWidgets("queue edits offer an undo", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: false,
      size: const Size(1440, 900),
    );
    final messages = <AppMessage>[];
    final subscription = app.messages.listen(messages.add);
    addTearDown(subscription.cancel);
    final queue = app.playback.queue;
    final before = List.of(queue.items);
    expect(before.length, greaterThan(2));

    app.clearQueue();
    await tester.pump();
    expect(queue.items, [app.playback.currentTrackId]);
    expect(
      messages.last.text,
      "Cleared ${before.length - 1} tracks from the queue.",
    );
    messages.last.action!.$2();
    expect(queue.items, before);

    final removed = queue.currentIndex == 0 ? 1 : 0;
    app.removeFromQueue(removed);
    await tester.pump();
    expect(queue.items, hasLength(before.length - 1));
    messages.last.action!.$2();
    expect(queue.items, before);
  });

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

  testWidgets("mobile playlist tracks reorder by dragging", (tester) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(390, 844),
    );
    final playlist = app.services.manager.listPlaylists().single;
    final [first, second, third] = playlist.trackIds;
    app.navigate(3);
    app.playlists.openPlaylist(playlist.id);
    await tester.pumpAndSettle();

    final handles = find.byTooltip("Drag to reorder");
    expect(handles, findsNWidgets(3));
    final gesture = await tester.startGesture(tester.getCenter(handles.first));
    await tester.pump();
    // Past the middle of the last row: the drop slot after it.
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(const Offset(0, 16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(app.services.manager.getPlaylist(playlist.id).trackIds, [
      second,
      third,
      first,
    ]);
  });

  testWidgets("Favorites lists favorites and can only be reordered", (
    tester,
  ) async {
    final app = await pumpShell(
      tester,
      mobile: true,
      size: const Size(390, 844),
    );
    final [first, second, third] = app.services.manager
        .listPlaylists()
        .single
        .trackIds;
    app.navigate(3);
    await tester.pumpAndSettle();
    // Listed first, before the user's playlists.
    expect(find.text("Favorites"), findsOneWidget);
    await tester.tap(find.text("Favorites"));
    await tester.pumpAndSettle();

    await shoot(tester, "mobile_favorites");
    expect(app.playlists.selectedPlaylistId, favoritesPlaylistId);
    expect(app.playlists.playlist(favoritesPlaylistId).trackIds, [
      third,
      first,
    ]);
    final handles = find.byTooltip("Drag to reorder");
    expect(handles, findsNWidgets(2));
    final gesture = await tester.startGesture(tester.getCenter(handles.first));
    await tester.pump();
    // Past the middle of the last row: the drop slot after it.
    for (var step = 0; step < 8; step++) {
      await gesture.moveBy(const Offset(0, 16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(app.playlists.playlist(favoritesPlaylistId).trackIds, [
      first,
      third,
    ]);
    expect(find.byIcon(Icons.favorite_rounded), findsNWidgets(2));
    expect(
      playlistActions(
        tester.element(find.byType(Scaffold).first),
        app,
        app.playlists.playlist(favoritesPlaylistId),
      ).map((action) => action.label),
      ["Copy links", "Export playlist"],
    );
    expect(() => app.playlists.delete(favoritesPlaylistId), throwsStateError);
    expect(
      () => app.playlists.rename(favoritesPlaylistId, "Mine"),
      throwsStateError,
    );
    expect(
      () => app.playlists.addTrack(favoritesPlaylistId, second),
      throwsStateError,
    );

    await app.toggleFavorite(first);
    await tester.pumpAndSettle();
    expect(app.playlists.playlist(favoritesPlaylistId).trackIds, [third]);
    expect(find.byTooltip("Drag to reorder"), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  test("queue drops land between the visible rows", () {
    // Rows 2 and 3 of the queue are hidden, e.g. deleted tracks.
    const rows = [0, 1, 4, 5];
    expect(queueDropSlot(rows, 0, 2), 5);
    expect(queueDropSlot(rows, 0, 3), 6);
    expect(queueDropSlot(rows, 3, 2), 4);
    expect(queueDropSlot(rows, 3, 0), 0);
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

  testWidgets("startup screens render on both layouts", (tester) async {
    final stage = ValueNotifier("Opening your library");
    addTearDown(stage.dispose);
    for (final (name, size, theme) in [
      ("desktop", const Size(1540, 960), "light"),
      ("mobile", const Size(390, 844), "dark"),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget frame(Widget home) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme("violet", Brightness.light),
        darkTheme: buildTheme("violet", Brightness.dark),
        themeMode: themeModeFor(theme),
        home: home,
      );
      await tester.pumpWidget(frame(LoadingView(stage: stage)));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text("Opening your library"), findsOneWidget);
      await shoot(tester, "${name}_loading");

      var revealed = false;
      var finished = false;
      await tester.pumpWidget(
        frame(
          LoadingView(
            stage: stage,
            finishing: true,
            onReveal: () => revealed = true,
            onFinished: () => finished = true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(revealed, isFalse);
      await shoot(tester, "${name}_loading_exit");
      await tester.pump(const Duration(milliseconds: 600));
      expect((revealed, finished), (true, true));
      await tester.pumpWidget(
        frame(const StartupError(error: "FileSystemException: Access denied")),
      );
      expect(find.textContaining("Access denied"), findsOneWidget);
      await shoot(tester, "${name}_startup_error");
    }
    // Stop the repeating animations before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
