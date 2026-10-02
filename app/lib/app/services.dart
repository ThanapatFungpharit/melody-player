import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";

import "package:path/path.dart" as p;

import "../application/downloads.dart";
import "../application/library_service.dart";
import "../application/providers.dart";
import "../application/store.dart";
import "../application/thumbnails.dart";
import "../application/yt_dlp_runtime.dart";
import "../core/library/manager.dart";
import "../platform/paths.dart";
import "../worker/worker_client.dart";

/// Everything loaded before the first view: durable state, the library, and
/// the yt-dlp worker (which selects its runtime in the background).
class AppServices {
  AppServices({
    required this.paths,
    required this.store,
    required this.manager,
    required this.library,
    required this.thumbnails,
    required this.worker,
    required this.providers,
    required this.downloads,
    required this.ytDlp,
    required this.availableTrackIds,
  });

  final AppPaths paths;
  final ApplicationStore store;
  final MusicManager manager;
  final LibraryService library;
  final ThumbnailCache thumbnails;
  final WorkerClient worker;
  ProviderRegistry providers;
  final DownloadCoordinator downloads;
  final YtDlpRuntime ytDlp;

  /// Restored queue entries whose files exist; checked once at startup.
  final Set<String> availableTrackIds;

  /// yt-dlp options derived from the current settings.
  Map<String, Object?> sharedOptions() =>
      sharedYtDlpOptions(store.settings, ffmpegLocation: paths.ffmpegLocation);

  /// Rebuilds providers after cookie settings change.
  void refreshProviders() => providers = ProviderRegistry(worker, sharedOptions());

  static Future<AppServices> load({
    void Function(ApplicationStore store)? onStoreReady,
  }) async {
    final paths = await AppPaths.resolve();
    final store = ApplicationStore.open(
      paths.stateDatabase,
      defaultDownloadDirectory: paths.defaultMusicDirectory,
      legacyPath: paths.legacyState,
    );
    onStoreReady?.call(store);
    final settings = store.settings;
    final manager = MusicManager.open(
      paths.libraryDatabase,
      settings.downloadDirectory,
      additionalMusicFolders: [?paths.publicMusicDirectory],
      legacyMetadataPath: paths.legacyLibrary,
    );
    final checkForUpdate = YtDlpRuntime.consumeUpdateRequest(store);
    final worker = WorkerClient(await _startWorker(paths, checkForUpdate));
    unawaited(
      worker.ready.then(
        (status) => debugPrint(
          "yt-dlp ${status["active_version"]} ready (${status["active_source"]})",
        ),
      ),
    );
    final thumbnails = ThumbnailCache(paths.thumbnails);
    final shared = sharedYtDlpOptions(settings, ffmpegLocation: paths.ffmpegLocation);
    final downloads = await DownloadCoordinator.open(
      manager,
      store,
      settings,
      worker,
      thumbnails: thumbnails,
      sharedOptions: shared,
    );
    return AppServices(
      paths: paths,
      store: store,
      manager: manager,
      library: LibraryService(manager, store),
      thumbnails: thumbnails,
      worker: worker,
      providers: ProviderRegistry(worker, shared),
      downloads: downloads,
      ytDlp: YtDlpRuntime(store, worker),
      availableTrackIds: _availableResumeTracks(manager, store),
    );
  }

  /// Source-tree development can run the worker in a standalone interpreter:
  /// set `MELODY_WORKER_PYTHON` (and optionally `MELODY_WORKER_SOURCE`).
  static Future<WorkerTransport> _startWorker(AppPaths paths, bool checkForUpdate) {
    final python = Platform.environment["MELODY_WORKER_PYTHON"];
    if (python != null && python.isNotEmpty) {
      return ProcessTransport.start(
        python: python,
        workerSource:
            Platform.environment["MELODY_WORKER_SOURCE"] ??
            p.normalize(p.join(Directory.current.path, "..", "worker", "src")),
        runtimeDirectory: paths.ytDlpRuntime,
        checkForUpdate: checkForUpdate,
      );
    }
    return BridgeTransport.start(
      runtimeDirectory: paths.ytDlpRuntime,
      checkForUpdate: checkForUpdate,
    );
  }

  /// Checks only the restored queue's files, not the whole library.
  static Set<String> _availableResumeTracks(MusicManager manager, ApplicationStore store) {
    if (!store.settings.resumeSession) return {};
    final playback = store.get("playback");
    final queue = playback is Map ? playback["queue"] : null;
    if (queue is! List) return {};
    return {
      for (final id in queue.whereType<String>())
        if (manager.hasTrack(id) && File(manager.trackPath(id)).existsSync()) id,
    };
  }
}
