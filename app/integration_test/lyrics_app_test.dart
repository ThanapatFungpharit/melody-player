/// Drives the real desktop app (real worker, real YouTube Music) through the
/// lyrics features: lyrics while playing, lyrics saved inside the downloaded
/// file (and nowhere beside it), offline lyrics, and lyrics for an imported
/// local file.
///
///   MELODY_DATA_DIR=DATA_FOLDER \
///   MELODY_WORKER_PYTHON=../worker/.venv/Scripts/python.exe \
///   MELODY_WORKER_SOURCE=REPO/worker/src \
///   MELODY_FFMPEG_DIR=path/to/ffmpeg-folder \
///   MELODY_SCREENSHOT_DIR=PNG_FOLDER (optional) \
///   flutter test integration_test -d windows
@Tags(["network"])
library;

import "dart:io";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter_test/flutter_test.dart";
import "package:integration_test/integration_test.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/core/artwork.dart";
import "package:melody/main.dart" as melody;
import "package:melody/ui/app_state.dart";
import "package:melody/ui/desktop/shell.dart";
import "package:melody/ui/shared/lyrics_view.dart";
import "package:path/path.dart" as p;

final _environment = Platform.environment;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(minutes: 2),
    String reason = "",
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail("Timed out waiting${reason.isEmpty ? "" : " for $reason"}");
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    final directory = _environment["MELODY_SCREENSHOT_DIR"];
    if (directory == null || directory.isEmpty) return;
    await tester.pump(const Duration(milliseconds: 400));
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      p.join(directory, "$name.png"),
    ).writeAsBytes(png!.buffer.asUint8List());
  }

  /// Synced lyric lines are tappable rows inside the lyrics view.
  int lyricRows() => find
      .descendant(of: find.byType(LyricsView), matching: find.byType(InkWell))
      .evaluate()
      .length;

  String lyricsFooter() {
    final texts = find
        .descendant(of: find.byType(LyricsView), matching: find.byType(Text))
        .evaluate()
        .map((element) => (element.widget as Text).data ?? "")
        .toList();
    return texts.isEmpty ? "" : texts.last;
  }

  Future<void> reopenLyrics(WidgetTester tester, MelodyApp app) async {
    app.closePanel();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip("Lyrics (Ctrl+Y)"));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets("lyrics work in the running app, online and offline", (
    tester,
  ) async {
    expect(
      _environment["MELODY_DATA_DIR"],
      isNotNull,
      reason: "Never run this against a real library",
    );
    melody.main();
    await waitFor(
      tester,
      () => find.byType(DesktopShell).evaluate().isNotEmpty,
      reason: "the app shell",
    );
    final app = tester.widget<DesktopShell>(find.byType(DesktopShell)).app;
    await app.services.worker.ready;
    if (!app.playback.muted) app.playback.toggleMute();

    // -- Online: search, play (which downloads), and show lyrics. ----------
    app.navigate(1);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, "Daft Punk Get Lucky");
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await waitFor(
      tester,
      () => app.search.results.isNotEmpty && !app.search.busy,
      reason: "search results",
    );
    await shoot(tester, "1_search");
    await tester.tap(find.byTooltip("Play").first);
    await waitFor(
      tester,
      () => app.playback.currentTrackId != null && !app.playback.loading,
      timeout: const Duration(minutes: 5),
      reason: "the downloaded track to play",
    );
    final trackId = app.playback.currentTrackId!;
    final audioPath = app.services.manager.trackPath(trackId);

    await tester.tap(find.byTooltip("Lyrics (Ctrl+Y)"));
    await waitFor(tester, () => lyricRows() > 10, reason: "synced lyrics");
    await shoot(tester, "2_lyrics_playing");

    final embedded = Lyrics.parse(await readEmbeddedLyrics(audioPath));
    expect(embedded.synced, isTrue, reason: "lyrics embedded in the MP3");
    await app.services.lyricsEmbedder!.idle;
    expect(
      File(LyricsLibrary.sidecarPath(audioPath)).existsSync(),
      isFalse,
      reason: "lyrics live inside the MP3, with no .lrc beside it",
    );
    expect(await app.services.manager.checkTrackIntegrity(trackId), isNull);

    // -- Offline: the worker is gone, so YouTube Music cannot be reached. ---
    // Without even Melody's saved copy, the MP3's own tag has the lyrics.
    await app.services.worker.close();
    final saved = Directory(app.services.paths.lyrics);
    await for (final entry in saved.list()) {
      await entry.delete();
    }
    await reopenLyrics(tester, app);
    await waitFor(tester, () => lyricRows() > 10, reason: "offline lyrics");
    expect(lyricsFooter(), isEmpty);
    await shoot(tester, "3_offline_from_tag");

    // -- An imported local file with a .lrc beside it. -----------------------
    final fixture =
        _environment["MELODY_TEST_FIXTURE"] ??
        p.absolute("test/fixtures/artwork/no_cover.mp3");
    final outside = await Directory.systemTemp.createTemp("melody-local");
    final original = p.join(outside.path, "My recording.mp3");
    await File(fixture).copy(original);
    await File(p.join(outside.path, "My recording.lrc")).writeAsString(
      "[ti:My recording]\n[00:00.20]First line I wrote\n"
      "[00:00.60]Second line I wrote\n",
    );
    final localId = await app.services.library.importLocalFile(original);
    app.touchLibrary();
    app.playback.playTracks([localId]);
    await waitFor(
      tester,
      () => app.playback.currentTrackId == localId,
      reason: "the imported track",
    );
    await reopenLyrics(tester, app);
    await waitFor(
      tester,
      () => find.text("Second line I wrote").evaluate().isNotEmpty,
      reason: "the local file's lyrics",
    );
    expect(lyricsFooter(), isEmpty);
    await shoot(tester, "4_local_file_lrc");

    app.playback.stop();
    await outside.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 12)));
}
