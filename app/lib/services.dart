import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";

import "application/catalog.dart";
import "application/downloads.dart";
import "application/library_service.dart";
import "application/lyrics.dart";
import "application/lyrics_embedding.dart";
import "application/models.dart" show AppSettings;
import "application/package_runtime.dart";
import "application/store.dart";
import "application/thumbnails.dart";
import "core/library/manager.dart";
import "core/storage.dart" show existingFiles, removeStaleTemporaries;
import "platform/paths.dart";
import "worker/worker_client.dart";

/// Everything loaded before the first view: durable state, the library, and
/// the Python worker (which selects ytmusicapi and yt-dlp in the background).
class AppServices {
  AppServices({
    required this.paths,
    required this.store,
    required this.manager,
    required this.library,
    required this.thumbnails,
    required this.worker,
    required this.catalog,
    required this.downloads,
    required this.ytDlp,
    required this.ytMusic,
    required this.lyrics,
    required this.lyricsEmbedder,
    required this.availableTrackIds,
  });

  final AppPaths paths;
  final ApplicationStore store;
  final MusicManager manager;
  final LibraryService library;
  final ThumbnailCache thumbnails;
  final WorkerClient worker;
  final MusicCatalog catalog;
  final DownloadCoordinator downloads;
  final PackageRuntime ytDlp;
  final PackageRuntime ytMusic;
  final LyricsLibrary lyrics;

  /// Puts lyrics inside library audio files. Null on Android, where
  /// library files are published media that are not rewritten.
  final LyricsEmbedder? lyricsEmbedder;

  /// Both updatable packages, in the order Settings lists them.
  List<PackageRuntime> get runtimes => [ytMusic, ytDlp];

  /// Restored queue entries whose files exist; checked once at startup.
  final Set<String> availableTrackIds;

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
      syncInBackground: true,
    );
    const packages = [ytDlpRuntimeInfo, ytMusicRuntimeInfo];
    final worker = await WorkerClient.start(
      runtimes: WorkerRuntimes({
        ytDlpPackage: paths.ytDlpRuntime,
        ytMusicPackage: paths.ytMusicRuntime,
      }, update: PackageRuntime.consumeUpdateRequests(store, packages)),
    );
    unawaited(
      worker.ready.then((status) {
        for (final info in packages) {
          final selection = status[info.package];
          debugPrint(
            selection.available
                ? "${info.label} ${selection.activeVersion} ready "
                      "(${selection.activeSource})"
                : "${info.label} is unavailable: ${selection.errors.join("; ")}",
          );
        }
      }),
    );
    final thumbnails = await ThumbnailCache.open(paths.thumbnails);
    Map<String, Object?> sharedOptions() => sharedYtDlpOptions(
      store.settings,
      ffmpegLocation: paths.ffmpegLocation,
      cacheDirectory: paths.ytDlpCache,
    );
    final catalog = MusicCatalog(worker, sharedOptions);
    final lyrics = LyricsLibrary(paths.lyrics, catalog.lyrics);
    final lyricsEmbedder = Platform.isAndroid
        ? null
        : LyricsEmbedder(
            manager,
            lyrics,
            (source, target, tags) => worker.tag(
              source: source,
              target: target,
              metadata: tags,
              options: sharedOptions(),
            ),
          );
    final library = LibraryService(
      manager,
      store,
      thumbnails: thumbnails,
      lyrics: lyrics,
    );
    // Before downloads open, so no finishing download is caching artwork.
    await library.removeUnusedArtwork();
    unawaited(_removeLeftovers(paths, settings));
    final downloads = await DownloadCoordinator.open(
      manager,
      store,
      settings,
      worker,
      thumbnails: thumbnails,
      lyrics: lyrics,
      // Download options apply from the next launch (Settings says so).
      sharedOptions: sharedOptions(),
    );
    return AppServices(
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
      lyrics: lyrics,
      lyricsEmbedder: lyricsEmbedder,
      availableTrackIds: await _availableResumeTracks(manager, store),
    );
  }

  /// Startup housekeeping that needs no ordering: temporary files a crash
  /// left mid-write, and yt-dlp's cache. Download staging and receipts are
  /// the download coordinator's; library copies are their owners'.
  static Future<void> _removeLeftovers(
    AppPaths paths,
    AppSettings settings,
  ) async {
    try {
      for (final directory in {
        paths.dataDirectory,
        paths.thumbnails,
        paths.lyrics,
        settings.downloadDirectory,
      }) {
        await removeStaleTemporaries(directory);
      }
      await pruneYtDlpCache(paths.ytDlpCache);
    } on Object catch (error) {
      debugPrint("Startup cleanup was skipped: $error");
    }
  }

  /// Checks only the restored queue's files, not the whole library.
  static Future<Set<String>> _availableResumeTracks(
    MusicManager manager,
    ApplicationStore store,
  ) async {
    if (!store.settings.resumeSession) return {};
    final playback = store.get("playback");
    final queue = playback is Map ? playback["queue"] : null;
    if (queue is! List) return {};
    final ids = queue.whereType<String>().where(manager.hasTrack).toSet();
    final paths = <String, String>{};
    for (final id in ids) {
      try {
        paths[id] = manager.trackPath(id);
      } on ArgumentError {
        // A path outside the music folders is unavailable, not fatal.
      }
    }
    final existing = await existingFiles(paths.values);
    return {
      for (final MapEntry(key: id, value: path) in paths.entries)
        if (existing.contains(path)) id,
    };
  }
}
