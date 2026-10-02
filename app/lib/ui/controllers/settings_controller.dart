import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../../app/app_state.dart";
import "../../application/cookie_files.dart";
import "../../application/library_service.dart";
import "../../application/models.dart";
import "../../application/yt_dlp_runtime.dart";
import "../../core/errors.dart";

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
  YtDlpStatus ytDlpStatus = const YtDlpStatus(preparing: true);
  bool checkingYtDlp = false;
  bool cleaningUp = false;
  bool _statusRefreshPending = false;

  /// Starts editing from the saved settings.
  void reset() {
    draft = app.settings.copy();
    pendingCookie = null;
    pendingCookieName = "";
    removeCookieRequested = false;
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
      return ("Ready to save $pendingCookieName ($count cookie${count != 1 ? "s" : ""}).", false);
    }
    if (removeCookieRequested) {
      return ("The cookie file will be removed when settings are saved.", false);
    }
    final configured = app.settings.cookieFile;
    if (configured.isEmpty) {
      return ("No cookie file uploaded. YouTube Music requests are anonymous.", false);
    }
    if (!File(configured).existsSync()) {
      return ("The saved cookie file is missing. Upload a replacement.", true);
    }
    return ("Using ${p.basename(configured)}", false);
  }

  bool get hasCookie =>
      pendingCookie != null ||
      (!removeCookieRequested &&
          app.settings.cookieFile.isNotEmpty &&
          File(app.settings.cookieFile).existsSync());

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
    final folder = Platform.isAndroid
        ? old.downloadDirectory
        : _expandHome(settings.downloadDirectory);
    if (!p.equals(p.absolute(folder), p.absolute(old.downloadDirectory)) &&
        app.services.manager.counts().$1 > 0) {
      throw const FormatException(
        "The music folder can only be changed while the library is empty.",
      );
    }
    await Directory(folder).create(recursive: true);
    settings.downloadDirectory = folder;
    final managed = app.services.paths.cookieFile;
    final removingManaged = removing &&
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
        if (removingManaged && await File(managed).exists()) await File(managed).delete();
        settings.cookieFile = "";
      }
      app.services.store.saveSettings(settings);
    } catch (_) {
      if (cookieChanged) {
        try {
          if (previousCookie != null) {
            await installCookieFile(ValidatedCookieFile(previousCookie, 0), managed);
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
    app.services.refreshProviders();
    if (settings.autoFocalPointLiveNotifications != old.autoFocalPointLiveNotifications) {
      app.syncSystemMedia(refreshMetadata: true);
    } else if (settings.notificationActionPair != old.notificationActionPair) {
      app.syncSystemMedia(refreshMetadata: false);
    }
    app.appearance.value = (settings.theme, settings.accentColor);
    reset();
    notifyListeners();
    final restart = [
      old.downloadDirectory != settings.downloadDirectory,
      old.audioFormat != settings.audioFormat,
      old.audioQuality != settings.audioQuality,
      old.concurrentDownloads != settings.concurrentDownloads,
      old.cookieFile != settings.cookieFile,
      pending != null,
    ].any((changed) => changed);
    app.showMessage(
      restart ? "Settings saved. Restart to apply download changes." : "Settings saved.",
    );
  }

  static String _expandHome(String path) {
    final home = Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"];
    if (home != null && (path == "~" || path.startsWith("~/") || path.startsWith(r"~\"))) {
      return p.join(home, path.substring(path.length == 1 ? 1 : 2));
    }
    return path;
  }

  // -- data management -------------------------------------------------------

  Future<String> runDataAction(String action) async {
    switch (action) {
      case "library":
        final (tracks, playlists) = _clearLibrary();
        if (tracks == 0 && playlists == 0) return "The library and playlists are already empty.";
        return "Cleared $tracks library track${tracks != 1 ? "s" : ""} and $playlists "
            "playlist${playlists != 1 ? "s" : ""}. Audio files were kept.";
      case "playlists":
        final count = app.services.manager.clearPlaylists();
        app.playlists.abandonImport();
        app.playlists.selectedPlaylistId = null;
        app.touchLibrary();
        if (count == 0) return "There are no playlists to clear.";
        return "Deleted $count playlist${count != 1 ? "s" : ""}. Library tracks were kept.";
      case "settings":
        final alreadyDefault = await _restoreDefaults();
        return alreadyDefault
            ? "Settings already use their default values."
            : "Settings restored to defaults. Download engine changes apply after restart.";
      case "everything":
        final (tracks, playlists) = _clearLibrary();
        final alreadyDefault = await _restoreDefaults();
        if (tracks == 0 && playlists == 0 && alreadyDefault) {
          return "The library, playlists, and settings are already reset.";
        }
        return "Library, playlists, and settings were reset. Audio files and unrelated "
            "history were kept. Download engine changes apply after restart.";
    }
    throw ArgumentError("Unknown data-management action: $action");
  }

  (int, int) _clearLibrary() {
    final counts = app.services.manager.clearLibrary();
    app.playlists.abandonImport();
    app.playback.clearLibraryState();
    app.services.store.clearLibraryData();
    app.playlists.selectedPlaylistId = null;
    app.touchLibrary();
    return counts;
  }

  Future<bool> _restoreDefaults() async {
    final defaults = AppSettings(downloadDirectory: app.services.paths.defaultMusicDirectory);
    final current = app.settings;
    final alreadyDefault = current.sameAs(defaults);
    final managed = app.services.paths.cookieFile;
    if (current.cookieFile.isNotEmpty &&
        p.equals(p.absolute(current.cookieFile), p.absolute(managed)) &&
        await File(managed).exists()) {
      await File(managed).delete();
    }
    app.services.store.saveSettings(defaults);
    app.settings = defaults;
    app.playback.applySettings(defaults);
    app.services.refreshProviders();
    if (current.autoFocalPointLiveNotifications != defaults.autoFocalPointLiveNotifications) {
      app.syncSystemMedia(refreshMetadata: true);
    } else if (current.notificationActionPair != defaults.notificationActionPair) {
      app.syncSystemMedia(refreshMetadata: false);
    }
    app.appearance.value = (defaults.theme, defaults.accentColor);
    reset();
    notifyListeners();
    return alreadyDefault;
  }

  // -- maintenance -----------------------------------------------------------

  Future<void> refreshYtDlpStatus() async {
    ytDlpStatus = await app.services.ytDlp.status();
    notifyListeners();
    if (ytDlpStatus.preparing && !_statusRefreshPending) {
      // A launch that installs an update can take a while; replace
      // "Preparing" without leaving Settings.
      _statusRefreshPending = true;
      app.services.ytDlp.whenReady(() {
        _statusRefreshPending = false;
        refreshYtDlpStatus();
      });
    }
  }

  String ytDlpStatusText() {
    final status = ytDlpStatus;
    var text = status.preparing
        ? "Preparing yt-dlp…"
        : status.updated
        ? "Updated to yt-dlp ${status.activeVersion}."
        : "Using yt-dlp ${status.activeVersion} "
              "(${status.bundled ? "bundled with Melody" : "installed update"}).";
    if (status.scheduledVersion.isNotEmpty) {
      text += " Version ${status.scheduledVersion} will be installed the next time Melody starts.";
    } else if (status.availableVersion.isNotEmpty) {
      text += " Version ${status.availableVersion} is available.";
    }
    if (status.problem.isNotEmpty && !status.preparing) {
      text += " Last issue: ${publicErrorMessage(status.problem)}";
    }
    return text;
  }

  bool get canInstallUpdate =>
      ytDlpStatus.availableVersion.isNotEmpty &&
      ytDlpStatus.availableVersion != ytDlpStatus.scheduledVersion;

  Future<void> checkForUpdate() async {
    checkingYtDlp = true;
    notifyListeners();
    try {
      ytDlpStatus = await app.services.ytDlp.checkForUpdate();
      app.showMessage(
        ytDlpStatus.availableVersion.isNotEmpty
            ? "yt-dlp ${ytDlpStatus.availableVersion} is available."
            : "yt-dlp is up to date.",
      );
    } on YtDlpUpdateError catch (error) {
      app.showError(error.message);
      ytDlpStatus = await app.services.ytDlp.status();
    } finally {
      checkingYtDlp = false;
      notifyListeners();
    }
  }

  Future<void> installUpdate() async {
    try {
      ytDlpStatus = await app.services.ytDlp.requestUpdate();
      app.showMessage(
        "Restart Melody to install yt-dlp ${ytDlpStatus.scheduledVersion}. "
        "The current version stays in use until then.",
      );
    } on YtDlpUpdateError catch (error) {
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
}
