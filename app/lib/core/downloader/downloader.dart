/// Background audio downloading, independent of music-library storage.
library;

import "dart:async";
import "dart:io";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../../worker/worker_client.dart";
import "../artwork.dart";
import "../errors.dart";
import "../storage.dart";
import "receipts.dart";

enum DownloadStatus { queued, downloading, processing, completed, failed, cancelled }

const _thumbnailExtensions = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"};
const _maxThumbnailBytes = 8 * 1024 * 1024;

/// A point-in-time view of a download.
class DownloadProgress {
  const DownloadProgress({
    required this.task,
    required this.url,
    required this.status,
    this.progress = 0,
    this.filename = "",
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.error = "",
    this.mediaTitle = "",
    this.uploader = "",
    this.thumbnail = "",
  });

  final String task;
  final String url;
  final DownloadStatus status;
  final double progress;
  final String filename;
  final int downloadedBytes;
  final int totalBytes;
  final String error;
  final String mediaTitle;
  final String uploader;
  final String thumbnail;

  DownloadProgress copyWith({
    DownloadStatus? status,
    double? progress,
    String? filename,
    int? downloadedBytes,
    int? totalBytes,
    String? error,
    String? mediaTitle,
    String? uploader,
    String? thumbnail,
  }) => DownloadProgress(
    task: task,
    url: url,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    filename: filename ?? this.filename,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    error: error ?? this.error,
    mediaTitle: mediaTitle ?? this.mediaTitle,
    uploader: uploader ?? this.uploader,
    thumbnail: thumbnail ?? this.thumbnail,
  );
}

/// The terminal outcome of one download. [artwork] is read back from the
/// completed media container so caches never become the authoritative copy.
class DownloadResult {
  const DownloadResult({
    required this.task,
    required this.url,
    required this.status,
    this.files = const [],
    this.error = "",
    this.failure,
    this.artwork,
  });

  final String task;
  final String url;
  final DownloadStatus status;
  final List<String> files;
  final String error;
  final DownloadFailure? failure;
  final Uint8List? artwork;
}

/// The downloader cannot accept another job right now.
class WorkerQueueFull implements Exception {
  WorkerQueueFull(this.capacity);

  final int capacity;

  @override
  String toString() =>
      "Background work limit reached ($capacity tasks); retry shortly.";
}

class _Cancelled implements Exception {}

class _Job {
  _Job(this.progress, this.onProgress, this.onComplete);

  DownloadProgress progress;
  final void Function(DownloadProgress)? onProgress;
  final void Function(DownloadResult)? onComplete;
  bool cancelled = false;
  bool started = false;
  DownloadResult? result;
}

/// Runs yt-dlp jobs through the worker with bounded concurrency.
///
/// The downloader owns only staging files. Completed files are moved into
/// [outputDirectory] behind a checksum receipt; callers decide whether to
/// register them and acknowledge the receipt.
class Downloader {
  Downloader(
    this._worker,
    this.outputDirectory, {
    int maxWorkers = 4,
    int? maxPending,
    Set<String> audioExtensions = const {".mp3"},
    this.options = const {},
  }) : _maxWorkers = max(1, maxWorkers),
       _capacity = max(1, maxWorkers) + (maxPending ?? max(1, maxWorkers)),
       _audioExtensions = {for (final item in audioExtensions) item.toLowerCase()} {
    Directory(outputDirectory).createSync(recursive: true);
  }

  final WorkerClient _worker;
  final String outputDirectory;
  final int _maxWorkers;
  final int _capacity;
  final Set<String> _audioExtensions;
  /// yt-dlp options applied to every job.
  final Map<String, Object?> options;
  final Map<String, _Job> _jobs = {};
  final List<String> _queue = [];
  final Set<String> _reservedNames = {};
  int _running = 0;
  int _inFlight = 0;
  bool _shutdown = false;

  /// Starts a download and returns its task id immediately.
  String start(
    String url, {
    void Function(DownloadProgress)? onProgress,
    void Function(DownloadResult)? onComplete,
  }) {
    final source = url.trim();
    if (source.isEmpty) throw ArgumentError("A download URL is required");
    if (_shutdown) throw StateError("The downloader has been shut down");
    if (_inFlight >= _capacity) throw WorkerQueueFull(_capacity);
    final task = const Uuid().v4();
    final job = _Job(
      DownloadProgress(task: task, url: source, status: DownloadStatus.queued),
      onProgress,
      onComplete,
    );
    _jobs[task] = job;
    _inFlight++;
    _queue.add(task);
    _notify(job);
    scheduleMicrotask(_pump);
    return task;
  }

  /// Requests cancellation. Returns false for a terminal or unknown task.
  bool cancel(String task) {
    final job = _jobs[task];
    if (job == null || job.result != null) return false;
    job.cancelled = true;
    if (!job.started) {
      _queue.remove(task);
      _finish(job, DownloadStatus.cancelled);
    } else {
      unawaited(_worker.cancel(task).catchError((Object _) {}));
    }
    return true;
  }

  void shutdown({bool cancelPending = false}) {
    _shutdown = true;
    if (!cancelPending) return;
    for (final task in _jobs.keys.toList()) {
      cancel(task);
    }
  }

  void _pump() {
    while (_running < _maxWorkers && _queue.isNotEmpty) {
      final job = _jobs[_queue.removeAt(0)]!;
      job.started = true;
      _running++;
      unawaited(
        _run(job).whenComplete(() {
          _running--;
          _pump();
        }),
      );
    }
  }

  Future<void> _run(_Job job) async {
    var files = <String>[];
    Uint8List? artwork;
    try {
      _raiseIfCancelled(job);
      _update(job, job.progress.copyWith(status: DownloadStatus.downloading));
      (files, artwork) = await _downloadOne(job);
      _raiseIfCancelled(job);
    } on _Cancelled {
      await _removeFiles(files);
      _finish(job, DownloadStatus.cancelled);
      return;
    } catch (error) {
      debugPrint("Download failed: ${job.progress.url}: $error");
      await _removeFiles(files);
      _finish(job, DownloadStatus.failed, error: error);
      return;
    }
    _finish(job, DownloadStatus.completed, files: files, artwork: artwork);
  }

  Future<(List<String>, Uint8List?)> _downloadOne(_Job job) async {
    final staging = await Directory(outputDirectory).createTemp(".melody-download-");
    try {
      final completed = await _worker.download(
        task: job.progress.task,
        url: job.progress.url,
        directory: staging.path,
        options: options,
        onProgress: (progress) => _onWorkerProgress(job, progress),
      );
      if (!completed) throw _Cancelled();
      _raiseIfCancelled(job);
      final sidecar = await _readDownloadedThumbnail(staging);
      final artwork = await _verifiedEmbeddedArtwork(
        staging,
        artworkExpected: sidecar.isNotEmpty || job.progress.thumbnail.trim().isNotEmpty,
      );
      final files = await _moveDownloadedFiles(job, staging);
      if (files.isEmpty) {
        throw DownloadError("The download did not produce an audio file");
      }
      return (files, artwork.isEmpty ? null : artwork);
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException catch (error) {
        debugPrint("Could not remove download staging: $error");
      }
    }
  }

  void _onWorkerProgress(_Job job, WorkerProgress data) {
    if (job.cancelled || job.result != null) return;
    final total = data.totalBytes;
    _update(
      job,
      job.progress.copyWith(
        status: data.status == "processing"
            ? DownloadStatus.processing
            : DownloadStatus.downloading,
        progress: total > 0 ? (data.downloadedBytes / total).clamp(0.0, 1.0) : 0.0,
        filename: data.filename,
        downloadedBytes: data.downloadedBytes,
        totalBytes: total,
        mediaTitle: data.title,
        uploader: data.uploader,
        thumbnail: data.thumbnail,
      ),
    );
  }

  /// The sidecar yt-dlp retained after embedding, for verification.
  Future<Uint8List> _readDownloadedThumbnail(Directory staging) async {
    File? largest;
    var largestSize = 0;
    try {
      await for (final entity in staging.list()) {
        if (entity is! File ||
            !_thumbnailExtensions.contains(p.extension(entity.path).toLowerCase())) {
          continue;
        }
        final size = await entity.length();
        if (size > 0 && size <= _maxThumbnailBytes && size > largestSize) {
          largest = entity;
          largestSize = size;
        }
      }
      return largest == null ? Uint8List(0) : await largest.readAsBytes();
    } on FileSystemException {
      return Uint8List(0);
    }
  }

  /// Reads back burned cover art before any completed media is committed.
  Future<Uint8List> _verifiedEmbeddedArtwork(
    Directory staging, {
    required bool artworkExpected,
  }) async {
    final embedded = <Uint8List>[];
    final missing = <String>[];
    await for (final entity in staging.list()) {
      if (entity is! File ||
          !_audioExtensions.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      final artwork = await readEmbeddedArtwork(entity.path);
      if (artwork.isNotEmpty) {
        embedded.add(artwork);
      } else if (artworkExpected) {
        missing.add(p.basename(entity.path));
      }
    }
    if (missing.isNotEmpty) {
      throw DownloadError(
        "Thumbnail artwork was available, but it was not embedded in the "
        "media file: ${(missing..sort()).join(", ")}",
      );
    }
    return embedded.fold<Uint8List>(
      Uint8List(0),
      (best, item) => item.length > best.length ? item : best,
    );
  }

  Future<List<String>> _moveDownloadedFiles(_Job job, Directory staging) async {
    final files = <String>[];
    final entries = <Map<String, String>>[];
    try {
      await for (final entity in staging.list()) {
        _raiseIfCancelled(job);
        if (entity is! File ||
            !_audioExtensions.contains(p.extension(entity.path).toLowerCase())) {
          continue;
        }
        if (await entity.length() <= 0) {
          throw DownloadError(
            "The download produced an empty audio file: ${p.basename(entity.path)}",
          );
        }
        final destination = _reserveDestination(p.basename(entity.path));
        try {
          entries.add({
            "filename": p.basename(destination),
            "sha256": await sha256File(entity.path),
          });
          await writeReceipt(outputDirectory, job.progress.task, job.progress.url, entries);
          await entity.rename(destination);
        } finally {
          // Once moved, the file itself prevents collisions.
          _reservedNames.remove(destination);
        }
        files.add(destination);
      }
    } catch (_) {
      await _removeFiles(files);
      rethrow;
    }
    return files;
  }

  String _reserveDestination(String name) {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var destination = p.join(outputDirectory, name);
    var counter = 1;
    while (File(destination).existsSync() || _reservedNames.contains(destination)) {
      counter++;
      destination = p.join(outputDirectory, "$stem ($counter)$extension");
    }
    _reservedNames.add(destination);
    return destination;
  }

  void _update(_Job job, DownloadProgress progress) {
    if (job.result != null) return;
    job.progress = progress;
    _notify(job);
  }

  void _finish(
    _Job job,
    DownloadStatus status, {
    List<String> files = const [],
    Object? error,
    Uint8List? artwork,
  }) {
    if (job.result != null) return;
    // Cancellation accepted before completion wins and owns cleanup.
    if (job.cancelled && status != DownloadStatus.cancelled) {
      unawaited(_removeFiles(files));
      status = DownloadStatus.cancelled;
      files = const [];
      error = null;
    }
    if (status != DownloadStatus.completed) {
      unawaited(_removeFiles([receiptPath(outputDirectory, job.progress.task)]));
    }
    final message = error == null ? "" : "$error";
    job.progress = job.progress.copyWith(
      status: status,
      progress: status == DownloadStatus.completed ? 1.0 : job.progress.progress,
      error: message,
    );
    job.result = DownloadResult(
      task: job.progress.task,
      url: job.progress.url,
      status: status,
      files: files,
      error: message,
      failure: status == DownloadStatus.failed ? classifyDownloadError(error ?? message) : null,
      artwork: status == DownloadStatus.completed ? artwork : null,
    );
    _inFlight--;
    _jobs.remove(job.progress.task);
    _notify(job);
    try {
      job.onComplete?.call(job.result!);
    } catch (error) {
      debugPrint("Download completion callback failed: $error");
    }
  }

  static void _raiseIfCancelled(_Job job) {
    if (job.cancelled) throw _Cancelled();
  }

  static Future<void> _removeFiles(List<String> files) async {
    for (final path in files) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException catch (error) {
        // Best effort: a locked output must not hide the real outcome.
        debugPrint("Could not remove incomplete download output $path: $error");
      }
    }
  }

  static void _notify(_Job job) {
    try {
      job.onProgress?.call(job.progress);
    } catch (error) {
      debugPrint("Download progress callback failed: $error");
    }
  }
}
