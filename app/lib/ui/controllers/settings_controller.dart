import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../app_state.dart";
import "../shared/format.dart";
import "../../application/cookie_files.dart";
import "../../application/library_service.dart";
import "../../application/models.dart";
import "../../application/package_runtime.dart";
import "../../core/errors.dart";
import "../../core/media.dart";
import "../../core/storage.dart" show deleteQuietly, samePath;

/// What the Settings page changes. Every setting applies and is saved the
/// moment it changes; only a new music folder waits to be confirmed, since it
/// can move the whole library.
class SettingsController extends ChangeNotifier {
  SettingsController(this.app) {
    reset();
  }

  final MelodyApp app;

  /// The music folder text as typed, not applied yet.
  String folderInput = "";

  /// The text the folder field starts from. It changes only from outside the
  /// field, which rebuilds the field; typing never does.
  String folderField = "";

  /// Status per worker package, keyed by package name.
  final Map<String, PackageStatus> packageStatus = {};

  /// Packages with an update check in progress.
  final Set<String> checkingPackages = {};
  bool cleaningUp = false;
  bool writingLyrics = false;
  bool _statusRefreshPending = false;

  /// Whether the uploaded cookie file exists, checked asynchronously so
  /// building the settings never waits on the disk.
  bool _savedCookieExists = false;
  int _cookieCheck = 0;
  bool _disposed = false;

  /// Starts from the saved settings.
  void reset() {
    folderInput = folderField = app.settings.downloadDirectory;
    unawaited(_checkSavedCookie());
  }

  Future<void> _checkSavedCookie() async {
    final check = ++_cookieCheck;
    var exists = false;
    try {
      exists = await File(app.services.paths.cookieFile).exists();
    } on FileSystemException {
      exists = false;
    }
    // A newer check, or nothing changed.
    if (_disposed || check != _cookieCheck || exists == _savedCookieExists) {
      return;
    }
    _savedCookieExists = exists;
    notifyListeners();
  }

  /// A cookie file was uploaded and is in use.
  bool get savedCookieAvailable => _savedCookieExists;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Changes settings, which apply and are saved at once.
  void update(void Function(AppSettings next) change) {
    final next = _withLiveVolume(app.settings.copy());
    change(next);
    try {
      app.services.store.saveSettings(next);
      _takeEffect(next);
    } on Object catch (error) {
      app.reportFailure(error);
    }
    notifyListeners();
  }

  /// The playback controller owns volume; keep its current values.
  AppSettings _withLiveVolume(AppSettings settings) => settings
    ..volume = app.playback.volume
    ..previousVolume = app.playback.previousVolume
    ..muted = app.playback.muted;

  void _takeEffect(AppSettings settings) {
    final old = app.settings;
    app.settings = settings;
    app.services.downloads.applySettings(settings);
    app.services.loudness.configure(
      enabled: settings.normalizeLoudness,
      targetLufs: settings.loudnessTarget.toDouble(),
    );
    if (settings.notificationActionPair != old.notificationActionPair) {
      app.syncSystemMedia(refreshMetadata: false);
    }
    app.appearance.value = (settings.theme, settings.accentColor);
  }

  String get cookieStatus => _savedCookieExists
      ? "Using the uploaded cookie file."
      : "No cookie file uploaded.";

  /// Starts using a cookie file for later downloads.
  Future<void> uploadCookie(String name, List<int> content) async {
    try {
      final cookie = validateCookieFile(content);
      await installCookieFile(cookie, app.services.paths.cookieFile);
      _savedCookieExists = true;
      app.services.downloads.applySettings(app.settings);
      app.showMessage("Using $name (${plural(cookie.cookieCount, "cookie")}).");
    } on CookieFileError catch (error) {
      app.showError(error.message);
    }
    notifyListeners();
  }

  /// Stops using the cookie file for later downloads.
  Future<void> removeCookie() async {
    await deleteQuietly(app.services.paths.cookieFile);
    app.services.downloads.applySettings(app.settings);
    await _checkSavedCookie();
    app.showMessage("The cookie file was removed.");
    notifyListeners();
  }

  void typeMusicFolder(String value) {
    folderInput = value;
    notifyListeners();
  }

  void chooseMusicFolder(String value) {
    folderInput = folderField = value;
    notifyListeners();
  }

  /// The music folder asked for, made absolute so it never depends on the
  /// launch directory.
  String get requestedMusicFolder =>
      p.normalize(p.absolute(_expandHome(folderInput.trim())));

  bool get musicFolderChanged =>
      folderInput.trim().isNotEmpty &&
      !samePath(requestedMusicFolder, app.settings.downloadDirectory);

  /// Library tracks that a new music folder would move; zero when the folder
  /// is unchanged.
  int get tracksToMove =>
      musicFolderChanged ? app.services.manager.counts().$1 : 0;

  /// Applies the requested music folder. A library with tracks needs
  /// [moveLibrary], which moves their files there.
  Future<void> applyMusicFolder({bool moveLibrary = false}) async {
    if (!musicFolderChanged) return;
    final folder = requestedMusicFolder;
    final previous = app.settings.downloadDirectory;
    if (moveLibrary) {
      app.showMessage("Moving the library…");
      // The player may hold a track file open, which can't be moved.
      app.playback.releaseLibrarySource();
    }
    final moved = await app.services.downloads.changeDirectory(
      folder,
      moveLibrary: moveLibrary,
    );
    final next = _withLiveVolume(app.settings.copy())
      ..downloadDirectory = folder;
    try {
      app.services.store.saveSettings(next);
    } catch (_) {
      await _revertMusicFolder(folder, previous);
      rethrow;
    }
    _takeEffect(next);
    reset();
    notifyListeners();
    app.showMessage(
      moved > 0
          ? "Moved ${plural(moved, "file")} to the new music folder."
          : "New downloads now go to $folder.",
    );
  }

  /// A short account of loudness measurement for Settings.
  String get loudnessStatus {
    final loudness = app.services.loudness;
    if (!loudness.available) {
      return "Melody's bundled FFmpeg could not be started, so tracks play "
          "at their own loudness until Melody restarts.";
    }
    final total = app.services.manager.counts().$1;
    final measured = loudness.analyzedCount.clamp(0, total);
    return measured >= total
        ? "Every library track has been measured."
        : "Measured ${plural(measured, "library track")} of $total. Melody "
              "measures the rest in the background; until then they play "
              "at a typical level.";
  }

  /// Moves the live library back to [previous] after the new [folder]
  /// could not be saved, so runtime and saved settings agree.
  Future<void> _revertMusicFolder(String folder, String previous) async {
    if (samePath(folder, previous)) return;
    try {
      await app.services.downloads.changeDirectory(previous, moveLibrary: true);
    } on Object catch (error) {
      debugPrint("Could not restore the previous music folder: $error");
    }
  }

  static String _expandHome(String path) {
    final home =
        Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"];
    if (home != null &&
        (path == "~" || path.startsWith("~/") || path.startsWith(r"~\"))) {
      return p.join(home, path.substring(path.length == 1 ? 1 : 2));
    }
    return path;
  }

  // -- data management -------------------------------------------------------

  Future<String> runDataAction(String action) async {
    switch (action) {
      case "library":
        final (tracks, playlists) = await _clearLibrary();
        if (tracks == 0 && playlists == 0) {
          return "The library and playlists are already empty.";
        }
        return "Cleared ${plural(tracks, "library track")} and "
            "${plural(playlists, "playlist")}. Downloaded audio was deleted; "
            "imported files were kept.";
      case "playlists":
        final count = app.services.manager.clearPlaylists();
        app.playlists.abandonImport();
        app.playlists.selectedPlaylistId = null;
        app.touchLibrary();
        if (count == 0) return "There are no playlists to clear.";
        return "Deleted ${plural(count, "playlist")}. Library tracks were kept.";
      case "settings":
        final alreadyDefault = await _restoreDefaults();
        return alreadyDefault
            ? "Settings already use their default values."
            : "Settings restored to defaults.";
      case "everything":
        final (tracks, playlists) = await _clearLibrary(deleteImported: true);
        final alreadyDefault = await _restoreDefaults();
        if (tracks == 0 && playlists == 0 && alreadyDefault) {
          return "The library, playlists, and settings are already reset.";
        }
        return "Library, playlists, and settings were reset, and library audio was "
            "deleted. Unrelated history was kept.";
    }
    throw ArgumentError("Unknown data-management action: $action");
  }

  Future<(int, int)> _clearLibrary({bool deleteImported = false}) async {
    // Releases the playing file before library files are deleted.
    app.playback.clearLibraryState();
    app.playlists.abandonImport();
    final counts = await app.services.library.clearLibrary(
      deleteImported: deleteImported,
    );
    app.playlists.selectedPlaylistId = null;
    app.touchLibrary();
    return counts;
  }

  Future<bool> _restoreDefaults() async {
    final current = app.settings;
    // Library files are recorded relative to the music folder, so here the
    // folder only changes while the library is empty, and then
    // takes effect immediately. Busy downloads keep the current folder.
    var folder = current.downloadDirectory;
    final defaultFolder = app.services.paths.defaultMusicDirectory;
    if (!samePath(folder, defaultFolder) &&
        app.services.manager.counts().$1 == 0) {
      try {
        await app.services.downloads.changeDirectory(defaultFolder);
        folder = defaultFolder;
      } on FormatException catch (error) {
        debugPrint("Keeping the music folder: ${error.message}");
      }
    }
    final defaults = AppSettings(downloadDirectory: folder);
    final cookies = app.services.paths.cookieFile;
    final alreadyDefault =
        current.sameAs(defaults) && !await File(cookies).exists();
    try {
      app.services.store.saveSettings(defaults);
    } catch (_) {
      await _revertMusicFolder(folder, current.downloadDirectory);
      rethrow;
    }
    // The default is no cookies. Best effort: the other defaults are
    // already saved.
    await deleteQuietly(cookies);
    app.playback.applySettings(defaults);
    _takeEffect(defaults);
    reset();
    notifyListeners();
    return alreadyDefault;
  }

  // -- maintenance -----------------------------------------------------------

  PackageStatus statusOf(PackageRuntime runtime) =>
      packageStatus[runtime.info.package] ??
      const PackageStatus(preparing: true);

  Future<void> refreshPackageStatus() async {
    final runtimes = app.services.runtimes;
    for (final runtime in runtimes) {
      packageStatus[runtime.info.package] = await runtime.status();
    }
    notifyListeners();
    if (runtimes.any((runtime) => statusOf(runtime).preparing) &&
        !_statusRefreshPending) {
      // A launch that installs an update can take a while; replace
      // "Preparing" without leaving Settings.
      _statusRefreshPending = true;
      runtimes.first.whenReady(() {
        _statusRefreshPending = false;
        refreshPackageStatus();
      });
    }
  }

  String packageStatusText(PackageRuntime runtime) {
    final status = statusOf(runtime);
    final info = runtime.info;
    if (!status.preparing && !status.available) {
      final problem = status.problem.isEmpty
          ? ""
          : " ${publicErrorMessage(status.problem)}";
      return "${info.label} is unavailable, so ${info.purpose} are off until "
          "Melody restarts.$problem";
    }
    var text = status.preparing
        ? "Preparing ${info.label}…"
        : status.updated
        ? "Updated to ${info.label} ${status.activeVersion}."
        : "Using ${info.label} ${status.activeVersion} "
              "(${status.bundled ? "bundled with Melody" : "installed update"}).";
    if (status.scheduledVersion.isNotEmpty) {
      text +=
          " Version ${status.scheduledVersion} will be installed the next time Melody starts.";
    } else if (status.availableVersion.isNotEmpty) {
      text += " Version ${status.availableVersion} is available.";
    }
    if (status.problem.isNotEmpty && !status.preparing) {
      text += " Last issue: ${publicErrorMessage(status.problem)}";
    }
    return text;
  }

  bool canInstallUpdate(PackageRuntime runtime) {
    final status = statusOf(runtime);
    return status.available &&
        status.availableVersion.isNotEmpty &&
        status.availableVersion != status.scheduledVersion;
  }

  bool isChecking(PackageRuntime runtime) =>
      checkingPackages.contains(runtime.info.package);

  Future<void> checkForUpdate(PackageRuntime runtime) async {
    final info = runtime.info;
    checkingPackages.add(info.package);
    notifyListeners();
    try {
      final status = await runtime.checkForUpdate();
      packageStatus[info.package] = status;
      app.showMessage(
        status.availableVersion.isNotEmpty
            ? "${info.label} ${status.availableVersion} is available."
            : "${info.label} is up to date.",
      );
    } on PackageUpdateError catch (error) {
      app.showError(error.message);
      packageStatus[info.package] = await runtime.status();
    } finally {
      checkingPackages.remove(info.package);
      notifyListeners();
    }
  }

  Future<void> installUpdate(PackageRuntime runtime) async {
    final info = runtime.info;
    try {
      final status = await runtime.requestUpdate();
      packageStatus[info.package] = status;
      app.showMessage(
        "Restart Melody to install ${info.label} ${status.scheduledVersion}. "
        "The current version stays in use until then.",
      );
    } on PackageUpdateError catch (error) {
      app.showError(error.message);
    }
    notifyListeners();
  }

  Future<LibraryReconciliation?> cleanUpLibrary() async {
    cleaningUp = true;
    notifyListeners();
    try {
      final report = await app.services.library.reconcile();
      if (report.staleReferencesRemoved > 0) app.touchLibrary();
      return report;
    } catch (error) {
      app.showError("Library cleanup could not be completed: $error");
      return null;
    } finally {
      cleaningUp = false;
      notifyListeners();
    }
  }

  /// Writes lyrics into the library files that have none, where Melody can.
  Future<void> writeLyricsIntoFiles() async {
    final embedder = app.services.lyricsEmbedder;
    if (embedder == null || writingLyrics) return;
    writingLyrics = true;
    notifyListeners();
    try {
      final report = await embedder.embedLibrary();
      app.showMessage(
        [
          report.written > 0
              ? "Wrote lyrics into ${plural(report.written, "file")}."
              : "No file took new lyrics.",
          if (report.failed > 0)
            "${plural(report.failed, "file")} could not be changed.",
          if (report.playing > 0) "The playing track was left alone.",
        ].join(" "),
        error: report.failed > 0,
      );
    } finally {
      writingLyrics = false;
      notifyListeners();
    }
  }

  /// Brings back missing audio: an imported track is copied again from its
  /// original file, a downloaded one is downloaded again. Returns the ids
  /// that were restored or queued.
  Future<Set<String>> repairMissingTracks(Iterable<String> trackIds) async {
    final library = app.services.library;
    final handled = <String>{};
    var restored = 0;
    var queued = 0;
    final failures = <String>[];
    for (final trackId in trackIds) {
      if (!app.services.manager.hasTrack(trackId)) {
        handled.add(trackId);
        continue;
      }
      final track = app.services.manager.getTrack(trackId);
      try {
        if (await library.canRestoreLocalFile(trackId)) {
          await library.restoreLocalFile(trackId);
          restored++;
        } else if (isYoutubeUrl(track.source)) {
          final details = library.details(trackId);
          await app.services.downloads.request(
            SearchResult(
              id: trackId,
              title: track.displayTitle,
              uploader: details.uploader,
              duration: details.duration,
              thumbnail: details.thumbnail,
              url: track.source,
              source: details.sourceName.isNotEmpty
                  ? details.sourceName
                  : youtubeMusicName,
            ),
          );
          queued++;
        } else {
          failures.add("“${track.displayTitle}” has no source to restore from");
          continue;
        }
        handled.add(trackId);
      } on Object catch (error) {
        failures.add("“${track.displayTitle}”: ${failureMessage(error)}");
      }
    }
    if (restored > 0) app.touchLibrary();
    final summary = [
      if (restored > 0)
        "Restored ${plural(restored, "track")} from the original files.",
      if (queued > 0) "Downloading ${plural(queued, "track")} again.",
    ];
    _report(summary, failures);
    return handled;
  }

  /// Removes tracks from the library and every playlist. Returns the ids
  /// that are gone.
  Future<Set<String>> removeTracks(Iterable<String> trackIds) async {
    final removed = <String>{};
    final failures = <String>[];
    for (final trackId in trackIds) {
      try {
        if (app.services.manager.hasTrack(trackId)) {
          await app.library.deleteTrack(trackId);
        }
        removed.add(trackId);
      } on Object catch (error) {
        failures.add(failureMessage(error));
      }
    }
    _report([
      if (removed.isNotEmpty)
        "Removed ${plural(removed.length, "track")} from the library.",
    ], failures);
    return removed;
  }

  /// Adds stray audio files to the library where they are. Returns the
  /// paths that no longer need attention.
  Future<Set<String>> addStrayFiles(List<String> paths) async {
    final outcome = await app.services.library.addStrayFiles(paths);
    if (outcome.done > 0) app.touchLibrary();
    _report([
      if (outcome.done > 0)
        "Added ${plural(outcome.done, "file")} to the library.",
    ], outcome.failures);
    return _settled(paths);
  }

  /// Deletes stray audio files. Returns the paths that no longer need
  /// attention.
  Future<Set<String>> deleteStrayFiles(List<String> paths) async {
    final outcome = await app.services.library.deleteStrayFiles(paths);
    _report([
      if (outcome.done > 0) "Deleted ${plural(outcome.done, "file")}.",
    ], outcome.failures);
    return _settled(paths);
  }

  /// Stray paths that are gone or now belong to a track.
  Future<Set<String>> _settled(List<String> paths) async => {
    for (final path in paths)
      if (!await File(path).exists() ||
          app.services.manager.isPathReferenced(path))
        path,
  };

  void _report(List<String> summary, List<String> failures) {
    if (failures.isNotEmpty) {
      app.showError([...summary, failures.take(3).join(" • ")].join(" "));
    } else if (summary.isNotEmpty) {
      app.showMessage(summary.join(" "));
    }
  }
}
