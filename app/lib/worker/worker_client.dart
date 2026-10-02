import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:serious_python/bridge.dart";
import "package:serious_python/serious_python.dart";

import "../core/errors.dart";

/// Moves JSON frames between the app and the yt-dlp worker.
abstract class WorkerTransport {
  Stream<Map<String, Object?>> get frames;
  void send(Map<String, Object?> frame);
  Future<void> close();
}

/// The embedded interpreter, reached through serious_python's in-process
/// byte channel. Python owns no process of its own.
class BridgeTransport implements WorkerTransport {
  BridgeTransport._(this._bridge);

  final PythonBridge _bridge;
  final List<Uint8List> _pending = [];
  Timer? _retry;

  /// Starts the packaged worker (`worker/src/main.py`).
  static Future<BridgeTransport> start({
    required String runtimeDirectory,
    required bool checkForUpdate,
  }) async {
    final bridge = PythonBridge();
    final transport = BridgeTransport._(bridge);
    // Python runs until the app exits; awaiting run() would never return.
    unawaited(
      SeriousPython.run(
        environmentVariables: {
          "MELODY_WORKER_PORT": "${bridge.port}",
          "MELODY_YT_DLP_RUNTIME": runtimeDirectory,
          "MELODY_YT_DLP_CHECK_REMOTE": checkForUpdate ? "1" : "0",
        },
      ).catchError((Object error) {
        debugPrint("yt-dlp worker stopped: $error");
        return null;
      }),
    );
    return transport;
  }

  @override
  Stream<Map<String, Object?>> get frames => _bridge.messages.map(_decode);

  @override
  void send(Map<String, Object?> frame) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(frame)));
    if (_pending.isEmpty && _bridge.send(bytes)) return;
    // The interpreter or its handler is still starting; deliver in order.
    _pending.add(bytes);
    _retry ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      while (_pending.isNotEmpty && _bridge.send(_pending.first)) {
        _pending.removeAt(0);
      }
      if (_pending.isEmpty) {
        _retry?.cancel();
        _retry = null;
      }
    });
  }

  @override
  Future<void> close() async {
    _retry?.cancel();
    _bridge.close();
  }
}

/// A standalone interpreter speaking newline-delimited JSON on stdio, used
/// by tests and source-tree development (`MELODY_WORKER_PYTHON`).
class ProcessTransport implements WorkerTransport {
  ProcessTransport._(this._process) {
    _process.stderr
        .transform(utf8.decoder)
        .listen((line) => debugPrint("[worker] ${line.trimRight()}"));
  }

  final Process _process;

  static Future<ProcessTransport> start({
    required String python,
    required String workerSource,
    required String runtimeDirectory,
    bool checkForUpdate = false,
  }) async {
    final process = await Process.start(
      python,
      ["-m", "melody_worker"],
      workingDirectory: workerSource,
      environment: {
        "PYTHONPATH": workerSource,
        "PYTHONUNBUFFERED": "1",
        "MELODY_YT_DLP_RUNTIME": runtimeDirectory,
        "MELODY_YT_DLP_CHECK_REMOTE": checkForUpdate ? "1" : "0",
      },
    );
    return ProcessTransport._(process);
  }

  @override
  Stream<Map<String, Object?>> get frames => _process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((line) => line.trim().isNotEmpty)
      .map((line) => _decode(utf8.encode(line)));

  @override
  void send(Map<String, Object?> frame) {
    _process.stdin.writeln(jsonEncode(frame));
  }

  @override
  Future<void> close() async {
    await _process.stdin.close();
    _process.kill();
  }
}

Map<String, Object?> _decode(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  return value is Map ? value.cast<String, Object?>() : const {};
}

/// Download progress reported by yt-dlp's progress hook.
class WorkerProgress {
  const WorkerProgress({
    required this.status,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.filename = "",
    this.title = "",
    this.uploader = "",
    this.thumbnail = "",
  });

  factory WorkerProgress.fromJson(Map<String, Object?> data) => WorkerProgress(
    status: data["status"] as String? ?? "downloading",
    downloadedBytes: (data["downloaded_bytes"] as num?)?.toInt() ?? 0,
    totalBytes: (data["total_bytes"] as num?)?.toInt() ?? 0,
    filename: data["filename"] as String? ?? "",
    title: data["title"] as String? ?? "",
    uploader: data["uploader"] as String? ?? "",
    thumbnail: data["thumbnail"] as String? ?? "",
  );

  /// downloading or processing.
  final String status;
  final int downloadedBytes;
  final int totalBytes;
  final String filename;
  final String title;
  final String uploader;
  final String thumbnail;
}

/// Request/response client for the yt-dlp worker.
class WorkerClient {
  WorkerClient(this._transport) {
    _subscription = _transport.frames.listen(
      _receive,
      onError: (Object error) => debugPrint("yt-dlp worker error: $error"),
    );
  }

  final WorkerTransport _transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  final Map<int, Completer<Object?>> _requests = {};
  final Map<String, void Function(WorkerProgress)> _progress = {};
  final Completer<Map<String, Object?>> _ready = Completer();
  int _nextId = 0;
  bool _closed = false;

  /// The runtime selection reported once yt-dlp is ready to import.
  Future<Map<String, Object?>> get ready => _ready.future;

  bool get isReady => _ready.isCompleted;

  void _receive(Map<String, Object?> frame) {
    final event = frame["event"];
    if (event == "ready") {
      if (!_ready.isCompleted) {
        _ready.complete(
          (frame["status"] as Map?)?.cast<String, Object?>() ?? const {},
        );
      }
      return;
    }
    if (event == "progress") {
      final listener = _progress[frame["task"]];
      if (listener != null) listener(WorkerProgress.fromJson(frame));
      return;
    }
    final id = frame["id"];
    if (id is! int) return;
    final request = _requests.remove(id);
    if (request == null) return;
    if (frame["ok"] == true) {
      request.complete(frame["result"]);
    } else {
      request.completeError(
        WorkerFailure.fromJson(
          (frame["error"] as Map?)?.cast<String, Object?>() ?? const {},
        ),
      );
    }
  }

  Future<Object?> _call(String operation, [Map<String, Object?> arguments = const {}]) {
    if (_closed) {
      return Future.error(WorkerFailure("The yt-dlp worker has stopped"));
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _requests[id] = completer;
    _transport.send({"id": id, "op": operation, ...arguments});
    return completer.future;
  }

  /// yt-dlp `extract_info(download=False)`, trimmed to the fields Melody reads.
  Future<Map<String, Object?>?> extract(
    String target,
    Map<String, Object?> options,
  ) async {
    final result = await _call("extract", {"target": target, "options": options});
    return (result as Map?)?.cast<String, Object?>();
  }

  /// Downloads [url] into [directory]. Returns false when it was cancelled.
  Future<bool> download({
    required String task,
    required String url,
    required String directory,
    required Map<String, Object?> options,
    required void Function(WorkerProgress progress) onProgress,
  }) async {
    _progress[task] = onProgress;
    try {
      final result = await _call("download", {
        "task": task,
        "url": url,
        "directory": directory,
        "options": options,
      });
      return (result as Map?)?["cancelled"] != true;
    } finally {
      _progress.remove(task);
    }
  }

  Future<void> cancel(String task) => _call("cancel", {"task": task});

  Future<Map<String, Object?>> status() async =>
      ((await _call("status")) as Map?)?.cast<String, Object?>() ?? const {};

  /// The newest compatible yt-dlp release on PyPI, or null.
  Future<String?> latestReleaseVersion() async {
    final result = await _call("latest_release");
    return (result as Map?)?["version"] as String?;
  }

  Future<void> close() async {
    _closed = true;
    await _subscription.cancel();
    await _transport.close();
    for (final request in _requests.values) {
      request.completeError(WorkerFailure("The yt-dlp worker has stopped"));
    }
    _requests.clear();
  }
}
