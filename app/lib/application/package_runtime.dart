import "dart:async";

import "../worker/worker_client.dart";
import "store.dart";

/// A user-initiated update action failed; the active package is unchanged.
class PackageUpdateError implements Exception {
  PackageUpdateError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An updatable Python package in the worker.
class RuntimePackageInfo {
  const RuntimePackageInfo({
    required this.package,
    required this.label,
    required this.purpose,
    required this.requestKey,
  });

  /// The PyPI name the worker selects by.
  final String package;

  /// The name shown in Settings.
  final String label;

  /// What stops working while the package is unavailable.
  final String purpose;

  /// The store key holding a release scheduled for the next launch.
  final String requestKey;
}

const ytDlpRuntimeInfo = RuntimePackageInfo(
  package: ytDlpPackage,
  label: "yt-dlp",
  purpose: "downloads",
  // Unchanged from earlier releases, so a scheduled update survives upgrading.
  requestKey: "yt_dlp_update_request",
);

const ytMusicRuntimeInfo = RuntimePackageInfo(
  package: ytMusicPackage,
  label: "ytmusicapi",
  purpose: "YouTube Music search, recommendations, and lyrics",
  requestKey: "ytmusicapi_update_request",
);

class PackageStatus {
  const PackageStatus({
    required this.preparing,
    this.available = true,
    this.activeVersion = "",
    this.bundled = true,
    this.updated = false,
    this.availableVersion = "",
    this.scheduledVersion = "",
    this.problem = "",
  });

  final bool preparing;

  /// The package could be imported in this launch.
  final bool available;
  final String activeVersion;
  final bool bundled;

  /// This launch activated a release installed at the user's request.
  final bool updated;

  /// A newer compatible release found by the last check.
  final String availableVersion;

  /// A release that will be installed when Melody next starts.
  final String scheduledVersion;

  /// The latest selection problem.
  final String problem;
}

/// Compares release versions numerically, part by part: yt-dlp's calendar
/// versions (`2026.8.19`, `2026.8.19.1`) and ytmusicapi's `1.12.3`.
int compareReleaseVersions(String a, String b) {
  List<int> parts(String value) => [
    for (final part in value.split(".")) int.tryParse(part) ?? 0,
  ];
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final difference =
        (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
    if (difference != 0) return difference.sign;
  }
  return 0;
}

/// The app's view of one worker-selected package. Selection happens once
/// per worker launch, before the package is imported, so an update checked
/// now installs at the next launch.
class PackageRuntime {
  PackageRuntime(this.info, this._store, this._worker);

  final RuntimePackageInfo info;
  final ApplicationStore _store;
  final WorkerClient _worker;
  String _available = "";

  /// The packages whose scheduled release the worker should install this
  /// launch. Each request is consumed once; a failing release is recorded by
  /// the updater itself and never retried on every launch.
  static Set<String> consumeUpdateRequests(
    ApplicationStore store,
    Iterable<RuntimePackageInfo> packages,
  ) => {
    for (final info in packages)
      if (_consume(store, info.requestKey)) info.package,
  };

  static bool _consume(ApplicationStore store, String key) {
    final requested = store.get(key);
    if (requested is! String || requested.isEmpty) return false;
    store.set(key, null);
    return true;
  }

  /// Runs [callback] once selection finishes.
  void whenReady(void Function() callback) =>
      unawaited(_worker.ready.then((_) => callback()));

  String _scheduled() {
    final value = _store.get(info.requestKey);
    return value is String ? value : "";
  }

  Future<PackageStatus> status() async {
    if (!_worker.isReady) {
      return PackageStatus(preparing: true, scheduledVersion: _scheduled());
    }
    final result = (await _worker.ready)[info.package];
    return PackageStatus(
      preparing: false,
      available: result.available,
      activeVersion: result.activeVersion,
      bundled: result.bundled,
      updated: result.updated,
      availableVersion: _available,
      scheduledVersion: _scheduled(),
      problem: result.errors.isEmpty ? "" : result.errors.last,
    );
  }

  /// Reads release metadata only.
  Future<PackageStatus> checkForUpdate() async {
    final current = (await _worker.ready)[info.package];
    if (!current.available) {
      throw PackageUpdateError(
        "${info.label} is unavailable in this launch. Restart Melody and try again.",
      );
    }
    final active = current.activeVersion;
    final String? latest;
    try {
      latest = await _worker.latestReleaseVersion(info.package);
    } catch (error) {
      throw PackageUpdateError("Could not check for updates: $error");
    }
    _available = latest != null && compareReleaseVersions(latest, active) > 0
        ? latest
        : "";
    return status();
  }

  /// Installs the checked release at the next launch, before it is imported.
  Future<PackageStatus> requestUpdate() async {
    if (_available.isEmpty) {
      throw PackageUpdateError("Check for updates before installing one.");
    }
    try {
      _store.set(info.requestKey, _available);
    } catch (error) {
      throw PackageUpdateError("Could not schedule the update: $error");
    }
    return status();
  }
}
