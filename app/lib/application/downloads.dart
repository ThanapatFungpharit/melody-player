import "dart:async";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../core/downloader/downloader.dart";
import "../core/errors.dart";
import "../core/library/manager.dart";
import "../core/library/models.dart";
import "../core/media.dart";
import "../core/storage.dart";
import "../worker/worker_client.dart";
import "library_service.dart" show LibraryService;
import "lyrics.dart";
import "models.dart";
import "owned_files.dart";
import "store.dart";
import "thumbnails.dart";

final _downloadUrlPattern = RegExp(
  r'''https?://[^\s<>"']+''',
  caseSensitive: false,
);

/// Unique HTTP(S) URLs from lines, bullets, or pasted prose.
List<String> extractDownloadUrls(String value) {
  final seen = <String>{};
  return [
    for (final match in _downloadUrlPattern.allMatches(value))
      if (_trimProse(match.group(0)!) case final url
          when url.isNotEmpty && seen.add(url))
        url,
  ];
}

/// Drops sentence punctuation after a URL, and a closing bracket that the
/// URL never opened, as in "(https://youtu.be/…)".
String _trimProse(String url) {
  var end = url.length;
  while (end > 0) {
    final last = url[end - 1];
    if (".,;".contains(last)) {
      end--;
      continue;
    }
    final open = switch (last) {
      ")" => "(",
      "]" => "[",
      _ => null,
    };
    if (open == null) break;
    final head = url.substring(0, end);
    if (open.allMatches(head).length >= last.allMatches(head).length) break;
    end--;
  }
  return url.substring(0, end);
}

class DuplicateDownloadError implements Exception {
  @override
  String toString() => "This track is already downloading.";
}

const _notASongLink =
    "Only links to single songs can be downloaded here. To save a playlist, "
    "use Import playlist on the Playlists page.";

const _lostFileError =
    "The downloaded library file is missing. Retry to restore it.";

/// The form Melody stores a song's link in, without playlist or tracking
/// parameters. Any other link stays as it is, for [DownloadCoordinator] to
/// refuse.
String _canonicalSource(String url) =>
    isYoutubeUrl(url) ? youtubeMusicTrackUrl(url) : url;

/// What [DownloadCoordinator.request] did with a result: found an intact
/// library [track], or joined or started the download [task].
class DownloadRequest {
  const DownloadRequest.existing(Track this.track)
    : task = null,
      started = false;

  const DownloadRequest.task(String this.task, {required this.started})
    : track = null;

  final Track? track;
  final String? task;

  /// This call started [task], so only this caller may cancel it.
  final bool started;
}

/// A group of independently scheduled song downloads.
class DownloadBatch {
  const DownloadBatch(
    this.id,
    this.tasks,
    this.size, {
    this.started = 0,
    this.existing = 0,
    this.failed = 0,
  });

  final String id;

  /// Tasks the batch's songs are downloading in, new and joined.
  final List<String> tasks;
  final int size;

  /// Songs this batch started downloading.
  final int started;

  /// Songs already intact in the library.
  final int existing;

  /// Songs that could not be scheduled; their history entries say why.
  final int failed;

  /// Songs that joined a download already in progress.
  int get joined => tasks.length - started;
}

/// yt-dlp options for downloads with the user's codec and quality.
Map<String, Object?> downloadOptions(
  AppSettings settings,
  Map<String, Object?> sharedOptions,
) => {
  "format": "bestaudio/best",
  "outtmpl": "%(title)s.%(ext)s",
  // One task is one song: the files of a task are registered under one source,
  // so a song link's playlist must not come along.
  "noplaylist": true,
  "quiet": true,
  "noprogress": true,
  // What another attempt looks for, to skip a song already downloaded.
  "final_ext": settings.downloadFormat.extension.substring(1),
  "postprocessors": [
    {
      "key": "FFmpegExtractAudio",
      "preferredcodec": settings.downloadFormat.codec,
      "preferredquality":
          settings.downloadFormat.lossless || settings.audioQuality == "best"
          ? "0"
          : settings.audioQuality,
    },
    {"key": "FFmpegMetadata"},
    // Keep the sidecar in staging after yt-dlp burns it into the media; the
    // downloader verifies the embedded tag and derives the UI cache from it.
    {"key": "EmbedThumbnail", "already_have_thumbnail": true},
  ],
  "writethumbnail": true,
  "addmetadata": true,
  ...sharedOptions,
};

Map<String, Object?> _noSharedOptions() => const {};

/// Turns downloader jobs into persistent, library-aware operations.
///
/// Worker callbacks can arrive many times per second. Listeners hear about
/// byte progress at most every [progressNotifyInterval]; status changes are
/// written and published immediately, and byte progress saved every few
/// seconds. A download still active at startup carries on from
/// what it left on disk ([resumeInterrupted]), and its row from what it last
/// showed.
class DownloadCoordinator extends ChangeNotifier {
  DownloadCoordinator._(
    this.manager,
    this.store,
    this._historyDays,
    this.thumbnails,
    this._downloader,
    this.lyrics,
    this._sharedOptions,
    this._progressSaveInterval,
  );

  static const progressNotifyInterval = Duration(milliseconds: 200);
  static const maxRetainedRecords = ApplicationStore.maxDownloadRecords;

  final MusicManager manager;
  final ApplicationStore store;
  final ThumbnailCache? thumbnails;
  final Downloader _downloader;
  late final OwnedFiles _files = OwnedFiles(store, manager);

  /// Supplies lyrics to embed in downloaded files.
  final LyricsLibrary? lyrics;
  final Map<String, Object?> Function() _sharedOptions;
  final Duration _progressSaveInterval;
  final Map<String, DownloadRecord> _records = {};
  final Map<String, String> _activeBySource = {};
  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastNotify = Duration.zero;
  Duration _lastProgressSave = Duration.zero;

  /// What the last run was still downloading.
  final List<String> _interrupted = [];
  final Set<String> _cancelRequested = {};
  bool _closing = false;

  /// Called with each published record change (terminal ones included).
  void Function(DownloadRecord record)? onRecord;

  static Future<DownloadCoordinator> open(
    MusicManager manager,
    ApplicationStore store,
    AppSettings settings,
    WorkerClient worker, {
    ThumbnailCache? thumbnails,
    LyricsLibrary? lyrics,
    Map<String, Object?> Function() sharedOptions = _noSharedOptions,
    required String stagingDirectory,
    Duration progressSaveInterval = const Duration(seconds: 5),
  }) async {
    final coordinator = DownloadCoordinator._(
      manager,
      store,
      settings.downloadHistoryDays,
      thumbnails,
      Downloader(
        worker,
        settings.downloadDirectory,
        maxWorkers: settings.concurrentDownloads,
        audioExtensions: {settings.downloadFormat.extension},
        options: downloadOptions(settings, sharedOptions()),
        stagingDirectory: stagingDirectory,
      ),
      lyrics,
      sharedOptions,
      progressSaveInterval,
    );
    await coordinator._recover();
    return coordinator;
  }

  Future<void> _recover() async {
    for (final record in store.downloads()) {
      _records[record.id] = record;
    }
    // Before any job starts, so only earlier processes' directories qualify.
    final abandoned = await _downloader.removeAbandonedStaging(
      resumableUrls: [
        for (final record in _records.values)
          if (record.status.isActive || record.status == DownloadStatus.failed)
            record.url,
      ],
    );
    if (abandoned > 0) {
      debugPrint("Removed $abandoned abandoned download staging folder(s)");
    }
    final lost = await _lostTrackIds();
    var recovered = false;
    for (final record in _records.values) {
      final lostFile = record.trackIds.any(lost.contains);
      if (record.status == DownloadStatus.completed && lostFile) {
        recovered = true;
        record
          ..status = DownloadStatus.failed
          ..error = _lostFileError
          ..errorKind = "disk"
          ..recovery = "retry";
      } else if (_flaggedLost(record) && !lostFile) {
        // Earlier releases flagged tracks the user removed too, and retrying
        // would bring those back.
        recovered = true;
        record
          ..status = DownloadStatus.completed
          ..error = ""
          ..errorKind = ""
          ..recovery = "";
      }
      if (record.status.isActive) {
        recovered = true;
        _interrupted.add(record.id);
        record
          ..status = DownloadStatus.failed
          ..error =
              "The application closed before this download finished. Retry it.";
      }
    }
    if (_removeDuplicates()) recovered = true;
    if (_expire()) recovered = true;
    if (recovered) _persist();
  }

  /// Carries on with what the last run was still downloading, unless it
  /// reached the library just before the end. Call it once [onRecord] is
  /// listening.
  /// One that cannot start stays failed, to retry by hand.
  Future<void> resumeInterrupted() async {
    final interrupted = List.of(_interrupted);
    _interrupted.clear();
    for (final id in interrupted) {
      try {
        final record = _records[id];
        if (record == null) continue;
        if (await availableTrack(record.url) case final track?) {
          record
            ..status = DownloadStatus.completed
            ..progress = 1.0
            ..error = ""
            ..trackIds = [track.id]
            ..completedAt = unixSeconds();
          _persist();
          _publish(record);
        } else {
          await retry(id);
        }
      } catch (error) {
        debugPrint("Could not resume download $id: $error");
      }
    }
  }

  /// Applies [settings] to the history and to downloads that start from now
  /// on, with the cookie file as it is now.
  void applySettings(AppSettings settings) {
    _downloader.configure(
      maxWorkers: settings.concurrentDownloads,
      audioExtensions: {settings.downloadFormat.extension},
      options: downloadOptions(settings, _sharedOptions()),
    );
    historyDays = settings.downloadHistoryDays;
  }

  /// Days a finished download stays in the history; 0 keeps it forever.
  int get historyDays => _historyDays;
  int _historyDays;

  set historyDays(int days) {
    if (days == _historyDays) return;
    _historyDays = days;
    if (_expire()) {
      _persist();
      notifyListeners();
    }
  }

  /// When a finished download older than this leaves the history, if ever.
  double? get _historyCutoff =>
      _historyDays > 0 ? unixSeconds() - _historyDays * 86400 : null;

  static bool _expired(DownloadRecord record, double? cutoff) =>
      cutoff != null &&
      !record.status.isActive &&
      max(record.createdAt, record.completedAt) < cutoff;

  /// Drops finished downloads older than [historyDays].
  bool _expire() {
    final cutoff = _historyCutoff;
    final before = _records.length;
    _records.removeWhere((_, record) => _expired(record, cutoff));
    return _records.length != before;
  }

  /// Newest first. Entries that expired since the last cleanup are left
  /// out, so a long session hides them before the next one removes them.
  List<DownloadRecord> list() {
    final cutoff = _historyCutoff;
    final records = [
      for (final record in _records.values)
        if (!_expired(record, cutoff)) record.copy(),
    ];
    records.sort((a, b) {
      final created = b.createdAt.compareTo(a.createdAt);
      return created != 0
          ? created
          : a.batchPosition.compareTo(b.batchPosition);
    });
    return records;
  }

  DownloadRecord? get(String recordId) => _records[recordId]?.copy();

  int activeCount() => _activeBySource.length;

  /// The library track for [url] whose file is there, if one exists.
  Future<Track?> availableTrack(String url) async {
    if (url.isEmpty) return null;
    final existing = manager.findTrackBySource(url);
    if (existing == null) return null;
    try {
      return await manager.checkTrackFile(existing.id) == null
          ? existing
          : null;
    } on Object {
      return null;
    }
  }

  /// Reuses an intact library track or an active job before scheduling new
  /// work. With [resolveMetadata], the result's title is a placeholder until
  /// yt-dlp reports the song's own details.
  Future<DownloadRequest> request(
    SearchResult result, {
    bool resolveMetadata = false,
  }) {
    if (result.url.isEmpty) {
      throw ArgumentError("This result does not provide a downloadable URL.");
    }
    return _request(
      resolveMetadata
          ? _DownloadMetadata.url(result.url, title: result.title)
          : _DownloadMetadata.fromResult(result),
    );
  }

  /// Schedules several URLs as one batch; each song remains an independent
  /// task so one failure cannot cancel the rest.
  Future<DownloadBatch> startUrls(Iterable<String> urls) async {
    final sources = <String>[];
    final seen = <String>{};
    for (final value in urls) {
      final source = value.trim();
      if (source.isEmpty || !seen.add(source)) continue;
      if (!isYoutubeUrl(source)) {
        throw ArgumentError("Only $youtubeMusicName URLs are supported.");
      }
      if (MediaIdentity.fromUrl(source) == null) {
        throw ArgumentError(_notASongLink);
      }
      sources.add(source);
    }
    if (sources.isEmpty) {
      throw ArgumentError("At least one $youtubeMusicName URL is required.");
    }
    final batchId = const Uuid().v4();
    final createdAt = unixSeconds();
    final keys = <String>{};
    final unique = [
      for (final source in sources)
        if (sourceKey(source) case final key when key.isEmpty || keys.add(key))
          source,
    ];
    final tasks = <String>[];
    var started = 0;
    var existing = 0;
    var failed = 0;
    for (final (index, source) in unique.indexed) {
      final metadata = _DownloadMetadata.url(
        source,
        title: "Song ${index + 1} of ${unique.length}",
        createdAt: createdAt,
        batchId: batchId,
        batchPosition: index + 1,
        batchSize: unique.length,
      );
      try {
        final request = await _request(metadata);
        if (request.task case final task?) {
          tasks.add(task);
          if (request.started) started++;
        } else {
          existing++;
        }
      } catch (error) {
        // Record this song's scheduling failure, then continue the batch.
        debugPrint("Batch download could not be scheduled: $source: $error");
        _recordStartFailure(metadata, error);
        failed++;
      }
    }
    return DownloadBatch(
      batchId,
      tasks,
      unique.length,
      started: started,
      existing: existing,
      failed: failed,
    );
  }

  Future<DownloadRequest> _request(_DownloadMetadata metadata) async {
    final url = metadata.url;
    if (url.isEmpty) {
      throw ArgumentError("A $youtubeMusicName URL is required.");
    }
    if (!isYoutubeUrl(url)) {
      throw ArgumentError("Only $youtubeMusicName URLs are supported.");
    }
    if (await availableTrack(url) case final track?) {
      return DownloadRequest.existing(track);
    }
    final active = _activeRecordForSource(url);
    if (active != null) return DownloadRequest.task(active.id, started: false);
    return DownloadRequest.task(_start(metadata), started: true);
  }

  String _start(_DownloadMetadata metadata) {
    final url = metadata.url;
    if (!isYoutubeUrl(url)) {
      throw ArgumentError("Only $youtubeMusicName URLs are supported.");
    }
    if (MediaIdentity.fromUrl(url) == null) throw ArgumentError(_notASongLink);
    if (_activeRecordForSource(url) != null) throw DuplicateDownloadError();
    String? task;
    final lyrics = this.lyrics;
    task = _downloader.start(
      url,
      onProgress: (progress) {
        if (task != null) _handleProgress(progress, metadata);
      },
      onComplete: (result) => unawaited(_handleComplete(result, metadata)),
      lyrics: lyrics == null
          ? null
          : () async => (await lyrics.load(url))?.toLrc(),
    );
    // Register the source before returning so a second request in the gap
    // before the first progress callback joins this task.
    _ensureRecord(task, metadata);
    _persist();
    return task;
  }

  /// Moves later downloads and the library to [folder] at once, so a file
  /// is never stored in one folder and recorded relative to another. Runs
  /// under the library lock, where no download can be importing, and only
  /// while nothing is downloading. A library with tracks changes folder only
  /// when [moveLibrary] moves its files along; the caller must release any
  /// file the player holds open. Returns the number of files moved.
  Future<int> changeDirectory(
    String folder, {
    bool moveLibrary = false,
  }) => manager.mutation.run(() async {
    if (_activeBySource.isNotEmpty) {
      throw const FormatException(
        "The music folder can't be changed while downloads are in progress.",
      );
    }
    final empty = manager.counts().$1 == 0;
    if (!empty && !moveLibrary) {
      throw const FormatException(
        "Move the library to change the music folder while it has tracks.",
      );
    }
    final previous = manager.musicFolder;
    _downloader.changeOutputDirectory(folder);
    try {
      if (empty) {
        manager.changeMusicFolder(folder);
        return 0;
      }
      return await manager.moveMusicFolder(
        folder,
        companions: (path) => [LyricsLibrary.sidecarPath(path)],
      );
    } catch (_) {
      _downloader.changeOutputDirectory(previous);
      rethrow;
    }
  });

  bool cancel(String recordId) {
    final cancelled = _downloader.cancel(recordId);
    if (cancelled) _cancelRequested.add(recordId);
    return cancelled;
  }

  /// Starts a new attempt, which takes the entry's place in the history.
  Future<String> retry(String recordId) async {
    final original = _records[recordId];
    if (original == null) {
      throw ArgumentError("Download history entry was not found.");
    }
    if (original.status.isActive) {
      throw ArgumentError("This download is still in progress.");
    }
    final task = _start(_DownloadMetadata.retrying(original));
    notifyListeners();
    return task;
  }

  /// Retries every failed download, once per song, skipping songs already
  /// downloading. Returns how many retries started; throws the first error
  /// only when none could start.
  Future<int> retryFailed() async {
    final songs = <String>{};
    var started = 0;
    Object? firstError;
    for (final record in list()) {
      if (record.status != DownloadStatus.failed) continue;
      if (!songs.add(_songKey(record.url))) continue;
      if (_activeRecordForSource(record.url) != null) continue;
      try {
        await retry(record.id);
        started++;
      } catch (error) {
        debugPrint("Could not retry download ${record.url}: $error");
        firstError ??= error;
      }
    }
    if (started == 0 && firstError != null) throw firstError;
    return started;
  }

  void clearFinished() {
    _records.removeWhere((_, record) => !record.status.isActive);
    _persist();
    notifyListeners();
  }

  /// Stops every job. Those the user did not cancel stay active in the saved
  /// history, for the next launch to pick up.
  void shutdown() {
    if (!_closing) _persist();
    _closing = true;
    _downloader.shutdown(cancelPending: true);
  }

  void _handleProgress(DownloadProgress progress, _DownloadMetadata metadata) {
    if (_closing) return;
    final record = _ensureRecord(progress.task, metadata);
    final previous = record.status;
    record
      ..status = progress.status == DownloadStatus.completed
          ? DownloadStatus.processing
          : progress.status
      ..filename = progress.filename.isEmpty
          ? ""
          : p.basename(progress.filename)
      ..error = friendlyDownloadError(progress.error);
    // Reports without bytes know nothing yet, as when an attempt starts: the
    // row keeps showing how far the song has got.
    if (progress.downloadedBytes > 0 || progress.totalBytes > 0) {
      record
        ..progress = progress.progress
        ..downloadedBytes = progress.downloadedBytes
        ..totalBytes = progress.totalBytes;
    }
    if (metadata.resolveMetadata) {
      if (progress.mediaTitle.isNotEmpty) record.title = progress.mediaTitle;
      if (progress.uploader.isNotEmpty) record.uploader = progress.uploader;
      if (progress.thumbnail.isNotEmpty) record.thumbnail = progress.thumbnail;
    }
    // A terminal snapshot is followed by the completion handler.
    if (record.status.isUnsuccessful) return;
    final now = _clock.elapsed;
    final changed = record.status != previous;
    if (changed || now - _lastProgressSave >= _progressSaveInterval) {
      _lastProgressSave = now;
      _persist();
    }
    if (changed || now - _lastNotify >= progressNotifyInterval) {
      _lastNotify = now;
      _publish(record);
    }
  }

  Future<void> _handleComplete(
    DownloadResult result,
    _DownloadMetadata metadata,
  ) async {
    if (_closing &&
        result.status.isUnsuccessful &&
        !_cancelRequested.contains(result.task)) {
      return;
    }
    _cancelRequested.remove(result.task);
    final record = _ensureRecord(result.task, metadata);
    var status = result.status;
    var error = result.failure?.message ?? friendlyDownloadError(result.error);
    List<String>? imported;
    String? storedName;
    if (result.status == DownloadStatus.completed) {
      imported = [];
      final storedPaths = <String>[];
      try {
        for (final path in result.files) {
          final (trackId, stored) = await _importDownloadedFile(
            path,
            metadata,
            title: record.title,
            uploader: record.uploader,
            thumbnail: record.thumbnail,
          );
          imported.add(trackId);
          storedPaths.add(stored);
        }
        if (storedPaths.isNotEmpty) storedName = p.basename(storedPaths.first);
        // Only once a track uses it, so a failed import leaves no entry.
        await _cacheArtwork(imported, result.artwork);
      } catch (failure) {
        debugPrint("Downloaded media could not be imported: $failure");
        status = DownloadStatus.failed;
        error = "Downloaded, but could not add to the library: $failure";
        imported = null;
        // Retrying downloads it again, so this attempt leaves no stray file.
        for (final path in result.files) {
          if (!manager.isPathReferenced(path)) await deleteQuietly(path);
        }
      }
    }
    record
      ..status = status
      ..error = error
      ..errorKind = result.failure?.kind.value ?? ""
      ..recovery = result.failure?.recovery ?? ""
      ..completedAt = unixSeconds();
    if (imported != null) {
      record
        ..progress = 1.0
        ..trackIds = imported;
      if (storedName != null) record.filename = storedName;
    }
    final identity = sourceKey(record.url);
    if (_activeBySource[identity] == record.id) {
      _activeBySource.remove(identity);
    }
    _expire();
    _prune();
    _persist();
    _publish(record);
  }

  /// Caches artwork read from the media file; the file stays canonical.
  Future<void> _cacheArtwork(List<String> trackIds, Uint8List? artwork) async {
    if (artwork == null) return;
    for (final trackId in trackIds.toSet()) {
      await thumbnails?.store(trackId, artwork);
    }
  }

  /// Registers audio or reuses its library identity, keeping existing metadata.
  Future<(String, String)> _importDownloadedFile(
    String path,
    _DownloadMetadata metadata, {
    required String title,
    required String uploader,
    required String thumbnail,
  }) => manager.mutation.run(() async {
    final source = metadata.url;
    final details = TrackDetails(
      uploader: uploader,
      duration: metadata.duration,
      thumbnail: thumbnail,
      sourceName: metadata.source,
    );
    final existing =
        manager.findTrackBySource(source) ??
        await manager.findTrackByContent(path);
    if (existing != null) {
      if (!store.hasTrackDetails(existing.id)) {
        store.saveTrackDetails(existing.id, details);
      }
      return (existing.id, await _reuseLibraryTrack(existing, path, source));
    }
    final trackId = await manager.addTrack(
      path,
      source: source,
      title: title.trim().isNotEmpty ? title : p.basenameWithoutExtension(path),
    );
    store.saveTrackDetails(trackId, details);
    return (trackId, manager.trackPath(trackId));
  });

  /// Keeps the file the track has, which may have been edited since, or
  /// repairs a missing or empty one without replacing the record.
  Future<String> _reuseLibraryTrack(
    Track track,
    String path,
    String source,
  ) async {
    final previousPath = manager.trackPath(track.id);
    final problem = await manager.checkTrackFile(track.id);
    String stored;
    if (problem == null) {
      // The library already has this song: the new copy goes.
      stored = previousPath;
      if (!samePath(path, stored)) {
        _files.mark([path]);
        await _files.release([path]);
      }
    } else {
      // An empty file goes once the track points at the new one, if Melody
      // downloaded it.
      final superseded = [
        if (!samePath(previousPath, path) && LibraryService.isDownload(track))
          previousPath,
      ];
      _files.mark(superseded);
      await manager.replaceTrackFile(track.id, path);
      stored = manager.trackPath(track.id);
      await _files.release(superseded);
    }
    if (track.source.isEmpty) manager.updateTrack(track.id, source: source);
    return stored;
  }

  DownloadRecord _ensureRecord(String task, _DownloadMetadata metadata) {
    final created = !_records.containsKey(task);
    final record = _records.putIfAbsent(task, () => metadata.toRecord(task));
    if (created) _replaceEarlier(record);
    _prune();
    final identity = sourceKey(record.url);
    if (identity.isNotEmpty && record.status.isActive) {
      _activeBySource[identity] = record.id;
    }
    return record;
  }

  void _recordStartFailure(_DownloadMetadata metadata, Object error) {
    final record = metadata.toRecord(const Uuid().v4())
      ..status = DownloadStatus.failed
      ..error = friendlyDownloadError("$error")
      ..completedAt = unixSeconds();
    _records[record.id] = record;
    _replaceEarlier(record);
    _prune();
    _persist();
    _publish(record);
  }

  /// The history lists each song once: a new attempt replaces the song's
  /// finished entries. An active one is never dropped.
  void _replaceEarlier(DownloadRecord record) {
    _records.removeWhere(
      (id, other) =>
          id != record.id &&
          !other.status.isActive &&
          _sameSource(other.url, record.url),
    );
  }

  /// Keeps the newest entry of each song, for history saved before entries
  /// were replaced.
  bool _removeDuplicates() {
    final newest = <String, DownloadRecord>{};
    for (final record in _records.values) {
      final song = _songKey(record.url);
      if (song.isEmpty) continue;
      final kept = newest[song];
      if (kept == null || record.createdAt > kept.createdAt) {
        newest[song] = record;
      }
    }
    final before = _records.length;
    _records.removeWhere((id, record) {
      final song = _songKey(record.url);
      return song.isNotEmpty && newest[song]!.id != id;
    });
    return _records.length != before;
  }

  void _persist() {
    try {
      store.saveDownloads(_records.values);
    } on Object catch (error) {
      debugPrint("Could not save download history: $error");
    }
  }

  /// Bounded history that never evicts an active operation.
  void _prune() {
    final excess = _records.length - maxRetainedRecords;
    if (excess <= 0) return;
    final finished =
        _records.values.where((record) => !record.status.isActive).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final record in finished.take(excess)) {
      _records.remove(record.id);
    }
  }

  void _publish(DownloadRecord record) {
    notifyListeners();
    try {
      onRecord?.call(record.copy());
    } catch (error) {
      debugPrint("Download listener failed: $error");
    }
  }

  DownloadRecord? _activeRecordForSource(String url) {
    final id = _activeBySource[sourceKey(url)];
    return id == null ? null : _records[id];
  }

  static bool _flaggedLost(DownloadRecord record) =>
      record.status == DownloadStatus.failed && record.error == _lostFileError;

  /// Library tracks of finished downloads whose files are gone or empty,
  /// checked in one batch off the UI isolate. A track the library no longer
  /// has is not lost: the user removed it.
  Future<Set<String>> _lostTrackIds() async {
    final paths = <String, String>{};
    final lost = <String>{};
    for (final record in _records.values) {
      if (record.status != DownloadStatus.completed && !_flaggedLost(record)) {
        continue;
      }
      for (final trackId in record.trackIds) {
        if (!manager.hasTrack(trackId)) continue;
        try {
          paths[trackId] ??= manager.trackPath(trackId);
        } on ArgumentError {
          // Its stored path is outside the music folders: not playable.
          lost.add(trackId);
        }
      }
    }
    final existing = await existingFiles(paths.values, nonEmpty: true);
    return {
      ...lost,
      for (final MapEntry(key: id, value: path) in paths.entries)
        if (!existing.contains(path)) id,
    };
  }
}

bool _sameSource(String a, String b) {
  final key = sourceKey(a);
  return key.isEmpty ? a == b : key == sourceKey(b);
}

/// The song a history entry is for: its media identity, or the URL itself
/// when the URL has none.
String _songKey(String url) {
  final key = sourceKey(url);
  return key.isEmpty ? url : key;
}

/// What a download was requested with: the details its history entry and
/// its library track start from.
class _DownloadMetadata {
  const _DownloadMetadata({
    required this.url,
    required this.title,
    this.uploader = "",
    this.thumbnail = "",
    this.source = youtubeMusicName,
    this.duration = 0,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.resolveMetadata = false,
    this.createdAt,
    this.batchId = "",
    this.batchPosition = 0,
    this.batchSize = 0,
  });

  /// A search result, with the details YouTube Music listed for it.
  factory _DownloadMetadata.fromResult(SearchResult result) =>
      _DownloadMetadata(
        url: _canonicalSource(result.url),
        title: result.title,
        uploader: result.uploader,
        thumbnail: result.thumbnail,
        source: result.source,
        duration: result.duration,
      );

  /// A bare URL, under a placeholder [title] until yt-dlp reports the
  /// song's own details.
  factory _DownloadMetadata.url(
    String url, {
    required String title,
    double? createdAt,
    String batchId = "",
    int batchPosition = 0,
    int batchSize = 0,
  }) => _DownloadMetadata(
    url: _canonicalSource(url),
    title: title,
    resolveMetadata: true,
    createdAt: createdAt,
    batchId: batchId,
    batchPosition: batchPosition,
    batchSize: batchSize,
  );

  /// A new attempt at [original], with the details it already has.
  factory _DownloadMetadata.retrying(DownloadRecord original) {
    final batched = original.batchId.isNotEmpty;
    return _DownloadMetadata(
      url: _canonicalSource(original.url),
      title: original.title,
      uploader: original.uploader,
      thumbnail: original.thumbnail,
      source: original.source,
      progress: original.progress,
      downloadedBytes: original.downloadedBytes,
      totalBytes: original.totalBytes,
      // URL batches start with placeholder titles that yt-dlp replaces.
      resolveMetadata: batched,
      // A batch song keeps its place and count in its batch.
      createdAt: batched ? original.createdAt : null,
      batchId: original.batchId,
      batchPosition: batched ? original.batchPosition : 0,
      batchSize: batched ? original.batchSize : 0,
    );
  }

  final String url;
  final String title;
  final String uploader;
  final String thumbnail;

  /// The service shown as the track's source.
  final String source;

  /// In seconds; 0 when unknown.
  final double duration;

  /// How far earlier attempts got.
  final double progress;
  final int downloadedBytes;
  final int totalBytes;

  /// Whether the title, uploader, and artwork yt-dlp reports replace these.
  final bool resolveMetadata;

  /// Seconds since the Unix epoch; null for now.
  final double? createdAt;
  final String batchId;
  final int batchPosition;
  final int batchSize;

  DownloadRecord toRecord(String id) => DownloadRecord(
    id: id,
    url: url,
    title: title,
    uploader: uploader,
    thumbnail: thumbnail,
    source: source,
    progress: progress,
    downloadedBytes: downloadedBytes,
    totalBytes: totalBytes,
    createdAt: createdAt,
    batchId: batchId,
    batchPosition: batchPosition,
    batchSize: batchSize,
  );
}
