/// How JSON frames reach the Python worker: serious_python's in-process FFI
/// bridge in the app, or a standalone interpreter on stdio during development.
library;

import "dart:async";
import "dart:collection";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:serious_python/bridge.dart";
import "package:serious_python/serious_python.dart";

/// Environment the worker reads at startup (see `worker/src/melody_worker`).
const _portVariable = "MELODY_WORKER_PORT";

/// The Python packages the worker selects at launch, by PyPI name.
const ytDlpPackage = "yt-dlp";
const ytMusicPackage = "ytmusicapi";

/// Per package: the runtime storage and "update this launch" variables.
const _packageVariables = {
  ytDlpPackage: ("MELODY_YT_DLP_RUNTIME", "MELODY_YT_DLP_CHECK_REMOTE"),
  ytMusicPackage: (
    "MELODY_YTMUSICAPI_RUNTIME",
    "MELODY_YTMUSICAPI_CHECK_REMOTE",
  ),
};

/// Where the worker keeps each package's runtime updates, and which
/// packages install their newest compatible release during this launch.
@immutable
class WorkerRuntimes {
  const WorkerRuntimes(this.directories, {this.update = const {}});

  /// Storage directories keyed by package name.
  final Map<String, String> directories;
  final Set<String> update;

  Map<String, String> get environment => {
    for (final MapEntry(key: package, value: (storage, check))
        in _packageVariables.entries) ...{
      storage: ?directories[package],
      check: update.contains(package) ? "1" : "0",
    },
  };
}

/// The label of the worker's port in [DartBridge.signalDartSession]; the
/// worker's session-restart handler looks it up.
const workerSessionLabel = "worker";

/// Moves JSON frames between the app and the Python worker.
abstract class WorkerTransport {
  /// Frames from the worker. Malformed frames are dropped.
  Stream<Map<String, Object?>> get frames;

  /// Completes once the worker can no longer answer: with the reason when it
  /// failed to start, exited, or stopped accepting frames, or with null after
  /// [close].
  Future<String?> get stopped;

  void send(Map<String, Object?> frame);

  Future<void> close();
}

/// The embedded interpreter, reached through serious_python's in-process
/// byte channel. Python owns no process of its own and runs until the app
/// exits; CPython cannot be safely finalized and restarted in one process.
class BridgeTransport implements WorkerTransport {
  BridgeTransport._(this._bridge, this._deliveryTimeout);

  final PythonBridge _bridge;
  final Duration _deliveryTimeout;
  final Queue<Uint8List> _pending = Queue();
  final Completer<String?> _stopped = Completer();
  final Stopwatch _undelivered = Stopwatch();
  Timer? _retry;
  bool _interpreterStarted = false;

  /// Starts the packaged worker (`worker/src/main.py`), or reconnects to it
  /// when the interpreter outlived a previous Dart VM in this process.
  ///
  /// Frames sent before the worker registers its handler are queued. If they
  /// still cannot be delivered [deliveryTimeout] after the interpreter
  /// started, the transport stops.
  static BridgeTransport start({
    required WorkerRuntimes runtimes,
    Duration deliveryTimeout = const Duration(seconds: 30),
  }) {
    final bridge = PythonBridge();
    final transport = BridgeTransport._(bridge, deliveryTimeout);
    final native = DartBridge.instance;
    if (native.isPythonInitialized) {
      // Android kept this process, and the interpreter, across a Dart VM
      // restart. Initializing Python twice is not possible; hand the running
      // worker this session's port instead.
      native.signalDartSession({workerSessionLabel: bridge.port});
      transport._interpreterReady();
      return transport;
    }
    SeriousPython.run(
      environmentVariables: {
        _portVariable: "${bridge.port}",
        ...runtimes.environment,
      },
    ).then(
      // With sync=false, run() resolves once the interpreter thread started;
      // a non-null result is the platform's failure message.
      (failure) => failure == null
          ? transport._interpreterReady()
          : transport._stop("Python could not start: $failure"),
      onError: (Object error) =>
          transport._stop("Python could not start: $error"),
    );
    return transport;
  }

  @override
  late final Stream<Map<String, Object?>> frames = _bridge.messages.expand(
    (bytes) => [?_decode(bytes)],
  );

  @override
  Future<String?> get stopped => _stopped.future;

  @override
  void send(Map<String, Object?> frame) {
    if (_stopped.isCompleted) return;
    _pending.add(Uint8List.fromList(utf8.encode(jsonEncode(frame))));
    _flush();
  }

  void _interpreterReady() {
    _interpreterStarted = true;
    _flush();
  }

  /// Delivers queued frames in order; retries while the worker starts.
  void _flush() {
    if (_stopped.isCompleted) return;
    while (_interpreterStarted && _pending.isNotEmpty) {
      final bool delivered;
      try {
        delivered = _bridge.send(_pending.first);
      } on StateError catch (error) {
        _stop("The worker channel closed: $error");
        return;
      }
      if (!delivered) break;
      _pending.removeFirst();
    }
    if (_pending.isEmpty) {
      _retry?.cancel();
      _retry = null;
      _undelivered
        ..stop()
        ..reset();
      return;
    }
    if (_interpreterStarted) {
      _undelivered.start();
      if (_undelivered.elapsed > _deliveryTimeout) {
        _stop("The Python worker is not accepting requests.");
        return;
      }
    }
    _retry ??= Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _flush(),
    );
  }

  void _stop(String? reason) {
    if (_stopped.isCompleted) return;
    if (reason != null) debugPrint("Python worker stopped: $reason");
    _retry?.cancel();
    _retry = null;
    _pending.clear();
    _stopped.complete(reason);
  }

  @override
  Future<void> close() async {
    _stop(null);
    _bridge.close();
  }
}

/// A standalone interpreter speaking newline-delimited JSON on stdio, used
/// by tests and source-tree development (`MELODY_WORKER_PYTHON`).
class ProcessTransport implements WorkerTransport {
  ProcessTransport._(this._process) {
    _process.stderr
        .transform(_lenientUtf8)
        .transform(const LineSplitter())
        .listen((line) => debugPrint("[worker] $line"));
    // Writes after the process exited fail here, not at the call site.
    unawaited(_process.stdin.done.catchError((Object _) {}));
    unawaited(
      _process.exitCode.then(
        (code) => _stop(
          _closing ? null : "The Python worker exited with code $code.",
        ),
      ),
    );
  }

  final Process _process;
  final Completer<String?> _stopped = Completer();
  bool _closing = false;

  static Future<ProcessTransport> start({
    required String python,
    required String workerSource,
    required WorkerRuntimes runtimes,
  }) async {
    final process = await Process.start(
      python,
      ["-m", "melody_worker"],
      workingDirectory: workerSource,
      environment: {
        "PYTHONPATH": workerSource,
        "PYTHONUNBUFFERED": "1",
        ...runtimes.environment,
      },
    );
    return ProcessTransport._(process);
  }

  @override
  late final Stream<Map<String, Object?>> frames = _process.stdout
      .transform(_lenientUtf8)
      .transform(const LineSplitter())
      .where((line) => line.trim().isNotEmpty)
      .expand((line) => [?_decode(utf8.encode(line))])
      .asBroadcastStream();

  @override
  Future<String?> get stopped => _stopped.future;

  @override
  void send(Map<String, Object?> frame) {
    if (_stopped.isCompleted) return;
    _process.stdin.writeln(jsonEncode(frame));
  }

  void _stop(String? reason) {
    if (_stopped.isCompleted) return;
    if (reason != null) debugPrint("Python worker stopped: $reason");
    _stopped.complete(reason);
  }

  @override
  Future<void> close() async {
    _closing = true;
    _stop(null);
    try {
      await _process.stdin.close();
    } on Object {
      // The process already exited.
    }
    _process.kill();
  }
}

/// A transport for a worker that could not be started at all.
class UnavailableTransport implements WorkerTransport {
  UnavailableTransport(this.reason);

  final String reason;

  @override
  Stream<Map<String, Object?>> get frames => const Stream.empty();

  @override
  Future<String?> get stopped => Future.value(reason);

  @override
  void send(Map<String, Object?> frame) {}

  @override
  Future<void> close() async {}
}

Map<String, Object?>? _decode(List<int> bytes) {
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is Map) return value.cast<String, Object?>();
  } on FormatException catch (error) {
    debugPrint("Ignoring an unreadable worker frame: $error");
  }
  return null;
}

/// Worker output decoder: a stray invalid byte (such as a log line from a
/// native library) becomes U+FFFD instead of an error that ends the stream.
const _lenientUtf8 = Utf8Decoder(allowMalformed: true);
