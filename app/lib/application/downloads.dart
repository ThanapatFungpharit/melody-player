import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../core/downloader/downloader.dart";
import "../core/downloader/receipts.dart";
import "../core/errors.dart";
import "../core/library/manager.dart";
import "../core/library/models.dart";
import "../core/media.dart";
import "../worker/worker_client.dart";
import "models.dart";
import "store.dart";
import "thumbnails.dart";

final _downloadUrlPattern = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);

/// Unique HTTP(S) URLs from lines, bullets, or pasted prose.
List<String> extractDownloadUrls(String value) {
  final seen = <String>{};
  return [
    for (final match in _downloadUrlPattern.allMatches(value))
      if (match.group(0)!.replaceAll(RegExp(r"[.,;]+$"), "") case final url
          when url.isNotEmpty && seen.add(url))
        url,
  ];
}

class DuplicateDownloadError implements Exception {
  @override
  String toString() => "This track is already downloading.";
}

/// A group of independently scheduled song downloads.
class DownloadBatch {
  const DownloadBatch(this.id, this.tasks, this.size);

  final String id;
  final List<String> tasks;
  final int size;
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
      "preferredcodec": settings.audioFormat,
      "preferredquality": settings.audioQuality == "best" ? "0" : settings.audioQuality,
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

double _now() => DateTime.now().microsecondsSinceEpoch / 1e6;

/// Turns downloader jobs into persistent, library-aware operations.
///
/// Worker callbacks can arrive many times per second. Notification and
/// durable-history intervals cap that work, while terminal state changes are
/// written and published immediately.
class DownloadCoordinator extends ChangeNotifier {
  DownloadCoordinator._(
    this.manager,
    this.store,
    this.settings,
    this.thumbnails,
    this._downloader,
  );

  static const progressNotifyInterval = Duration(milliseconds: 200);
  static const progressPersistInterval = Duration(seconds: 1);
  static const maxRetainedRecords = 250;
  static const activeStatuses = {"queued", "downloading", "processing"};

  final MusicManager manager;
  final ApplicationStore store;
  final AppSettings settings;
  final ThumbnailCache? thumbnails;
  final Downloader _downloader;
  final Map<String, DownloadRecord> _records = {};
  final Map<String, String> _activeBySource = {};
  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastNotify = Duration.zero;
  Duration _lastPersist = Duration.zero;

  /// Called with each published record change (terminal ones included).
  void Function(DownloadRecord record)? onRecord;

  static Future<DownloadCoordinator> open(
    MusicManager manager,
    ApplicationStore store,
    AppSettings settings,
    WorkerClient worker, {
    ThumbnailCache? thumbnails,
    Map<String, Object?> sharedOptions = const {},
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
        audioExtensions: {".${settings.audioFormat.toLowerCase()}"},
        options: downloadOptions(settings, sharedOptions),
      ),
    );
    await coordinator._recover();
    return coordinator;
  }

  Future<void> _recover() async {
    for (final record in store.downloads()) {
      _records[record.id] = record;
    }
    await _recoverHandoffs();
    var recovered = false;
    for (final record in _records.values) {
      if (record.status == "completed" &&
          record.trackIds.isNotEmpty &&
          !record.trackIds.every(_trackFileAvailable)) {
        recovered = true;
        record
          ..status = "failed"
          ..error = "The downloaded library file is missing. Retry to restore it."
          ..errorKind = "disk"
          ..recovery = "retry";
      }
      if (activeStatuses.contains(record.status)) {
        recovered = true;
        record
          ..status = "failed"
          ..error = "The application closed before this download finished. Retry it.";
      }
    }
    if (recovered) _persist();
  }

  /// Newest first.
  List<DownloadRecord> list() {
    final records = [for (final record in _records.values) record.copy()];
    records.sort((a, b) {
      final created = b.createdAt.compareTo(a.createdAt);
      return created != 0 ? created : a.batchPosition.compareTo(b.batchPosition);
    });
    return records;
  }

  DownloadRecord? get(String recordId) => _records[recordId]?.copy();

  int activeCount() => _activeBySource.length;

  bool isSourceActive(String url) => _activeBySource.containsKey(sourceKey(url));

  /// The canonical intact library track for [url], if one exists.
  Future<Track?> availableTrack(String url) async {
    if (url.isEmpty) return null;
    final existing = manager.findTrackBySource(url);
    if (existing == null) return null;
    try {
      return await manager.checkTrackIntegrity(existing.id) == null ? existing : null;
    } on Object {
      return null;
    }
  }

  /// Reuses an existing track or active job before scheduling new work.
  /// Returns null when the media is already in the library.
  Future<String?> request(SearchResult result) async =>
      (await requestWithOwnership(result)).$1;

  /// Like [request], and reports whether this call created the task, so a
  /// caller can cancel only work it owns.
  Future<(String?, bool)> requestWithOwnership(SearchResult result) {
    if (result.url.isEmpty) {
      throw ArgumentError("This result does not provide a downloadable URL.");
    }
    return _requestWithOwnership({
      "url": result.url,
      "title": result.title,
      "uploader": result.uploader,
      "thumbnail": result.thumbnail,
      "source": result.source,
      "kind": result.kind,
      "duration": result.duration,
    });
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
    final createdAt = _now();
    final keys = <String>{};
    final unique = [
      for (final source in sources)
        if (sourceKey(source) case final key when key.isEmpty || keys.add(key)) source,
    ];
    final tasks = <String>[];
    for (final (index, source) in unique.indexed) {
      final metadata = <String, Object?>{
        ..._urlMetadata(source, title: "Song ${index + 1} of ${unique.length}"),
        "batch_id": batchId,
        "batch_position": index + 1,
        "batch_size": unique.length,
        "created_at": createdAt,
      };
      try {
        final (task, _) = await _requestWithOwnership(metadata);
        if (task != null) tasks.add(task);
      } catch (error) {
        // Record this song's scheduling failure, then continue the batch.
        debugPrint("Batch download could not be scheduled: $source: $error");
        _recordStartFailure(metadata, error);
      }
    }
    return DownloadBatch(batchId, tasks, unique.length);
  }

  Future<(String?, bool)> _requestWithOwnership(Map<String, Object?> metadata) async {
    final url = "${metadata["url"] ?? ""}";
    if (url.isEmpty) throw ArgumentError("A $youtubeMusicName URL is required.");
    if (!isYoutubeUrl(url)) {
      throw ArgumentError("Only $youtubeMusicName URLs are supported.");
    }
    if (metadata["kind"] != "playlist" && await availableTrack(url) != null) {
      return (null, false);
    }
    final active = _activeRecordForSource(url);
    if (active != null) return (active.id, false);
    return (_start(metadata), true);
  }

  String _start(Map<String, Object?> metadata) {
    final url = "${metadata["url"]}";
    if (!isYoutubeUrl(url)) {
      throw ArgumentError("Only $youtubeMusicName URLs are supported.");
    }
    if (_activeRecordForSource(url) != null) throw DuplicateDownloadError();
    String? task;
    task = _downloader.start(
      url,
      onProgress: (progress) {
        if (task != null) _handleProgress(progress, metadata);
      },
      onComplete: (result) => unawaited(_handleComplete(result, metadata)),
    );
    // Register the source before returning so a second request in the gap
    // before the first progress callback joins this task.
    _ensureRecord(task, metadata);
    _persist();
    return task;
  }

  bool cancel(String recordId) => _downloader.cancel(recordId);

  Future<String> retry(String recordId) async {
    final original = _records[recordId];
    if (original == null) throw ArgumentError("Download history entry was not found.");
    return _start({
      "url": original.url,
      "title": original.title,
      "uploader": original.uploader,
      "thumbnail": original.thumbnail,
      "source": original.source,
      "kind": original.kind,
      "duration": 0.0,
    });
  }

  void clearFinished() {
    _records.removeWhere((_, record) => !activeStatuses.contains(record.status));
    _persist();
    notifyListeners();
  }

  void shutdown() => _downloader.shutdown(cancelPending: true);

  void _handleProgress(DownloadProgress progress, Map<String, Object?> metadata) {
    final record = _ensureRecord(progress.task, metadata);
    final previous = record.status;
    record
      ..status = progress.status == DownloadStatus.completed
          ? "processing"
          : progress.status.name
      ..progress = progress.progress
      ..filename = progress.filename.isEmpty ? "" : p.basename(progress.filename)
      ..downloadedBytes = progress.downloadedBytes
      ..totalBytes = progress.totalBytes
      ..error = friendlyDownloadError(progress.error);
    if (metadata["resolve_metadata"] == true) {
      if (progress.mediaTitle.isNotEmpty) record.title = progress.mediaTitle;
      if (progress.uploader.isNotEmpty) record.uploader = progress.uploader;
      if (progress.thumbnail.isNotEmpty) record.thumbnail = progress.thumbnail;
    }
    // A terminal snapshot is followed by the completion handler.
    if (const {"failed", "cancelled"}.contains(record.status)) return;
    final now = _clock.elapsed;
    final changed = record.status != previous;
    if (changed || now - _lastPersist >= progressPersistInterval) {
      _persist();
      _lastPersist = now;
    }
    if (changed || now - _lastNotify >= progressNotifyInterval) {
      _lastNotify = now;
      _publish(record);
    }
  }

  Future<void> _handleComplete(DownloadResult result, Map<String, Object?> metadata) async {
    final record = _ensureRecord(result.task, metadata);
    var status = result.status.name;
    var error = result.failure?.message ?? friendlyDownloadError(result.error);
    List<String>? imported;
    String? storedName;
    if (result.status == DownloadStatus.completed) {
      imported = [];
      final storedPaths = <String>[];
      try {
        await _cacheThumbnail(record.thumbnail, result.artwork);
        for (final path in result.files) {
          final (trackId, stored) = await _importDownloadedFile(
            path,
            metadata,
            uploader: record.uploader,
            thumbnail: record.thumbnail,
          );
          imported.add(trackId);
          storedPaths.add(stored);
        }
        if (storedPaths.isNotEmpty) storedName = p.basename(storedPaths.first);
      } catch (failure) {
        debugPrint("Downloaded media could not be imported: $failure");
        status = "failed";
        error = "Downloaded, but could not add to the library: $failure";
        imported = null;
      }
    }
    record
      ..status = status
      ..error = error
      ..errorKind = result.failure?.kind.value ?? ""
      ..recovery = result.failure?.recovery ?? "";
    if (imported != null) {
      record
        ..progress = 1.0
        ..trackIds = imported
        ..completedAt = _now();
      if (storedName != null) record.filename = storedName;
    }
    final identity = sourceKey(record.url);
    if (_activeBySource[identity] == record.id) _activeBySource.remove(identity);
    _prune();
    _persist();
    if (record.status == "completed") {
      try {
        final receipt = File(receiptPath(settings.downloadDirectory, result.task));
        if (await receipt.exists()) await receipt.delete();
      } on FileSystemException catch (failure) {
        debugPrint("Could not acknowledge completed download receipt: $failure");
      }
    }
    _publish(record);
  }

  /// Caches artwork verified in the media file; the file stays canonical.
  Future<void> _cacheThumbnail(String url, Uint8List? artwork) async {
    final cache = thumbnails;
    if (cache == null || url.isEmpty || artwork == null || artwork.isEmpty) return;
    try {
      await cache.storeBytes(url, artwork);
    } on Object catch (error) {
      debugPrint("Could not cache downloaded thumbnail: $error");
    }
  }

  /// Finishes downloads whose bytes survived but whose registration was
  /// interrupted. Ambiguous receipts stay for repair; unrelated files in the
  /// music folder are never adopted.
  Future<void> _recoverHandoffs() async {
    final directory = Directory(settings.downloadDirectory);
    if (!await directory.exists()) return;
    final receipts = [
      await for (final entity in directory.list())
        if (entity is File &&
            p.basename(entity.path).startsWith(".melody-download-") &&
            entity.path.endsWith(".json"))
          entity,
    ];
    for (final file in receipts) {
      try {
        final receipt = await readReceipt(file.path);
        final existing = _records[receipt.taskId];
        final metadata = _urlMetadata(
          receipt.url,
          title: existing?.title ?? p.basenameWithoutExtension(receipt.files.first),
        );
        final trackIds = <String>[];
        for (final path in receipt.files) {
          final (trackId, _) = await _importDownloadedFile(
            path,
            metadata,
            uploader: existing?.uploader ?? "",
            thumbnail: existing?.thumbnail ?? "",
          );
          trackIds.add(trackId);
        }
        final record = _ensureRecord(receipt.taskId, metadata);
        record
          ..status = "completed"
          ..progress = 1.0
          ..error = ""
          ..errorKind = ""
          ..recovery = ""
          ..trackIds = trackIds
          ..completedAt = _now()
          ..filename = p.basename(manager.trackPath(trackIds.first));
        _activeBySource.remove(sourceKey(receipt.url));
        _persist();
        await file.delete();
      } on Object catch (error) {
        debugPrint("Could not reconcile download receipt ${file.path}: $error");
      }
    }
  }

  /// Registers audio or reuses its library identity, keeping existing metadata.
  Future<(String, String)> _importDownloadedFile(
    String path,
    Map<String, Object?> metadata, {
    required String uploader,
    required String thumbnail,
  }) => manager.mutation.run(() async {
    final source = "${metadata["url"]}";
    final details = TrackDetails(
      uploader: uploader,
      duration: switch (metadata["duration"]) {
        num value => value.toDouble(),
        _ => 0,
      },
      thumbnail: thumbnail,
      sourceName: "${metadata["source"] ?? youtubeMusicName}",
    );
    final existing =
        manager.findTrackBySource(source) ?? await manager.findTrackByContent(path);
    if (existing != null) {
      if (!store.hasTrackDetails(existing.id)) store.saveTrackDetails(existing.id, details);
      return (existing.id, await _reuseLibraryTrack(existing, path, source));
    }
    final title = "${metadata["title"] ?? ""}";
    final trackId = await manager.addTrack(
      path,
      source: source,
      title: title.isNotEmpty ? title : p.basenameWithoutExtension(path),
    );
    store.saveTrackDetails(trackId, details);
    return (trackId, manager.trackPath(trackId));
  });

  /// Keeps intact audio, or repairs the file without replacing the record.
  Future<String> _reuseLibraryTrack(Track track, String path, String source) async {
    final previousPath = manager.trackPath(track.id);
    final problem = await manager.checkTrackIntegrity(track.id);
    String stored;
    if (problem == null) {
      stored = previousPath;
      if (!p.equals(p.absolute(path), p.absolute(stored))) await File(path).delete();
    } else {
      await manager.replaceTrackFile(track.id, path);
      stored = manager.trackPath(track.id);
      if (!p.equals(p.absolute(previousPath), p.absolute(stored))) {
        try {
          if (!manager.isPathReferenced(previousPath)) {
            final previous = File(previousPath);
            if (await previous.exists()) await previous.delete();
          }
        } on FileSystemException catch (error) {
          debugPrint("Could not remove the superseded library file: $error");
        }
      }
    }
    if (track.source.isEmpty) manager.updateTrack(track.id, source: source);
    return stored;
  }

  DownloadRecord _ensureRecord(String task, Map<String, Object?> metadata) {
    final record = _records.putIfAbsent(task, () => _recordFromMetadata(task, metadata));
    _prune();
    final identity = sourceKey(record.url);
    if (identity.isNotEmpty && activeStatuses.contains(record.status)) {
      _activeBySource[identity] = record.id;
    }
    return record;
  }

  void _recordStartFailure(Map<String, Object?> metadata, Object error) {
    final record = _recordFromMetadata(const Uuid().v4(), metadata)
      ..status = "failed"
      ..error = friendlyDownloadError("$error")
      ..completedAt = _now();
    _records[record.id] = record;
    _prune();
    _persist();
    _publish(record);
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
        _records.values.where((record) => !activeStatuses.contains(record.status)).toList()
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

  /// Cheap startup availability; full hashes remain explicit checks.
  bool _trackFileAvailable(String trackId) {
    try {
      final status = File(manager.trackPath(trackId)).statSync();
      return status.type == FileSystemEntityType.file && status.size > 0;
    } on Object {
      return false;
    }
  }
}

Map<String, Object?> _urlMetadata(String url, {required String title}) => {
  "url": url,
  "title": title,
  "uploader": "",
  "thumbnail": "",
  "source": youtubeMusicName,
  "kind": "track",
  "duration": 0.0,
  "resolve_metadata": true,
};

DownloadRecord _recordFromMetadata(String id, Map<String, Object?> metadata) =>
    DownloadRecord(
      id: id,
      url: "${metadata["url"]}",
      title: "${metadata["title"]}",
      uploader: "${metadata["uploader"] ?? ""}",
      thumbnail: "${metadata["thumbnail"] ?? ""}",
      source: "${metadata["source"] ?? youtubeMusicName}",
      kind: "${metadata["kind"] ?? "track"}",
      createdAt: switch (metadata["created_at"]) {
        num value => value.toDouble(),
        _ => null,
      },
      batchId: "${metadata["batch_id"] ?? ""}",
      batchPosition: switch (metadata["batch_position"]) { int value => value, _ => 0 },
      batchSize: switch (metadata["batch_size"]) { int value => value, _ => 0 },
    );
