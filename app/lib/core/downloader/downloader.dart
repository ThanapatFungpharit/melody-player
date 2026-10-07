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
import "../id3_lyrics.dart";
import "../storage.dart";
import "receipts.dart";

/// The lifecycle of one download. The names are persisted in download history.
enum DownloadStatus {
  queued,
  downloading,
  processing,
  completed,
  failed,
  cancelled;

  static DownloadStatus parse(Object? value) =>
      values.firstWhere((status) => status.name == value, orElse: () => queued);

  /// Still waiting, transferring, or converting.
  bool get isActive =>
      this == queued || this == downloading || this == processing;

  bool get isFinished => !isActive;

  /// Finished without a file.
  bool get isUnsuccessful => this == failed || this == cancelled;
}

const _thumbnailExtensions = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"};

/// Staging directories are `<outputDirectory>/.melody-download-<random>`;
/// receipts share the prefix but are files ending in `.json`.
const _stagingPrefix = ".melody-download-";

/// Held with an exclusive lock while a download uses its staging directory,
/// so another Melody process can tell a live directory from an abandoned one.
/// The operating system releases the lock when the process ends.
const _stagingLock = ".melody-staging.lock";

/// A staging directory with no usable lock (made by an earlier release, or
/// on a filesystem without locks) counts as abandoned once nothing in it has
/// changed for this long; an active download keeps writing.
const _unlockedStagingAge = Duration(hours: 1);

/// A download's private staging directory and the lock that marks it live.
class _Staging {
  _Staging(this.directory, this._lock);

  final Directory directory;
  RandomAccessFile? _lock;

  static Future<_Staging> create(String parent) async {
    final directory = await Directory(parent).createTemp(_stagingPrefix);
    RandomAccessFile? lock;
    try {
      lock = await File(
        p.join(directory.path, _stagingLock),
      ).open(mode: FileMode.write);
      await lock.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      // Without a lock the directory is still removed below, or swept by
      // age after a crash.
      debugPrint("Download staging is not locked: $error");
      await lock?.close();
      lock = null;
    }
    return _Staging(directory, lock);
  }

  /// Releases the lock and deletes the directory with everything in it.
  /// Idempotent; a failure only logs, and the next launch sweeps it.
  Future<void> remove() async {
    final lock = _lock;
    _lock = null;
    try {
      await lock?.close();
    } on FileSystemException catch (error) {
      debugPrint("Could not release download staging: $error");
    }
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      debugPrint("Could not remove download staging: $error");
    }
  }
}

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
  _Job(this.progress, this.onProgress, this.onComplete, this.lyrics);

  DownloadProgress progress;
  final void Function(DownloadProgress)? onProgress;
  final void Function(DownloadResult)? onComplete;
  final Future<String?> Function()? lyrics;
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
    this._outputDirectory, {
    int maxWorkers = 4,
    int? maxPending,
    Set<String> audioExtensions = const {".mp3"},
    this.options = const {},
    this.lyricsTimeout = const Duration(seconds: 15),
  }) : _maxWorkers = max(1, maxWorkers),
       _capacity = max(1, maxWorkers) + (maxPending ?? max(1, maxWorkers)),
       _audioExtensions = {
         for (final item in audioExtensions) item.toLowerCase(),
       } {
    Directory(_outputDirectory).createSync(recursive: true);
  }

  final WorkerClient _worker;
  String _outputDirectory;

  /// Where completed files and their receipts are placed.
  String get outputDirectory => _outputDirectory;

  /// Sends later downloads to [directory]. Refused while any job is queued
  /// or running, since a job stages and finishes in one directory.
  void changeOutputDirectory(String directory) {
    if (_inFlight > 0) {
      throw StateError("Downloads are still in progress");
    }
    Directory(directory).createSync(recursive: true);
    _outputDirectory = directory;
  }

  final int _maxWorkers;
  final int _capacity;
  final Set<String> _audioExtensions;

  /// yt-dlp options applied to every job.
  final Map<String, Object?> options;

  /// How long a job waits for its lyrics before downloading without them.
  final Duration lyricsTimeout;
  final Map<String, _Job> _jobs = {};
  final List<String> _queue = [];
  final Set<String> _reservedNames = {};

  /// Staging directories of this downloader's running jobs. POSIX locks do
  /// not exclude their own process, so the sweep skips these by name.
  final Set<String> _activeStaging = {};
  int _running = 0;
  int _inFlight = 0;
  bool _shutdown = false;

  /// Starts a download and returns its task id immediately.
  ///
  /// [lyrics] supplies text (plain or LRC) to embed in the audio file; it is
  /// asked once the job starts. Lyrics are optional: a failure or a slow
  /// answer never fails the download.
  String start(
    String url, {
    void Function(DownloadProgress)? onProgress,
    void Function(DownloadResult)? onComplete,
    Future<String?> Function()? lyrics,
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
      lyrics,
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
    final owned = await _Staging.create(outputDirectory);
    final staging = owned.directory;
    _activeStaging.add(staging.path);
    try {
      // FFmpeg tags MP3 lyrics as a TXXX frame players ignore; those get a
      // proper USLT frame after the download instead, so their lookup runs
      // alongside it. Other formats need the lyrics before FFmpeg runs.
      final tagsMp3 = _audioExtensions.contains(".mp3");
      final lyricsLookup = _lyrics(job);
      final tagLyrics = tagsMp3 ? null : await lyricsLookup;
      _raiseIfCancelled(job);
      final completed = await _worker.download(
        task: job.progress.task,
        url: job.progress.url,
        directory: staging.path,
        options: options,
        metadata: {"lyrics": ?tagLyrics},
        onProgress: (progress) => _onWorkerProgress(job, progress),
      );
      if (!completed) throw _Cancelled();
      _raiseIfCancelled(job);
      if (tagsMp3) {
        final lyrics = await lyricsLookup;
        _raiseIfCancelled(job);
        if (lyrics != null) await _writeMp3Lyrics(staging, lyrics);
      }
      final sidecar = await _readDownloadedThumbnail(staging);
      final artwork = await _verifiedEmbeddedArtwork(
        staging,
        artworkExpected:
            sidecar.isNotEmpty || job.progress.thumbnail.trim().isNotEmpty,
      );
      final files = await _moveDownloadedFiles(job, staging);
      if (files.isEmpty) {
        throw DownloadError("The download did not produce an audio file");
      }
      return (files, artwork.isEmpty ? null : artwork);
    } finally {
      // Every outcome (completion, failure, cancellation) ends here; only a
      // process that dies first leaves the directory for the startup sweep.
      await owned.remove();
      _activeStaging.remove(staging.path);
    }
  }

  /// Deletes staging directories in [outputDirectory] that a download
  /// abandoned when its process ended (closed mid-download, crashed, or
  /// killed): partial streams, intermediate audio, and thumbnails that no
  /// receipt owns. A directory another running process still holds is kept.
  /// Returns how many were removed.
  Future<int> removeAbandonedStaging({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(_unlockedStagingAge);
    var removed = 0;
    try {
      await for (final entity in Directory(
        outputDirectory,
      ).list(followLinks: false)) {
        if (entity is! Directory ||
            !p.basename(entity.path).startsWith(_stagingPrefix) ||
            _activeStaging.contains(entity.path)) {
          continue;
        }
        try {
          if (!await _isAbandoned(entity, cutoff)) continue;
        } on FileSystemException {
          continue; // Removed meanwhile, or unreadable: left alone.
        }
        await _Staging(entity, null).remove();
        if (!await entity.exists()) removed++;
      }
    } on FileSystemException catch (error) {
      debugPrint("Could not look for abandoned download staging: $error");
    }
    return removed;
  }

  /// A live owner holds the staging lock. Without one, a directory nothing
  /// has written to since [cutoff] is abandoned.
  static Future<bool> _isAbandoned(Directory staging, DateTime cutoff) async {
    final lockFile = File(p.join(staging.path, _stagingLock));
    if (await lockFile.exists()) {
      RandomAccessFile? lock;
      try {
        lock = await lockFile.open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
        return true;
      } on FileSystemException {
        // Held by a running download, or locks are unsupported here.
      } finally {
        await lock?.close();
      }
    }
    var newest = (await staging.stat()).modified;
    await for (final entity in staging.list(
      recursive: true,
      followLinks: false,
    )) {
      final modified = (await entity.stat()).modified;
      if (modified.isAfter(newest)) newest = modified;
    }
    return newest.isBefore(cutoff);
  }

  Future<String?> _lyrics(_Job job) async {
    final source = job.lyrics;
    if (source == null) return null;
    try {
      final text = await source().timeout(lyricsTimeout);
      return text == null || text.trim().isEmpty ? null : text;
    } on Object catch (error) {
      debugPrint("Downloading without lyrics: ${job.progress.url}: $error");
      return null;
    }
  }

  /// Embeds lyrics in staged MP3s before their artwork is verified, so the
  /// verification also covers the rewritten tag.
  Future<void> _writeMp3Lyrics(Directory staging, String lyrics) async {
    await for (final entity in staging.list()) {
      if (entity is! File || p.extension(entity.path).toLowerCase() != ".mp3") {
        continue;
      }
      try {
        if (!await writeId3Lyrics(entity.path, lyrics)) {
          debugPrint("Lyrics were not embedded: unsupported ID3 tag");
        }
      } on Object catch (error) {
        debugPrint("Lyrics were not embedded in ${entity.path}: $error");
      }
    }
  }

  void _onWorkerProgress(_Job job, WorkerProgress data) {
    if (job.cancelled || job.result != null) return;
    final total = data.totalBytes;
    _update(
      job,
      job.progress.copyWith(
        status: data.processing
            ? DownloadStatus.processing
            : DownloadStatus.downloading,
        progress: total > 0
            ? (data.downloadedBytes / total).clamp(0.0, 1.0)
            : 0.0,
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
            !_thumbnailExtensions.contains(
              p.extension(entity.path).toLowerCase(),
            )) {
          continue;
        }
        final size = await entity.length();
        if (size > 0 && size <= maxArtworkBytes && size > largestSize) {
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
            !_audioExtensions.contains(
              p.extension(entity.path).toLowerCase(),
            )) {
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
          await writeReceipt(
            outputDirectory,
            job.progress.task,
            job.progress.url,
            entries,
          );
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
    final destination = availablePath(
      outputDirectory,
      name,
      reserved: _reservedNames,
    );
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
      unawaited(
        _removeFiles([receiptPath(outputDirectory, job.progress.task)]),
      );
    }
    final message = error == null ? "" : "$error";
    job.progress = job.progress.copyWith(
      status: status,
      progress: status == DownloadStatus.completed
          ? 1.0
          : job.progress.progress,
      error: message,
    );
    job.result = DownloadResult(
      task: job.progress.task,
      url: job.progress.url,
      status: status,
      files: files,
      error: message,
      failure: status == DownloadStatus.failed
          ? classifyDownloadError(error ?? message)
          : null,
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
