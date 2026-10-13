@Tags(["network"])
library;

import "../support/temp.dart";
import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/application/models.dart";
import "package:melody/application/catalog.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/core/artwork.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/worker/transport.dart";
import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

/// End-to-end checks against the real Python worker and YouTube Music.
///
///   MELODY_WORKER_PYTHON=../worker/.venv/Scripts/python.exe \
///   MELODY_FFMPEG_DIR=path/to/ffmpeg-folder \
///   flutter test test/integration --tags network
void main() {
  final python = Platform.environment["MELODY_WORKER_PYTHON"];
  final ffmpeg = Platform.environment["MELODY_FFMPEG_DIR"];
  final skip = python == null
      ? "Set MELODY_WORKER_PYTHON to run worker integration tests"
      : null;
  late Directory root;
  late WorkerClient worker;

  setUpAll(() async {
    if (python == null) return;
    root = await createTestDirectory("melody-worker");
    worker = WorkerClient(
      await ProcessTransport.start(
        python: python,
        workerSource: p.normalize(p.absolute("..", "worker", "src")),
        runtimes: WorkerRuntimes({
          ytDlpPackage: p.join(root.path, "runtime", "yt-dlp"),
          ytMusicPackage: p.join(root.path, "runtime", "ytmusicapi"),
        }),
      ),
    );
  });

  tearDownAll(() async {
    if (python == null) return;
    await worker.close();
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the databases; the OS cleans temp.
    }
  });

  test("the worker selects yt-dlp and ytmusicapi runtimes", () async {
    final status = await worker.ready.timeout(const Duration(seconds: 60));
    expect(status.ytDlp.available, isTrue);
    expect(status.ytDlp.activeVersion, startsWith("2026."));
    expect(status.ytMusic.available, isTrue);
    expect(status.ytMusic.activeVersion, startsWith("1."));
  }, skip: skip);

  test(
    "lyrics come from YouTube Music",
    () async {
      final catalog = MusicCatalog(worker, () => {});
      final song = (await catalog.search(
        "Daft Punk Get Lucky",
        limit: 1,
      )).first;
      final lyrics = await catalog.lyrics(song.id);
      expect(lyrics, isNotNull);
      expect(lyrics!.lines, isNotEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    "search results map to YouTube Music tracks",
    () async {
      final catalog = MusicCatalog(worker, () => {});
      final results = await catalog.search("Debussy Clair de Lune", limit: 3);
      expect(results, isNotEmpty);
      expect(
        results.first.url,
        startsWith("https://music.youtube.com/watch?v="),
      );
      expect(results.first.title, isNotEmpty);
      expect(results.first.thumbnail, startsWith("https://"));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    "a real download is converted, verified, and registered",
    () async {
      final music = p.join(root.path, "Music");
      final store = ApplicationStore.open(
        p.join(root.path, "state.db"),
        defaultDownloadDirectory: music,
      );
      final manager = MusicManager.open(p.join(root.path, "library.db"), music);
      final thumbnails = ThumbnailCache(p.join(root.path, "cache", "artwork"));
      final catalog = MusicCatalog(worker, () => {});
      final result = (await catalog.search(
        "Erik Satie Gymnopedie 1",
        limit: 1,
      )).first;
      final coordinator = await DownloadCoordinator.open(
        manager,
        store,
        store.settings,
        worker,
        thumbnails: thumbnails,
        sharedOptions: sharedYtDlpOptions(
          ffmpegLocation: ffmpeg,
          cacheDirectory: p.join(root.path, "cache", "yt-dlp"),
        ),
        stagingDirectory: p.join(root.path, "downloads", "staging"),
        receiptDirectory: p.join(root.path, "downloads", "receipts"),
      );
      final finished = Completer<DownloadRecord>();
      coordinator.onRecord = (record) {
        if (record.status.isFinished && !finished.isCompleted) {
          finished.complete(record);
        }
      };
      expect((await coordinator.request(result)).started, isTrue);
      final record = await finished.future.timeout(const Duration(minutes: 5));
      expect(record.status, DownloadStatus.completed, reason: record.error);
      final track = manager.getTrack(record.trackIds.single);
      final path = manager.trackPath(track.id);
      expect(p.extension(path), ".mp3");
      expect(await readEmbeddedArtwork(path), isNotEmpty);
      expect(thumbnails.cachedPath(result.thumbnail), isNotNull);
      expect(await manager.checkTrackIntegrity(track.id), isNull);
      // yt-dlp's intermediate files went with the staging folder.
      expect([
        for (final entity in Directory(music).listSync())
          if (p.basename(entity.path).startsWith(".")) entity.path,
      ], isEmpty);
      manager.close();
      store.close();
    },
    skip:
        skip ??
        (ffmpeg == null
            ? "Set MELODY_FFMPEG_DIR to test real downloads"
            : null),
    timeout: const Timeout(Duration(minutes: 6)),
  );

  for (final format in ["mp3", "m4a"]) {
    test(
      "a real $format download embeds its lyrics",
      () async {
        final folder = p.join(root.path, "lyrics-$format");
        final music = p.join(folder, "Music");
        final store = ApplicationStore.open(
          p.join(folder, "state.db"),
          defaultDownloadDirectory: music,
        );
        store.saveSettings(store.settings..audioFormat = format);
        final manager = MusicManager.open(p.join(folder, "library.db"), music);
        final catalog = MusicCatalog(worker, () => {});
        final result = (await catalog.search(
          "Daft Punk Get Lucky",
          limit: 1,
        )).first;
        final coordinator = await DownloadCoordinator.open(
          manager,
          store,
          store.settings,
          worker,
          lyrics: LyricsLibrary(p.join(folder, "lyrics"), catalog.lyrics),
          sharedOptions: sharedYtDlpOptions(
            ffmpegLocation: ffmpeg,
            cacheDirectory: p.join(root.path, "cache", "yt-dlp"),
          ),
          stagingDirectory: p.join(root.path, "downloads", "staging"),
          receiptDirectory: p.join(root.path, "downloads", "receipts"),
        );
        final finished = Completer<DownloadRecord>();
        coordinator.onRecord = (record) {
          if (record.status.isFinished && !finished.isCompleted) {
            finished.complete(record);
          }
        };
        await coordinator.request(result);
        final record = await finished.future.timeout(
          const Duration(minutes: 5),
        );
        expect(record.status, DownloadStatus.completed, reason: record.error);
        final id = record.trackIds.single;
        final path = manager.trackPath(id);
        expect(p.extension(path), ".$format");
        final embedded = Lyrics.parse(await readEmbeddedLyrics(path));
        expect(embedded.synced, isTrue);
        expect(embedded.lines.length, greaterThan(10));
        expect(await readEmbeddedArtwork(path), isNotEmpty);
        expect(await manager.checkTrackIntegrity(id), isNull);
        manager.close();
        store.close();
      },
      skip:
          skip ??
          (ffmpeg == null
              ? "Set MELODY_FFMPEG_DIR to test real downloads"
              : null),
      timeout: const Timeout(Duration(minutes: 6)),
    );
  }
}
