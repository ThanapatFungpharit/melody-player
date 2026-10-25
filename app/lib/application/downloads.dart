import "dart:async";
import "dart:io";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../core/downloader/downloader.dart";
import "../core/downloader/receipts.dart";
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
  "quiet": true,
  "noprogress": true,
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

/// Turns downloader jobs into persistent, library-aware operations.
///
/// Worker callbacks can arrive many times per second. Listeners hear about
/// byte progress at most every [progressNotifyInterval]; status changes are
/// written and published immediately. Byte progress is never persisted: a
/// download still active at startup is reported as interrupted.
class DownloadCoordinator extends ChangeNotifier {
  DownloadCoordinator._(
    this.manager,
    this.store,
    this.settings,
    this.thumbnails,
    this._downloader,
    this.lyrics,
  );

  static const progressNotifyInterval = Duration(milliseconds: 200);
  static const maxRetainedRecords = ApplicationStore.maxDownloadRecords;

  final MusicManager manager;
  final ApplicationStore store;
  final AppSettings settings;
  final ThumbnailCache? thumbnails;
  final Downloader _downloader;
  late final OwnedFiles _files = OwnedFiles(store, manager);

  /// Supplies lyrics to embed in downloaded files.
  final LyricsLibrary? lyrics;
  final Map<String, DownloadRecord> _records = {};
  final Map<String, String> _activeBySource = {};
  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastNotify = Duration.zero;

  /// Called with each published record change (terminal ones included).
  void Function(DownloadRecord record)? onRecord;

  static Future<DownloadCoordinator> open(
    MusicManager manager,
    ApplicationStore store,
    AppSettings settings,
    WorkerClient worker, {
    ThumbnailCache? thumbnails,
    LyricsLibrary? lyrics,
    Map<String, Object?> sharedOptions = const {},
    required String stagingDirectory,
    required String receiptDirectory,
  }) async {
    final coordinator = DownloadCoordinator._(
      manager,
      store,
      settings,
      thumbnails,
      Downloader(
        worker,
        settings.downloadDirectory,
        maxWorkers: settings.concurrentDownloads,
        audioExtensions: {settings.downloadFormat.extension},
        options: downloadOptions(settings, sharedOptions),
        stagingDirectory: stagingDirectory,
        receiptDirectory: receiptDirectory,
      ),
      lyrics,
    );
    await coordinator._recover();
    return coordinator;
  }

  Future<void> _recover() async {
    for (final record in store.downloads()) {
      _records[record.id] = record;
    }
    // Before any job starts, so only earlier processes' directories qualify.
    final abandoned = await _downloader.removeAbandonedStaging();
    if (abandoned > 0) {
      debugPrint("Removed $abandoned abandoned download staging folder(s)");
    }
    await _recoverHandoffs();
    final available = await _availableTrackIds();
    var recovered = false;
    for (final record in _records.values) {
      if (record.status == DownloadStatus.completed &&
          record.trackIds.isNotEmpty &&
          !record.trackIds.every(available.contains)) {
        recovered = true;
        record
          ..status = DownloadStatus.failed
          ..error =
              "The downloaded library file is missing. Retry to restore it."
          ..errorKind = "disk"
          ..recovery = "retry";
      }
      if (record.status.isActive) {
        recovered = true;
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

  /// Days a finished download stays in the history; 0 keeps it forever.
  int get historyDays => _historyDays;
  late int _historyDays = settings.downloadHistoryDays;

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

  /// The canonical intact library track for [url], if one exists.
  Future<Track?> availableTrack(String url) async {
    if (url.isEmpty) return null;
    final existing = manager.findTrackBySource(url);
    if (existing == null) return null;
    try {
      return await manager.checkTrackIntegrity(existing.id) == null
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
    if (metadata.kind != "playlist") {
      if (await availableTrack(url) case final track?) {
        return DownloadRequest.existing(track);
      }
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

  bool cancel(String recordId) => _downloader.cancel(recordId);

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

  void shutdown() => _downloader.shutdown(cancelPending: true);

  void _handleProgress(DownloadProgress progress, _DownloadMetadata metadata) {
    final record = _ensureRecord(progress.task, metadata);
    final previous = record.status;
    record
      ..status = progress.status == DownloadStatus.completed
          ? DownloadStatus.processing
          : progress.status
      ..progress = progress.progress
      ..filename = progress.filename.isEmpty
          ? ""
          : p.basename(progress.filename)
      ..downloadedBytes = progress.downloadedBytes
      ..totalBytes = progress.totalBytes
      ..error = friendlyDownloadError(progress.error);
    if (metadata.resolveMetadata) {
      if (progress.mediaTitle.isNotEmpty) record.title = progress.mediaTitle;
      if (progress.uploader.isNotEmpty) record.uploader = progress.uploader;
      if (progress.thumbnail.isNotEmpty) record.thumbnail = progress.thumbnail;
    }
    // A terminal snapshot is followed by the completion handler.
    if (record.status.isUnsuccessful) return;
    final now = _clock.elapsed;
    final changed = record.status != previous;
    if (changed) _persist();
    if (changed || now - _lastNotify >= progressNotifyInterval) {
      _lastNotify = now;
      _publish(record);
    }
  }

  Future<void> _handleComplete(
    DownloadResult result,
    _DownloadMetadata metadata,
  ) async {
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
        await _cacheThumbnail(record.thumbnail, result.artwork);
      } catch (failure) {
        debugPrint("Downloaded media could not be imported: $failure");
        status = DownloadStatus.failed;
        error = "Downloaded, but could not add to the library: $failure";
        imported = null;
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
    if (record.status == DownloadStatus.completed) {
      await deleteQuietly(
        receiptPath(_downloader.receiptDirectory, result.task),
      );
    }
    _publish(record);
  }

  /// Caches artwork verified in the media file; the file stays canonical.
  Future<void> _cacheThumbnail(String url, Uint8List? artwork) async {
    final cache = thumbnails;
    if (cache == null || url.isEmpty || artwork == null || artwork.isEmpty) {
      return;
    }
    try {
      await cache.storeBytes(url, artwork);
    } on Object catch (error) {
      debugPrint("Could not cache downloaded thumbnail: $error");
    }
  }

  /// Finishes downloads whose bytes survived but whose registration was
  /// interrupted, then retires each receipt. Only files that still match
  /// their checksums are adopted; missing or changed ones are left as they
  /// are, and unrelated files in the music folder are never touched. A
  /// receipt is kept only when importing fails, to retry next launch.
  Future<void> _recoverHandoffs() async {
    final directory = Directory(_downloader.receiptDirectory);
    if (!await directory.exists()) return;
    final receipts = [
      await for (final entity in directory.list(followLinks: false))
        if (entity is File &&
            p.extension(entity.path) == ".json" &&
            !isTemporaryFile(p.basename(entity.path)))
          entity,
    ];
    for (final file in receipts) {
      final Receipt receipt;
      try {
        receipt = await readReceipt(file.path);
      } on FormatException catch (error) {
        // It can vouch for no file, so it goes; the files it names stay.
        debugPrint("Discarding unreadable receipt ${file.path}: $error");
        await deleteQuietly(file.path);
        continue;
      } on Object catch (error) {
        debugPrint("Could not read download receipt ${file.path}: $error");
        continue;
      }
      if (receipt.unverified > 0) {
        debugPrint(
          "${receipt.unverified} file(s) of download ${receipt.taskId} are "
          "missing or changed; they are left as they are",
        );
      }
      if (receipt.files.isEmpty) {
        await deleteQuietly(file.path);
        continue;
      }
      try {
        final existing = _records[receipt.taskId];
        final metadata = _DownloadMetadata.url(
          receipt.url,
          title:
              existing?.title ??
              p.basenameWithoutExtension(receipt.files.first),
        );
        final trackIds = <String>[];
        for (final path in receipt.files) {
          final (trackId, _) = await _importDownloadedFile(
            await _intoMusicFolder(path),
            metadata,
            title: metadata.title,
            uploader: existing?.uploader ?? "",
            thumbnail: existing?.thumbnail ?? "",
          );
          trackIds.add(trackId);
        }
        final record = _ensureRecord(receipt.taskId, metadata);
        record
          ..status = DownloadStatus.completed
          ..progress = 1.0
          ..error = ""
          ..errorKind = ""
          ..recovery = ""
          ..trackIds = trackIds
          ..completedAt = unixSeconds()
          ..filename = p.basename(manager.trackPath(trackIds.first));
        _activeBySource.remove(sourceKey(receipt.url));
        _persist();
      } on ArgumentError catch (error) {
        // Can never succeed: retired, and the files stay where they are.
        debugPrint("Retiring download receipt ${file.path}: $error");
      } on Object catch (error) {
        // Such as a disk error: the next launch tries again.
        debugPrint("Could not reconcile download receipt ${file.path}: $error");
        continue;
      }
      await deleteQuietly(file.path);
    }
  }

  /// [path], moved into the music folder first when it is elsewhere: the
  /// music folder changed after the download finished but before its file
  /// was registered.
  Future<String> _intoMusicFolder(String path) =>
      manager.mutation.run(() async {
        if (samePath(p.dirname(path), manager.musicFolder)) return path;
        final target = availablePath(manager.musicFolder, p.basename(path));
        await moveFile(path, target);
        return target;
      });

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

  /// Keeps intact audio, or repairs the file without replacing the record.
  Future<String> _reuseLibraryTrack(
    Track track,
    String path,
    String source,
  ) async {
    final previousPath = manager.trackPath(track.id);
    final problem = await manager.checkTrackIntegrity(track.id);
    String stored;
    if (problem == null) {
      // The library already has this audio intact: the new copy goes.
      stored = previousPath;
      if (!samePath(path, stored)) {
        _files.mark([path]);
        await _files.release([path]);
      }
    } else {
      // The damaged file goes once the track points at the new one, if
      // Melody downloaded it.
      final superseded = [
        if (!samePath(previousPath, path) && LibraryService.ownsFile(track))
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

  /// Completed downloads' tracks whose files exist and are not empty. Cheap
  /// startup availability, checked in one batch off the UI isolate; full
  /// hashes remain explicit checks.
  Future<Set<String>> _availableTrackIds() async {
    final paths = <String, String>{};
    for (final record in _records.values) {
      if (record.status != DownloadStatus.completed) continue;
      for (final trackId in record.trackIds) {
        try {
          paths[trackId] ??= manager.trackPath(trackId);
        } on Object {
          // An unknown track or invalid path counts as unavailable.
        }
      }
    }
    final existing = await existingFiles(paths.values, nonEmpty: true);
    return {
      for (final MapEntry(key: id, value: path) in paths.entries)
        if (existing.contains(path)) id,
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
    this.kind = "track",
    this.duration = 0,
    this.resolveMetadata = false,
    this.createdAt,
    this.batchId = "",
    this.batchPosition = 0,
    this.batchSize = 0,
  });

  /// A search result, with the details YouTube Music listed for it.
  factory _DownloadMetadata.fromResult(SearchResult result) =>
      _DownloadMetadata(
        url: result.url,
        title: result.title,
        uploader: result.uploader,
        thumbnail: result.thumbnail,
        source: result.source,
        kind: result.kind,
        duration: result.duration,
      );

  /// A bare URL, under a placeholder [title] until yt-dlp reports the
  /// song's own details.
  const _DownloadMetadata.url(
    String url, {
    required String title,
    double? createdAt,
    String batchId = "",
    int batchPosition = 0,
    int batchSize = 0,
  }) : this(
         url: url,
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
      url: original.url,
      title: original.title,
      uploader: original.uploader,
      thumbnail: original.thumbnail,
      source: original.source,
      kind: original.kind,
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
  final String kind;

  /// In seconds; 0 when unknown.
  final double duration;

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
    kind: kind,
    createdAt: createdAt,
    batchId: batchId,
    batchPosition: batchPosition,
    batchSize: batchSize,
  );
}
