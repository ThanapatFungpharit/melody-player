import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "application/catalog.dart";
import "application/downloads.dart";
import "application/library_service.dart";
import "application/loudness.dart";
import "application/lyrics.dart";
import "application/lyrics_embedding.dart";
import "application/package_runtime.dart";
import "application/storage_upgrade.dart";
import "application/store.dart";
import "application/thumbnails.dart";
import "core/library/manager.dart";
import "audio/audio_backend.dart" show audioLimiterHeadroomDb, audioMaxBoostDb;
import "core/loudness.dart"
    show ffmpegAudioHasher, ffmpegExecutable, ffmpegLoudnessMeter;
import "core/storage.dart" show existingFiles, removeStaleTemporaries;
import "package:melody_audio/melody_audio.dart"
    show useNotificationArtworkDirectory;
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
    required this.loudness,
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

  /// Measures library tracks and gives playback their normalization gains.
  final LoudnessNormalizer loudness;

  /// Both updatable packages, in the order Settings lists them.
  List<PackageRuntime> get runtimes => [ytMusic, ytDlp];

  /// Restored queue entries whose files exist; checked once at startup.
  final Set<String> availableTrackIds;

  static Future<AppServices> load({
    void Function(ApplicationStore store)? onStoreReady,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call("Finding your music");
    final paths = await AppPaths.resolve();
    final legacy = LegacyLayout(paths);
    // Before anything opens a folder that moved.
    await relocateLegacyFolders(legacy);
    useNotificationArtworkDirectory(paths.notificationArtworkCache);
    final storesExisted =
        File(paths.stateDatabase).existsSync() &&
        File(paths.libraryDatabase).existsSync();
    final store = ApplicationStore.open(
      paths.stateDatabase,
      defaultDownloadDirectory: paths.defaultMusicDirectory,
      legacyPath: legacy.stateJson,
    );
    onStoreReady?.call(store);
    onStage?.call("Opening your library");
    final manager = MusicManager.open(
      paths.libraryDatabase,
      store.settings.downloadDirectory,
      additionalMusicFolders: [?paths.publicMusicRoot],
      legacyMetadataPath: legacy.libraryMmdb,
      syncInBackground: true,
      moveJournal: paths.musicMoveJournal,
    );
    await upgradeLegacyState(
      legacy,
      store,
      manager,
      storesExisted: storesExisted,
    );
    onStage?.call("Starting the music engine");
    const packages = [ytDlpRuntimeInfo, ytMusicRuntimeInfo];
    final worker = await WorkerClient.start(
      runtimes: WorkerRuntimes({
        for (final info in packages) info.package: paths.runtime(info.package),
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
    onStage?.call("Gathering artwork");
    final thumbnails = await ThumbnailCache.open(paths.artworkCache);
    Map<String, Object?> sharedOptions() => sharedYtDlpOptions(
      ffmpegLocation: paths.ffmpegLocation,
      cacheDirectory: paths.ytDlpCache,
      cookieFile: paths.cookieFile,
    );
    final catalog = MusicCatalog(worker, sharedOptions);
    final lyrics = LyricsLibrary(paths.lyrics, catalog.lyrics);
    final lyricsEmbedder = Platform.isAndroid
        ? null
        : LyricsEmbedder(
            manager,
            lyrics,
            store,
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
    // Before downloads open, so no finishing download is caching artwork or
    // registering a file.
    await library.releasePendingFiles();
    await library.removeUnusedCaches();
    unawaited(_removeLeftovers(paths, manager));
    onStage?.call("Resuming downloads");
    final downloads = await DownloadCoordinator.open(
      manager,
      store,
      store.settings,
      worker,
      thumbnails: thumbnails,
      lyrics: lyrics,
      // Download options apply from the next launch (Settings says so).
      sharedOptions: sharedOptions(),
      stagingDirectory: paths.downloadStaging,
      receiptDirectory: paths.downloadReceipts,
    );
    final ffmpeg = ffmpegExecutable(paths.ffmpegLocation);
    final loudness = await LoudnessNormalizer.open(
      manager,
      paths.loudnessCache,
      ffmpegLoudnessMeter(ffmpeg),
      hasher: ffmpegAudioHasher(ffmpeg),
      enabled: store.settings.normalizeLoudness,
      targetLufs: store.settings.loudnessTarget.toDouble(),
      maxBoostDb: audioMaxBoostDb,
      limiterHeadroomDb: audioLimiterHeadroomDb,
    );
    onStage?.call("Restoring your queue");
    final availableTrackIds = await _availableResumeTracks(manager, store);
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
      loudness: loudness,
      availableTrackIds: availableTrackIds,
    );
  }

  /// Startup housekeeping that needs no ordering: temporary files a crash
  /// left mid-write (in Melody's data and beside library tracks), and
  /// yt-dlp's cache. Download staging and receipts are the download
  /// coordinator's.
  static Future<void> _removeLeftovers(
    AppPaths paths,
    MusicManager manager,
  ) async {
    try {
      final trackFolders = <String>{manager.musicFolder};
      for (final track in manager.listTracks()) {
        try {
          trackFolders.add(p.dirname(manager.trackPath(track.id)));
        } on ArgumentError {
          // Outside the music folders: not Melody's to clean.
        }
      }
      for (final directory in {...paths.atomicWriteFolders, ...trackFolders}) {
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
