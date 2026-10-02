import "dart:async";

import "../worker/worker_client.dart";
import "store.dart";

const updateRequestKey = "yt_dlp_update_request";

/// A user-initiated update action failed; the active package is unchanged.
class YtDlpUpdateError implements Exception {
  YtDlpUpdateError(this.message);

  final String message;

  @override
  String toString() => message;
}

class YtDlpStatus {
  const YtDlpStatus({
    required this.preparing,
    this.activeVersion = "",
    this.bundled = true,
    this.updated = false,
    this.availableVersion = "",
    this.scheduledVersion = "",
    this.problem = "",
  });

  final bool preparing;
  final String activeVersion;
  final bool bundled;

  /// This launch activated a release installed at the user's request.
  final bool updated;

  /// A newer compatible release found by the last check.
  final String availableVersion;

  /// A release that will be installed when Melody next starts.
  final String scheduledVersion;

  /// The latest non-fatal selection problem.
  final String problem;
}

/// Compares yt-dlp's calendar versions (`2026.8.19`, `2026.8.19.1`).
int compareReleaseVersions(String a, String b) {
  List<int> parts(String value) => [
    for (final part in value.split(".")) int.tryParse(part) ?? 0,
  ];
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final difference = (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
    if (difference != 0) return difference.sign;
  }
  return 0;
}

/// The app's view of the worker-selected yt-dlp runtime. Selection happens
/// once per worker launch, before yt-dlp is imported, so an update checked
/// now installs at the next launch.
class YtDlpRuntime {
  YtDlpRuntime(this._store, this._worker);

  final ApplicationStore _store;
  final WorkerClient _worker;
  String _available = "";

  /// Whether the worker should install the scheduled release this launch.
  /// The request is consumed once; a failing release is recorded by the
  /// updater itself and never retried on every launch.
  static bool consumeUpdateRequest(ApplicationStore store) {
    final requested = store.get(updateRequestKey);
    if (requested is! String || requested.isEmpty) return false;
    store.set(updateRequestKey, null);
    return true;
  }

  /// Runs [callback] once selection finishes.
  void whenReady(void Function() callback) =>
      unawaited(_worker.ready.then((_) => callback(), onError: (_) => callback()));

  String _scheduled() {
    final value = _store.get(updateRequestKey);
    return value is String ? value : "";
  }

  Future<YtDlpStatus> status() async {
    if (!_worker.isReady) {
      return YtDlpStatus(preparing: true, scheduledVersion: _scheduled());
    }
    final result = await _worker.ready;
    final errors = [
      if (result["errors"] case final List<Object?> items)
        for (final item in items) "$item",
    ];
    return YtDlpStatus(
      preparing: false,
      activeVersion: "${result["active_version"] ?? ""}",
      bundled: result["active_source"] != "runtime",
      updated: result["updated"] == true,
      availableVersion: _available,
      scheduledVersion: _scheduled(),
      problem: errors.isEmpty ? "" : errors.last,
    );
  }

  /// Reads release metadata only.
  Future<YtDlpStatus> checkForUpdate() async {
    await _worker.ready;
    final active = (await status()).activeVersion;
    final String? latest;
    try {
      latest = await _worker.latestReleaseVersion();
    } catch (error) {
      throw YtDlpUpdateError("Could not check for updates: $error");
    }
    _available = latest != null && compareReleaseVersions(latest, active) > 0 ? latest : "";
    return status();
  }

  /// Installs the checked release at the next launch, before yt-dlp loads.
  Future<YtDlpStatus> requestUpdate() async {
    if (_available.isEmpty) {
      throw YtDlpUpdateError("Check for updates before installing one.");
    }
    try {
      _store.set(updateRequestKey, _available);
    } catch (error) {
      throw YtDlpUpdateError("Could not schedule the update: $error");
    }
    return status();
  }
}
