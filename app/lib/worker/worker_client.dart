/// The app's only entry point to Python: a typed request/response client for
/// the worker in `worker/`, which hosts ytmusicapi and yt-dlp.
library;

import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/errors.dart";
import "transport.dart";

export "transport.dart"
    show WorkerRuntimes, WorkerTransport, ytDlpPackage, ytMusicPackage;

/// The release of one Python package the worker selected at launch.
@immutable
class RuntimeSelection {
  const RuntimeSelection({
    required this.available,
    this.activeVersion = "",
    this.activeSource = "",
    this.updated = false,
    this.errors = const [],
  });

  factory RuntimeSelection.fromJson(Map<String, Object?> data) =>
      RuntimeSelection(
        available: data["available"] == true,
        activeVersion: "${data["active_version"] ?? ""}",
        activeSource: "${data["active_source"] ?? ""}",
        updated: data["updated"] == true,
        errors: [
          if (data["errors"] case final List<Object?> items)
            for (final item in items) "$item",
        ],
      );

  /// Whether the package can be used in this launch.
  final bool available;
  final String activeVersion;

  /// `bundled` or `runtime` (an installed update).
  final String activeSource;

  /// This launch activated a release installed at the user's request.
  final bool updated;

  /// Non-fatal selection problems, oldest first.
  final List<String> errors;

  bool get bundled => activeSource != "runtime";
}

/// What the worker selected at launch, per package.
@immutable
class WorkerStatus {
  const WorkerStatus(this.packages);

  factory WorkerStatus.fromJson(Map<String, Object?> data) {
    final packages = data["packages"];
    return WorkerStatus({
      if (packages is Map)
        for (final MapEntry(:key, :value) in packages.entries)
          if (value is Map)
            "$key": RuntimeSelection.fromJson(value.cast<String, Object?>()),
    });
  }

  /// The worker never started or has stopped.
  factory WorkerStatus.unavailable(String reason) => WorkerStatus({
    for (final package in const [ytDlpPackage, ytMusicPackage])
      package: RuntimeSelection(available: false, errors: [reason]),
  });

  final Map<String, RuntimeSelection> packages;

  /// A package the worker did not report is unavailable.
  RuntimeSelection operator [](String package) =>
      packages[package] ??
      RuntimeSelection(
        available: false,
        errors: ["$package was not reported by the worker"],
      );

  /// Downloads and stream URLs.
  RuntimeSelection get ytDlp => this[ytDlpPackage];

  /// YouTube Music search, radio, playlists, and lyrics.
  RuntimeSelection get ytMusic => this[ytMusicPackage];
}

/// Download progress reported by yt-dlp's progress hook.
@immutable
class WorkerProgress {
  const WorkerProgress({
    required this.processing,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.filename = "",
    this.title = "",
    this.uploader = "",
    this.thumbnail = "",
  });

  /// Mistyped fields read as empty rather than dropping the update.
  factory WorkerProgress.fromJson(Map<String, Object?> data) {
    int bytes(String key) => switch (data[key]) {
      final num value when value.isFinite && value > 0 => value.toInt(),
      _ => 0,
    };
    String text(String key) => switch (data[key]) {
      final String value => value,
      _ => "",
    };
    return WorkerProgress(
      processing: data["status"] == "processing",
      downloadedBytes: bytes("downloaded_bytes"),
      totalBytes: bytes("total_bytes"),
      filename: text("filename"),
      title: text("title"),
      uploader: text("uploader"),
      thumbnail: text("thumbnail"),
    );
  }

  /// Bytes are complete and FFmpeg is converting or tagging the file.
  final bool processing;
  final int downloadedBytes;
  final int totalBytes;
  final String filename;
  final String title;
  final String uploader;
  final String thumbnail;
}

/// Request/response client for the Python worker.
///
/// Every request completes: with the worker's reply, or with a
/// [WorkerFailure] once the transport stops. A stopped worker is never
/// restarted within a launch.
class WorkerClient {
  WorkerClient(this._transport) {
    _subscription = _transport.frames.listen(
      _receive,
      onError: (Object error) => debugPrint("Python worker error: $error"),
    );
    unawaited(_transport.stopped.then(_stop));
  }

  /// Starts the worker for this platform. Source-tree development can run it
  /// in a standalone interpreter by setting `MELODY_WORKER_PYTHON` (and
  /// optionally `MELODY_WORKER_SOURCE`). Never throws: a worker that cannot
  /// start reports itself unavailable.
  static Future<WorkerClient> start({required WorkerRuntimes runtimes}) async {
    final environment = Platform.environment;
    final python = environment["MELODY_WORKER_PYTHON"] ?? "";
    WorkerTransport transport;
    try {
      transport = python.isNotEmpty
          ? await ProcessTransport.start(
              python: python,
              workerSource:
                  environment["MELODY_WORKER_SOURCE"] ??
                  p.normalize(
                    p.join(Directory.current.path, "..", "worker", "src"),
                  ),
              runtimes: runtimes,
            )
          : BridgeTransport.start(runtimes: runtimes);
    } on Object catch (error) {
      debugPrint("Python worker could not start: $error");
      transport = UnavailableTransport("Python could not start: $error");
    }
    return WorkerClient(transport);
  }

  final WorkerTransport _transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  final Map<int, Completer<Object?>> _requests = {};
  final Map<String, void Function(WorkerProgress)> _progress = {};
  final Completer<WorkerStatus> _ready = Completer();
  int _nextId = 0;
  String? _stoppedReason;

  /// The runtime selection, reported once every package is ready to import.
  /// A worker that stops first reports itself unavailable.
  Future<WorkerStatus> get ready => _ready.future;

  bool get isReady => _ready.isCompleted;

  void _receive(Map<String, Object?> frame) {
    final event = frame["event"];
    if (event == "ready") {
      if (!_ready.isCompleted) {
        _ready.complete(WorkerStatus.fromJson(_object(frame["status"])));
      }
      return;
    }
    if (event == "progress") {
      final listener = _progress[frame["task"]];
      if (listener == null) return;
      try {
        listener(WorkerProgress.fromJson(frame));
      } on Object catch (error) {
        // One listener's failure must not stop frames for every request.
        debugPrint("Worker progress listener failed: $error");
      }
      return;
    }
    final id = frame["id"];
    if (id is! int) return;
    final request = _requests.remove(id);
    if (request == null) return;
    // Removed above, so every path below must complete it.
    if (frame["ok"] == true) {
      request.complete(frame["result"]);
    } else {
      request.completeError(WorkerFailure.fromJson(_object(frame["error"])));
    }
  }

  static Map<String, Object?> _object(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};

  /// Fails everything still waiting on a worker that can no longer answer.
  void _stop(String? reason) {
    if (_stoppedReason != null) return;
    final message = reason ?? "The Python worker has stopped.";
    _stoppedReason = message;
    if (!_ready.isCompleted) _ready.complete(WorkerStatus.unavailable(message));
    final pending = _requests.values.toList();
    _requests.clear();
    _progress.clear();
    for (final request in pending) {
      request.completeError(WorkerFailure(message));
    }
  }

  Future<Object?> _call(
    String operation, [
    Map<String, Object?> arguments = const {},
  ]) {
    final stopped = _stoppedReason;
    if (stopped != null) return Future.error(WorkerFailure(stopped));
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _requests[id] = completer;
    try {
      _transport.send({"id": id, "op": operation, ...arguments});
    } on Object catch (error) {
      // Unencodable arguments or a closed channel: nothing will answer.
      _requests.remove(id);
      return Future.error(WorkerFailure("Could not reach the worker: $error"));
    }
    return completer.future;
  }

  /// yt-dlp `extract_info(download=False)`, trimmed to the fields Melody reads.
  Future<Map<String, Object?>?> extract(
    String target,
    Map<String, Object?> options,
  ) async {
    final result = await _call("extract", {
      "target": target,
      "options": options,
    });
    return (result as Map?)?.cast<String, Object?>();
  }

  /// Downloads [url] into [directory]. Returns false when it was cancelled.
  /// [metadata] adds tags (such as `lyrics`) that FFmpeg writes into the file.
  Future<bool> download({
    required String task,
    required String url,
    required String directory,
    required Map<String, Object?> options,
    Map<String, String> metadata = const {},
    required void Function(WorkerProgress progress) onProgress,
  }) async {
    _progress[task] = onProgress;
    try {
      final result = await _call("download", {
        "task": task,
        "url": url,
        "directory": directory,
        "options": options,
        if (metadata.isNotEmpty) "metadata": metadata,
      });
      return (result as Map?)?["cancelled"] != true;
    } finally {
      _progress.remove(task);
    }
  }

  Future<void> cancel(String task) => _call("cancel", {"task": task});

  /// Writes [source] to [target] with FFmpeg, copying every stream and tag
  /// and setting [metadata] tags (such as `lyrics`). [options] are yt-dlp
  /// options; `ffmpeg_location` picks the FFmpeg that downloads use.
  Future<void> tag({
    required String source,
    required String target,
    required Map<String, String> metadata,
    Map<String, Object?> options = const {},
  }) => _call("tag", {
    "source": source,
    "target": target,
    "metadata": metadata,
    "options": options,
  });

  /// Calls a read-only ytmusicapi `YTMusic` method with keyword [arguments].
  /// The worker allows `search`, `get_watch_playlist`, `get_lyrics`, and
  /// `get_playlist`.
  Future<Object?> ytMusic(String method, Map<String, Object?> arguments) =>
      _call("ytmusic", {"method": method, "arguments": arguments});

  /// The newest compatible release of [package] on PyPI, or null.
  Future<String?> latestReleaseVersion(String package) async {
    final result = await _call("latest_release", {"package": package});
    return switch (result) {
      {"version": final String version} when version.isNotEmpty => version,
      _ => null,
    };
  }

  Future<void> close() async {
    _stop(null);
    await _subscription.cancel();
    await _transport.close();
  }
}
