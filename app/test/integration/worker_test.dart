@Tags(["network"])
library;

import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/models.dart";
import "package:melody/application/providers.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/core/artwork.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/media.dart";
import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

/// End-to-end checks against the real Python worker and YouTube Music.
///
///   MELODY_WORKER_PYTHON=../worker/.venv/Scripts/python.exe \
///   MELODY_FFMPEG_DIR=<folder with ffmpeg and ffprobe> \
///   flutter test test/integration --tags network
void main() {
  final python = Platform.environment["MELODY_WORKER_PYTHON"];
  final ffmpeg = Platform.environment["MELODY_FFMPEG_DIR"];
  final skip = python == null ? "Set MELODY_WORKER_PYTHON to run worker integration tests" : null;
  late Directory root;
  late WorkerClient worker;

  setUpAll(() async {
    if (python == null) return;
    root = await Directory.systemTemp.createTemp("melody-worker");
    worker = WorkerClient(
      await ProcessTransport.start(
        python: python,
        workerSource: p.normalize(p.absolute("..", "worker", "src")),
        runtimeDirectory: p.join(root.path, "yt-dlp-runtime"),
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

  test("the worker selects a yt-dlp runtime", () async {
    final status = await worker.ready.timeout(const Duration(seconds: 60));
    expect(status["available"], isTrue);
    expect("${status["active_version"]}", startsWith("2026."));
  }, skip: skip);

  test("search results map to YouTube Music tracks", () async {
    final providers = ProviderRegistry(worker, {});
    final results = await providers.search(youtubeProviderId, "Debussy Clair de Lune", limit: 3);
    expect(results, isNotEmpty);
    expect(results.first.url, startsWith("https://music.youtube.com/watch?v="));
    expect(results.first.title, isNotEmpty);
    expect(results.first.thumbnail, startsWith("https://"));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test("a real download is converted, verified, and registered", () async {
    final music = p.join(root.path, "Music");
    final store = ApplicationStore.open(p.join(root.path, "state.db"), defaultDownloadDirectory: music);
    final manager = MusicManager.open(p.join(root.path, "library.db"), music);
    final thumbnails = ThumbnailCache(p.join(root.path, "thumbnails"));
    final providers = ProviderRegistry(worker, {});
    final result = (await providers.search(youtubeProviderId, "Erik Satie Gymnopedie 1", limit: 1)).first;
    final coordinator = await DownloadCoordinator.open(
      manager,
      store,
      store.settings,
      worker,
      thumbnails: thumbnails,
      sharedOptions: sharedYtDlpOptions(store.settings, ffmpegLocation: ffmpeg),
    );
    final finished = Completer<DownloadRecord>();
    coordinator.onRecord = (record) {
      if (const {"completed", "failed", "cancelled"}.contains(record.status) && !finished.isCompleted) {
        finished.complete(record);
      }
    };
    final task = await coordinator.request(result);
    expect(task, isNotNull);
    final record = await finished.future.timeout(const Duration(minutes: 5));
    expect(record.status, "completed", reason: record.error);
    final track = manager.getTrack(record.trackIds.single);
    final path = manager.trackPath(track.id);
    expect(p.extension(path), ".mp3");
    expect(await readEmbeddedArtwork(path), isNotEmpty);
    expect(thumbnails.cachedPath(result.thumbnail), isNotNull);
    expect(await manager.checkTrackIntegrity(track.id), isNull);
    manager.close();
    store.close();
  }, skip: skip ?? (ffmpeg == null ? "Set MELODY_FFMPEG_DIR to test real downloads" : null),
      timeout: const Timeout(Duration(minutes: 6)));
}
