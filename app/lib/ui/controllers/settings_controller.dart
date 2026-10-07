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

/// In-progress settings choices and the save/reset workflows.
class SettingsController extends ChangeNotifier {
  SettingsController(this.app) {
    reset();
  }

  final MelodyApp app;
  late AppSettings draft;
  ValidatedCookieFile? pendingCookie;
  String pendingCookieName = "";
  bool removeCookieRequested = false;

  /// Status per worker package, keyed by package name.
  final Map<String, PackageStatus> packageStatus = {};

  /// Packages with an update check in progress.
  final Set<String> checkingPackages = {};
  bool cleaningUp = false;
  bool _statusRefreshPending = false;

  /// Whether the saved cookie file exists, checked asynchronously so
  /// building the settings never waits on the disk. Assumed present until a
  /// check says otherwise.
  bool _savedCookieExists = true;
  int _cookieCheck = 0;
  bool _disposed = false;

  /// Starts editing from the saved settings.
  void reset() {
    draft = app.settings.copy();
    pendingCookie = null;
    pendingCookieName = "";
    removeCookieRequested = false;
    unawaited(_checkSavedCookie());
  }

  Future<void> _checkSavedCookie() async {
    final check = ++_cookieCheck;
    final path = app.settings.cookieFile;
    var exists = false;
    if (path.isNotEmpty) {
      try {
        exists = await File(path).exists();
      } on FileSystemException {
        exists = false;
      }
    }
    // A newer check, or nothing changed.
    if (_disposed || check != _cookieCheck || exists == _savedCookieExists) {
      return;
    }
    _savedCookieExists = exists;
    notifyListeners();
  }

  /// A saved cookie file is configured and present.
  bool get savedCookieAvailable =>
      app.settings.cookieFile.isNotEmpty && _savedCookieExists;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void update(void Function(AppSettings draft) change) {
    change(draft);
    notifyListeners();
  }

  /// Previews theme and accent immediately; persisted only on save.
  void previewAppearance({String? theme, String? accent}) {
    if (theme != null) draft.theme = theme;
    if (accent != null) draft.accentColor = accent;
    app.appearance.value = (draft.theme, draft.accentColor);
    notifyListeners();
  }

  void cancel() {
    reset();
    app.appearance.value = (app.settings.theme, app.settings.accentColor);
    app.closePanel();
    notifyListeners();
  }

  /// The visible cookie status line and whether it is a problem.
  (String, bool) cookieStatus() {
    if (pendingCookie != null) {
      final count = pendingCookie!.cookieCount;
      return (
        "Ready to save $pendingCookieName (${plural(count, "cookie")}).",
        false,
      );
    }
    if (removeCookieRequested) {
      return (
        "The cookie file will be removed when settings are saved.",
        false,
      );
    }
    final configured = app.settings.cookieFile;
    if (configured.isEmpty) {
      return ("No cookie file uploaded.", false);
    }
    if (!_savedCookieExists) {
      return ("The saved cookie file is missing. Upload a replacement.", true);
    }
    return ("Using ${p.basename(configured)}", false);
  }

  bool get hasCookie =>
      pendingCookie != null || (!removeCookieRequested && savedCookieAvailable);

  void stageCookie(String name, List<int> content) {
    try {
      pendingCookie = validateCookieFile(content);
      pendingCookieName = name;
      removeCookieRequested = false;
    } on CookieFileError catch (error) {
      app.showError(error.message);
    }
    notifyListeners();
  }

  void removeCookie() {
    pendingCookie = null;
    pendingCookieName = "";
    removeCookieRequested = true;
    notifyListeners();
  }

  Future<void> save() async {
    final old = app.settings.copy();
    final settings = draft.copy()
      // The playback controller owns volume; keep its current values.
      ..volume = app.playback.volume
      ..previousVolume = app.playback.previousVolume
      ..muted = app.playback.muted;
    final pending = pendingCookie;
    final removing = removeCookieRequested;
    app.showMessage("Saving settings…");
    // Absolute, so the folder never depends on the launch directory.
    final folder = Platform.isAndroid
        ? old.downloadDirectory
        : p.normalize(p.absolute(_expandHome(settings.downloadDirectory)));
    if (_sameFolder(folder, old.downloadDirectory)) {
      await Directory(folder).create(recursive: true);
    } else {
      // Applied now: a download before a restart must land where the
      // library will look for it afterwards.
      await app.services.downloads.changeDirectory(folder);
    }
    settings.downloadDirectory = folder;
    final managed = app.services.paths.cookieFile;
    final removingManaged =
        removing &&
        settings.cookieFile.isNotEmpty &&
        p.equals(p.absolute(settings.cookieFile), p.absolute(managed));
    final cookieChanged = pending != null || removingManaged;
    List<int>? previousCookie;
    if (cookieChanged && await File(managed).exists()) {
      previousCookie = await File(managed).readAsBytes();
    }
    try {
      if (pending != null) {
        settings.cookieFile = await installCookieFile(pending, managed);
      } else if (removing) {
        if (removingManaged && await File(managed).exists()) {
          await File(managed).delete();
        }
        settings.cookieFile = "";
      }
      app.services.store.saveSettings(settings);
    } catch (_) {
      await _revertMusicFolder(folder, old.downloadDirectory);
      if (cookieChanged) {
        try {
          if (previousCookie != null) {
            await installCookieFile(
              ValidatedCookieFile(previousCookie, 0),
              managed,
            );
          } else if (await File(managed).exists()) {
            await File(managed).delete();
          }
        } on FileSystemException catch (error) {
          debugPrint("Could not restore the managed cookie file: $error");
        }
      }
      rethrow;
    }
    app.settings = settings;
    if (settings.autoFocalPointLiveNotifications !=
        old.autoFocalPointLiveNotifications) {
      app.syncSystemMedia(refreshMetadata: true);
    } else if (settings.notificationActionPair != old.notificationActionPair) {
      app.syncSystemMedia(refreshMetadata: false);
    }
    app.appearance.value = (settings.theme, settings.accentColor);
    reset();
    notifyListeners();
    final restart = [
      old.audioFormat != settings.audioFormat,
      old.audioQuality != settings.audioQuality,
      old.concurrentDownloads != settings.concurrentDownloads,
      old.cookieFile != settings.cookieFile,
      pending != null,
    ].any((changed) => changed);
    app.showMessage(
      restart
          ? "Settings saved. Restart to apply download changes."
          : "Settings saved.",
    );
  }

  static bool _sameFolder(String a, String b) =>
      p.equals(p.absolute(a), p.absolute(b));

  /// Moves the live library back to [previous] after the new [folder]
  /// could not be saved, so runtime and saved settings agree.
  Future<void> _revertMusicFolder(String folder, String previous) async {
    if (_sameFolder(folder, previous)) return;
    try {
      await app.services.downloads.changeDirectory(previous);
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
            : "Settings restored to defaults. Download engine changes apply after restart.";
      case "everything":
        final (tracks, playlists) = await _clearLibrary(deleteImported: true);
        final alreadyDefault = await _restoreDefaults();
        if (tracks == 0 && playlists == 0 && alreadyDefault) {
          return "The library, playlists, and settings are already reset.";
        }
        return "Library, playlists, and settings were reset, and library audio was "
            "deleted. Unrelated history was kept. Download engine changes apply "
            "after restart.";
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
    // Library files are recorded relative to the music folder, so like
    // [save], the folder only changes while the library is empty, and then
    // takes effect immediately. Busy downloads keep the current folder.
    var folder = current.downloadDirectory;
    final defaultFolder = app.services.paths.defaultMusicDirectory;
    if (!_sameFolder(folder, defaultFolder) &&
        app.services.manager.counts().$1 == 0) {
      try {
        await app.services.downloads.changeDirectory(defaultFolder);
        folder = defaultFolder;
      } on FormatException catch (error) {
        debugPrint("Keeping the music folder: ${error.message}");
      }
    }
    final defaults = AppSettings(downloadDirectory: folder);
    final alreadyDefault = current.sameAs(defaults);
    final managed = app.services.paths.cookieFile;
    if (current.cookieFile.isNotEmpty &&
        p.equals(p.absolute(current.cookieFile), p.absolute(managed)) &&
        await File(managed).exists()) {
      await File(managed).delete();
    }
    try {
      app.services.store.saveSettings(defaults);
    } catch (_) {
      await _revertMusicFolder(folder, current.downloadDirectory);
      rethrow;
    }
    app.settings = defaults;
    app.playback.applySettings(defaults);
    if (current.autoFocalPointLiveNotifications !=
        defaults.autoFocalPointLiveNotifications) {
      app.syncSystemMedia(refreshMetadata: true);
    } else if (current.notificationActionPair !=
        defaults.notificationActionPair) {
      app.syncSystemMedia(refreshMetadata: false);
    }
    app.appearance.value = (defaults.theme, defaults.accentColor);
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
