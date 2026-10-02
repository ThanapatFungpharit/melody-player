import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:melody_audio/melody_audio.dart";
import "package:path/path.dart" as p;

import "../application/models.dart";
import "../application/playback.dart";
import "../audio/audio_backend.dart";
import "../core/errors.dart";
import "../ui/controllers/home_controller.dart";
import "../ui/controllers/library_controller.dart";
import "../ui/controllers/playlists_controller.dart";
import "../ui/controllers/search_controller.dart";
import "../ui/controllers/settings_controller.dart";
import "services.dart";

const _terminalStatuses = {"completed", "failed", "cancelled"};

/// A listenable that fires on demand.
class Signal extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// A user-visible notification.
class AppMessage {
  const AppMessage(this.text, {this.error = false});

  final String text;
  final bool error;
}

/// Utility destinations shown beside or over the main content.
enum AppPanel { queue, downloads, settings, player }

/// A follow-up applied once a requested download reaches a terminal state.
class PendingTrackAction {
  const PendingTrackAction(this.action, this.playlistId);

  final String action;
  final String? playlistId;
}

/// Composition root and application-wide UI state.
///
/// Feature workflows live in the controllers it owns; this class connects
/// services, keeps system media controls in sync, and routes cross-feature
/// events such as finished downloads.
class MelodyApp {
  MelodyApp(this.services, {required bool mobile}) : isMobile = mobile {
    settings = services.store.settings;
    persistence = PlaybackPersistence(services.store, showError);
    backend = NativeAudioBackend(useDeviceVolume: mobile);
    playback = PlaybackController(
      services.manager,
      services.library,
      services.store,
      backend,
      persistence: persistence,
      availableTrackIds: services.availableTrackIds,
      artworkUri: services.thumbnails.artworkUri,
      onError: showError,
    );
    final callbacks = backend.callbacks
      ..onLoaded = playback.onLoaded
      ..onPosition = playback.onPosition
      ..onDuration = playback.onDuration
      ..onPlaying = playback.onPlaying
      ..onCompleted = playback.onCompleted
      ..onTrackChanged = playback.onTrackChanged
      ..onStopped = playback.onStopped
      ..onError = playback.onBackendError
      ..onMediaAction = _mediaAction;
    assert(identical(callbacks, backend.callbacks));
    _playbackSubscription = playback.changes.listen(_playbackChanged);
    services.downloads.onRecord = _downloadChanged;
    home = HomeController(this);
    search = MusicSearchController(this);
    library = LibraryController(this);
    playlists = PlaylistsController(this);
    settingsDraft = SettingsController(this);
    if (Platform.isAndroid) _queuePrivateTracksForExport();
  }

  final AppServices services;
  final bool isMobile;
  late AppSettings settings;
  late final PlaybackPersistence persistence;
  late final NativeAudioBackend backend;
  late final PlaybackController playback;
  late final HomeController home;
  late final MusicSearchController search;
  late final LibraryController library;
  late final PlaylistsController playlists;
  late final SettingsController settingsDraft;
  late final StreamSubscription<String> _playbackSubscription;

  /// Track, transport, queue, and loading changes.
  final Signal playbackState = Signal();

  /// Position and duration ticks.
  final Signal playbackProgress = Signal();
  final Signal playbackVolume = Signal();

  /// Bumped whenever tracks, details, or playlists change.
  final ValueNotifier<int> libraryRevision = ValueNotifier(0);
  final ValueNotifier<int> selectedNavigation = ValueNotifier(0);
  final ValueNotifier<AppPanel?> activePanel = ValueNotifier(null);

  /// Theme mode and accent currently previewed.
  late final ValueNotifier<(String, String)> appearance = ValueNotifier((
    settings.theme,
    settings.accentColor,
  ));
  final StreamController<AppMessage> _messages = StreamController.broadcast();
  Stream<AppMessage> get messages => _messages.stream;

  final Map<String, PendingTrackAction> pendingDownloadActions = {};
  final Map<String, int> downloadPlayRequests = {};
  final Set<String> _pendingMusicExports = {};
  final Map<String, String> _privateExportSources = {};
  bool _draining = false;
  String? _lastAnnouncedTrack;
  Object? _systemMediaKey;
  (String, String, String, String) _systemMediaMetadata = ("", "", "", "");
  bool _systemMediaFavorite = false;
  bool _closed = false;

  // -- notifications -------------------------------------------------------

  void showMessage(String message, {bool error = false}) {
    if (!_messages.isClosed) _messages.add(AppMessage(message, error: error));
  }

  void showError(String message) => showMessage(publicErrorMessage(message), error: true);

  /// Reports an unexpected failure from a UI action.
  void reportFailure(Object error) {
    debugPrint("Action failed: $error");
    showError(switch (error) {
      FormatException(:final message) => message,
      ArgumentError(:final message) => "$message",
      ProviderError(:final message) => message,
      _ => "$error",
    });
  }

  /// Runs a UI action, turning failures into an error message.
  Future<void> run(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      reportFailure(error);
    }
  }

  void touchLibrary() => libraryRevision.value++;

  // -- navigation ----------------------------------------------------------

  void navigate(int index) {
    selectedNavigation.value = index.clamp(0, 3);
    if (!isMobile && activePanel.value != AppPanel.queue) activePanel.value = null;
  }

  void openPanel(AppPanel panel) => activePanel.value = panel;

  void closePanel() => activePanel.value = null;

  // -- playback and system media ------------------------------------------

  void _playbackChanged(String change) {
    if (change != "volume") syncSystemMedia(refreshMetadata: change == "track");
    if (change == "track" && _privateExportSources.isNotEmpty) {
      unawaited(_cleanupExportedSources());
    }
    switch (change) {
      case "progress":
            playbackProgress.emit();
        return;
      case "volume":
            playbackVolume.emit();
        return;
    }
    playbackState.emit();
    playbackProgress.emit();
    final current = playback.currentTrackId ??
        (playback.externalTitle.isNotEmpty ? "stream:${playback.externalTitle}" : null);
    if (settings.notifications &&
        playback.playing &&
        current != null &&
        current != _lastAnnouncedTrack) {
      _lastAnnouncedTrack = current;
      showMessage("Now playing: ${currentTitle()}");
    }
  }

  /// The visible title for whatever is playing.
  String currentTitle() {
    if (playback.externalTitle.isNotEmpty) return playback.externalTitle;
    final id = playback.currentTrackId;
    if (id == null) return "Nothing playing";
    try {
      return services.manager.getTrack(id).displayTitle;
    } on ArgumentError {
      return "Nothing playing";
    }
  }

  /// Keeps lock-screen and notification controls aligned with playback.
  void syncSystemMedia({bool refreshMetadata = true}) {
    if (_closed) return;
    final key = playback.externalTitle.isNotEmpty
        ? ("stream", playback.externalTitle, playback.externalUploader, playback.externalThumbnail)
        : playback.currentTrackId != null
        ? ("track", playback.currentTrackId)
        : null;
    if (refreshMetadata || key != _systemMediaKey) {
      _systemMediaKey = key;
      final (metadata, favorite) = _resolveSystemMediaMetadata();
      _systemMediaMetadata = metadata;
      _systemMediaFavorite = favorite;
    }
    final (title, artist, album, artworkUri) = _systemMediaMetadata;
    final hasMedia = title.isNotEmpty && playback.mediaSessionActive;
    final libraryTrack =
        hasMedia && playback.currentTrackId != null && playback.externalTitle.isEmpty;
    backend.syncMediaSession(
      MediaSessionSnapshot(
        title: hasMedia ? title : "",
        artist: artist,
        album: album,
        artworkUri: artworkUri,
        autoFocalPoint: settings.autoFocalPointLiveNotifications,
        durationMs: playback.durationMs,
        positionMs: playback.positionMs,
        playing: playback.playing,
        loading: playback.loading,
        hasNext: hasMedia && playback.queue.peekNext(automatic: true) != null,
        hasPrevious: hasMedia,
        repeatMode: playback.queue.repeat.value,
        canRepeat: libraryTrack && playback.queue.items.isNotEmpty,
        canShuffle: libraryTrack && playback.queue.upcomingCount >= 2,
        canFavorite: libraryTrack,
        favorite: libraryTrack && _systemMediaFavorite,
        notificationActionPair: settings.notificationActionPair,
        // A paused stream keeps its notification; only Stop clears it.
        keepAlive: hasMedia,
      ),
    );
  }

  ((String, String, String, String), bool) _resolveSystemMediaMetadata() {
    if (playback.externalTitle.isNotEmpty) {
      return (
        (
          playback.externalTitle,
          playback.externalUploader,
          "",
          services.thumbnails.artworkUri(playback.externalThumbnail),
        ),
        false,
      );
    }
    final id = playback.currentTrackId;
    if (id == null) return (("", "", "", ""), false);
    try {
      final track = services.manager.getTrack(id);
      final details = services.library.details(id);
      return (
        (
          track.displayTitle,
          details.uploader,
          // Melody stores no album tags; the source is useful context.
          details.sourceName,
          services.thumbnails.artworkUri(details.thumbnail),
        ),
        details.favorite,
      );
    } on Object {
      return (("", "", "", ""), false);
    }
  }

  /// A command from system media controls the native engine left to the app.
  void _mediaAction(String action, int? seekPositionMs) {
    final libraryCurrent = playback.mediaSessionActive &&
        playback.externalTitle.isEmpty &&
        playback.currentTrackId != null;
    switch (action.toLowerCase()) {
      case "play":
        if (!playback.playing) playback.toggle();
      case "pause":
        if (playback.playing) playback.toggle();
      case "stop":
        playback.stop();
      case "skiptonext":
        playback.next();
      case "skiptoprevious":
        playback.previous();
      case "seekto" when seekPositionMs != null:
        playback.seek(seekPositionMs);
      case "rewind":
        playback.seek(playback.positionMs - 10000);
      case "fastforward":
        playback.seek(playback.positionMs + 10000);
      case "cyclerepeat":
        if (playback.mediaSessionActive && playback.queue.items.isNotEmpty) {
          playback.cycleRepeat();
        }
      case "shuffleupcoming" || "shuffle":
        if (libraryCurrent) playback.shuffleUpcoming();
      case "togglefavorite":
        if (libraryCurrent) unawaited(toggleFavorite(playback.currentTrackId!));
    }
  }

  /// Toggles a favorite and refreshes every view that shows it.
  Future<void> toggleFavorite(String trackId) => run(() {
    services.library.toggleFavorite(trackId);
    touchLibrary();
    playbackState.emit();
    if (trackId == playback.currentTrackId && playback.externalTitle.isEmpty) {
      syncSystemMedia(refreshMetadata: true);
    }
  });

  /// Called when the app returns to the foreground.
  void resumed() {
    unawaited(backend.refreshState());
    backend.invalidateMediaSession();
    syncSystemMedia(refreshMetadata: false);
  }

  /// Adopts a decoder retained across a widget-tree rebuild.
  Future<void> reattachNativeState() async {
    try {
      final state = await backend.reattachNativeState();
      if (state != null) playback.onNativeReattach(state);
    } on Object catch (error) {
      debugPrint("Native playback reattachment is unavailable: $error");
    }
  }

  // -- downloads -----------------------------------------------------------

  void _downloadChanged(DownloadRecord record) {
    if (record.status == "completed" && Platform.isAndroid) {
      _pendingMusicExports.addAll(record.trackIds);
      unawaited(_drainMusicExports());
    }
    if (_terminalStatuses.contains(record.status)) {
      _finishPendingDownloadAction(record);
      touchLibrary();
      playlists.notifyDownloadChanged();
    }
  }

  void _finishPendingDownloadAction(DownloadRecord record) {
    final pending = pendingDownloadActions.remove(record.id);
    if (pending == null) return;
    final generation = downloadPlayRequests.remove(record.id);
    final relevant = pending.action != "play" ||
        (generation != null && playback.isCurrentRequest(generation));
    if (!relevant) return;
    if (record.status == "completed") {
      applyTrackAction(record.trackIds, pending.action, pending.playlistId);
      return;
    }
    showError("Couldn’t finish the requested action for ${record.title}.");
  }

  /// Applies a queue, playlist, favorite, or play action to library tracks.
  void applyTrackAction(List<String> trackIds, String action, [String? playlistId]) {
    final available = trackIds.where(services.manager.hasTrack).toList();
    if (available.isEmpty) return;
    switch (action) {
      case "next":
        playback.addNextMany(available);
        showMessage("Ready to play next.");
      case "queue":
        playback.addLastMany(available);
        showMessage("Added to the queue.");
      case "playlist" when playlistId != null:
        unawaited(run(() {
          services.manager.addTracksToPlaylist(playlistId, available);
          touchLibrary();
          showMessage("Added to playlist.");
        }));
      case "favorite":
        unawaited(run(() {
          services.library.favoriteTracks(available);
          touchLibrary();
          showMessage("Added to favorites.");
        }));
      case "play":
        final autoplay = playback.loading ? playback.playing : true;
        playback.playTracks(available);
        if (!autoplay) playback.toggle();
        showMessage("Preparing track…");
    }
  }

  // -- Android public Music folder ------------------------------------------

  /// Resumes exports interrupted before their private copy was removed.
  void _queuePrivateTracksForExport() {
    final privateRoot = p.normalize(services.paths.dataDirectory);
    for (final track in services.manager.listTracks()) {
      try {
        final path = services.manager.trackPath(track.id);
        if (p.isWithin(privateRoot, path) && File(path).existsSync()) {
          _pendingMusicExports.add(track.id);
        }
      } on Object {
        continue;
      }
    }
    if (_pendingMusicExports.isNotEmpty) unawaited(_drainMusicExports());
  }

  void exportImportedTracks(Iterable<String> trackIds) {
    if (!Platform.isAndroid) return;
    _pendingMusicExports.addAll(trackIds);
    unawaited(_drainMusicExports());
  }

  /// Publishes staged Android audio and makes the public copy canonical.
  Future<void> _drainMusicExports() async {
    if (_draining) return;
    _draining = true;
    var failed = false;
    final privateRoot = p.normalize(services.paths.dataDirectory);
    final publicRoot = services.paths.publicMusicDirectory;
    try {
      while (_pendingMusicExports.isNotEmpty && !_closed) {
        final trackId = _pendingMusicExports.first;
        _pendingMusicExports.remove(trackId);
        try {
          final source = services.manager.trackPath(trackId);
          if (!p.isWithin(privateRoot, source) || !await File(source).exists()) continue;
          final published = await MelodyNative.publishAudio(source);
          if (publicRoot == null || !p.isWithin(publicRoot, published)) {
            throw StateError("Android returned a file outside Music/Melody");
          }
          await services.manager.replaceTrackFile(trackId, published);
          if (p.equals(source, published)) continue;
          if (playback.currentTrackId == trackId) {
            _privateExportSources[trackId] = source;
          } else {
            await _removeUnreferencedFile(source);
          }
        } catch (error) {
          failed = true;
          debugPrint("Could not publish track to the Android Music folder: $error");
        }
      }
    } finally {
      _draining = false;
    }
    if (failed) {
      showError(
        "A downloaded track could not be moved to Music/Melody. "
        "Melody will retry next time it starts.",
      );
    }
  }

  Future<void> _cleanupExportedSources() async {
    final current = playback.currentTrackId;
    for (final entry in _privateExportSources.entries.toList()) {
      if (entry.key == current) continue;
      await _removeUnreferencedFile(entry.value);
      _privateExportSources.remove(entry.key);
    }
  }

  Future<void> _removeUnreferencedFile(String path) async {
    if (services.manager.isPathReferenced(path)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint("Could not remove exported staging audio: $error");
    }
  }

  // -- appearance ----------------------------------------------------------

  ThemeMode get themeMode => switch (appearance.value.$1) {
    "dark" => ThemeMode.dark,
    "light" => ThemeMode.light,
    _ => ThemeMode.system,
  };

  void close() {
    if (_closed) return;
    _closed = true;
    playlists.abandonImport();
    backend.close();
    playback.close();
    persistence.close();
    for (final path in _privateExportSources.values) {
      unawaited(_removeUnreferencedFile(path));
    }
    // Running jobs observe cancellation at their next yt-dlp callback.
    services.downloads.shutdown();
    unawaited(_playbackSubscription.cancel());
    unawaited(_messages.close());
  }
}
