import "dart:async";
import "dart:math";

import "package:flutter/material.dart";
import "package:melody_audio/melody_audio.dart";

import "../application/download_report.dart";
import "../application/lyrics.dart";
import "../application/models.dart";
import "../application/playback.dart";
import "../audio/audio_backend.dart";
import "../core/errors.dart";
import "../services.dart";
import "controllers/home_controller.dart";
import "controllers/library_controller.dart";
import "controllers/playlists_controller.dart";
import "controllers/search_controller.dart";
import "controllers/settings_controller.dart";
import "shared/app_icon.dart";
import "shared/format.dart" show downloadReportMessage;

/// A listenable that fires on demand.
class Signal extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// A user-visible notification.
class AppMessage {
  const AppMessage(this.text, {this.error = false, this.action});

  final String text;
  final bool error;

  /// A button shown with the message, as (label, what it does).
  final (String, VoidCallback)? action;
}

/// Utility destinations shown beside or over the main content.
enum AppPanel { queue, lyrics, downloads, settings, player }

/// What to do with library tracks once they are available.
enum TrackAction { play, playNext, queue, addToPlaylist, favorite }

/// A follow-up applied once a requested download reaches a terminal state.
class PendingTrackAction {
  const PendingTrackAction(this.action, this.playlistId);

  final TrackAction action;
  final String? playlistId;
}

/// The UI's root state, created once [AppServices] are loaded.
///
/// Feature workflows live in the controllers it owns; this class connects
/// playback to the audio engine, keeps system media controls in sync, and
/// routes cross-feature events such as finished downloads.
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
    backend.callbacks
      ..onLoaded = playback.onLoaded
      ..onPosition = playback.onPosition
      ..onDuration = playback.onDuration
      ..onPlaying = playback.onPlaying
      ..onCompleted = playback.onCompleted
      ..onTrackChanged = playback.onTrackChanged
      ..onStopped = playback.onStopped
      ..onError = playback.onBackendError
      ..onMediaAction = _mediaAction;
    _playbackSubscription = playback.changes.listen(_playbackChanged);
    services.downloads.onRecord = _downloadChanged;
    home = HomeController(this);
    search = MusicSearchController(this);
    library = LibraryController(this);
    playlists = PlaylistsController(this);
    settingsDraft = SettingsController(this);
    // Leaving Settings without saving (close, Esc, back, another panel)
    // drops a theme or accent preview, as Cancel does.
    activePanel.addListener(() {
      if (activePanel.value != AppPanel.settings) {
        appearance.value = (settings.theme, settings.accentColor);
      }
    });
    final embedder = services.lyricsEmbedder;
    if (embedder != null) {
      embedder.isPlaying = (trackId) => playback.currentTrackId == trackId;
      embedder.embedLibrary();
    }
  }

  final AppServices services;
  final bool isMobile;

  /// The saved settings; drafts live in [settingsDraft] until saved.
  AppSettings get settings => _settings;
  set settings(AppSettings value) {
    _settings = value;
    AppIcon.apply(value.accentColor);
  }

  late AppSettings _settings;
  late final PlaybackPersistence persistence;
  late final NativeAudioBackend backend;
  late final PlaybackController playback;
  late final HomeController home;
  late final MusicSearchController search;
  late final LibraryController library;
  late final PlaylistsController playlists;
  late final SettingsController settingsDraft;
  late final StreamSubscription<PlaybackChange> _playbackSubscription;

  /// Track, transport, queue, and loading changes.
  final Signal playbackState = Signal();

  /// Position and duration ticks.
  final Signal playbackProgress = Signal();
  final Signal playbackVolume = Signal();

  // The engine reports position about once a second; views that move
  // continuously extrapolate from the last report.
  final Stopwatch _positionClock = Stopwatch()..start();
  late int _positionAnchorMs = playback.positionMs;
  int _positionAnchorAt = 0;

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
  String? _lastAnnouncedTrack;
  Object? _systemMediaKey;
  (String, String, String, String) _systemMediaMetadata = ("", "", "", "");
  bool _systemMediaFavorite = false;
  bool _closed = false;

  // -- notifications -------------------------------------------------------

  void showMessage(
    String message, {
    bool error = false,
    (String, VoidCallback)? action,
  }) {
    if (!_messages.isClosed) {
      _messages.add(AppMessage(message, error: error, action: action));
    }
  }

  void showError(String message) =>
      showMessage(publicErrorMessage(message), error: true);

  /// Reports an unexpected failure from a UI action.
  void reportFailure(Object error) {
    debugPrint("Action failed: $error");
    showError(failureMessage(error));
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
    // The queue and lyrics follow playback, so they stay open.
    if (!isMobile &&
        activePanel.value != AppPanel.queue &&
        activePanel.value != AppPanel.lyrics) {
      activePanel.value = null;
    }
  }

  void openPanel(AppPanel panel) => activePanel.value = panel;

  void closePanel() => activePanel.value = null;

  // -- playback and system media ------------------------------------------

  void _playbackChanged(PlaybackChange change) {
    if (change != PlaybackChange.volume) {
      _positionAnchorMs = playback.positionMs;
      _positionAnchorAt = _positionClock.elapsedMilliseconds;
    }
    // The engine publishes the timeline to system controls itself, so the
    // once-a-second progress reports need no session sync of their own.
    if (change != PlaybackChange.volume && change != PlaybackChange.progress) {
      syncSystemMedia(refreshMetadata: change == PlaybackChange.track);
    }
    if (change == PlaybackChange.track) {
      // Files skipped while they played can take their lyrics now.
      services.lyricsEmbedder?.retryDeferred();
      _saveLyrics([?playback.currentTrackId]);
    }
    switch (change) {
      case PlaybackChange.progress:
        playbackProgress.emit();
        return;
      case PlaybackChange.volume:
        playbackVolume.emit();
        return;
      case PlaybackChange.state ||
          PlaybackChange.track ||
          PlaybackChange.queue ||
          PlaybackChange.loading:
        break;
    }
    playbackState.emit();
    playbackProgress.emit();
    final current =
        playback.currentTrackId ??
        (playback.externalTitle.isNotEmpty
            ? "stream:${playback.externalTitle}"
            : null);
    if (settings.notifications &&
        playback.playing &&
        current != null &&
        current != _lastAnnouncedTrack) {
      _lastAnnouncedTrack = current;
      showMessage("Now playing: ${currentTitle()}");
    }
  }

  /// Whether the playback position is moving on its own.
  bool get positionAdvancing =>
      playback.playing && !playback.loading && playback.durationMs > 0;

  /// The playback position this frame, between the engine's reports. It
  /// runs at most a little past the last report, so a stalled stream does
  /// not drift away.
  int estimatedPositionMs() {
    if (!positionAdvancing) return playback.positionMs;
    final elapsed = _positionClock.elapsedMilliseconds - _positionAnchorAt;
    return min(
      playback.durationMs,
      _positionAnchorMs + min(elapsed, _maxExtrapolationMs),
    );
  }

  static const _maxExtrapolationMs = 1500;

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
        ? (
            "stream",
            playback.externalTitle,
            playback.externalUploader,
            playback.externalThumbnail,
          )
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
        hasMedia &&
        playback.currentTrackId != null &&
        playback.externalTitle.isEmpty;
    backend.syncMediaSession(
      MediaSessionState(
        title: hasMedia ? title : "",
        artist: artist,
        album: album,
        artworkUri: artworkUri,
        automaticFocalPoint: settings.autoFocalPointLiveNotifications,
        duration: Duration(milliseconds: playback.durationMs),
        position: Duration(milliseconds: playback.positionMs),
        playing: playback.playing,
        loading: playback.loading,
        // Skip buttons stay published even at the queue's ends (Next there
        // pauses and rewinds). Android fills a missing skip slot with a
        // custom shortcut, which would shift the notification's buttons.
        hasNext: hasMedia,
        hasPrevious: hasMedia,
        repeatMode: audioRepeatMode(playback.queue.repeat),
        canRepeat: libraryTrack && playback.queue.items.isNotEmpty,
        canShuffle: libraryTrack && playback.queue.upcomingCount >= 2,
        canFavorite: libraryTrack,
        favorite: libraryTrack && _systemMediaFavorite,
        shortcuts: _notificationShortcuts(settings.notificationActionPair),
        // A paused stream keeps its notification; only Stop clears it.
        keepAlive: hasMedia,
      ),
    );
  }

  static List<MediaShortcut> _notificationShortcuts(String pair) =>
      switch (pair) {
        "shuffle_repeat" => const [
          MediaShortcut.shuffle,
          MediaShortcut.repeat,
          MediaShortcut.favorite,
        ],
        "repeat_favorite" => const [
          MediaShortcut.repeat,
          MediaShortcut.favorite,
          MediaShortcut.shuffle,
        ],
        _ => const [
          MediaShortcut.shuffle,
          MediaShortcut.favorite,
          MediaShortcut.repeat,
        ],
      };

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
  void _mediaAction(MediaCommand command, int? seekPositionMs) {
    final libraryCurrent =
        playback.mediaSessionActive &&
        playback.externalTitle.isEmpty &&
        playback.currentTrackId != null;
    switch (command) {
      case MediaCommand.play:
        if (!playback.playing) playback.toggle();
      case MediaCommand.pause:
        if (playback.playing) playback.toggle();
      case MediaCommand.stop:
        playback.stop();
      case MediaCommand.skipToNext:
        playback.next();
      case MediaCommand.skipToPrevious:
        playback.previous();
      case MediaCommand.seekTo:
        if (seekPositionMs != null) playback.seek(seekPositionMs);
      case MediaCommand.rewind:
        playback.seek(playback.positionMs - 10000);
      case MediaCommand.fastForward:
        playback.seek(playback.positionMs + 10000);
      case MediaCommand.cycleRepeat:
        if (playback.mediaSessionActive && playback.queue.items.isNotEmpty) {
          playback.cycleRepeat();
        }
      case MediaCommand.shuffleUpcoming:
        if (libraryCurrent) playback.shuffleUpcoming();
      case MediaCommand.toggleFavorite:
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
  void reattachNativeState() {
    final state = backend.reattachNativeState();
    if (state != null) playback.onNativeReattach(state);
  }

  // -- downloads -----------------------------------------------------------

  void _downloadChanged(DownloadRecord record) {
    if (record.status == DownloadStatus.completed) {
      _saveLyrics(record.trackIds);
    }
    if (record.status.isFinished) {
      // Playing or importing a song already tells the user how it went.
      final reported =
          pendingDownloadActions.containsKey(record.id) ||
          playlists.ownsDownload(record.id);
      if (!reported) _downloadReporter.add(record);
      _finishPendingDownloadAction(record);
      touchLibrary();
      playlists.notifyDownloadChanged();
      _reportDownloads();
    }
  }

  final _downloadReporter = DownloadReporter();

  /// One message once the downloads settle, not one per song.
  void _reportDownloads() {
    final report = _downloadReporter.settle(
      active: services.downloads.activeCount(),
    );
    if (report == null) return;
    showMessage(
      downloadReportMessage(report),
      error: report.hasFailures,
      action: activePanel.value == AppPanel.downloads
          ? null
          : ("View", () => openPanel(AppPanel.downloads)),
    );
  }

  void _finishPendingDownloadAction(DownloadRecord record) {
    final pending = pendingDownloadActions.remove(record.id);
    if (pending == null) return;
    final generation = downloadPlayRequests.remove(record.id);
    final relevant =
        pending.action != TrackAction.play ||
        (generation != null && playback.isCurrentRequest(generation));
    if (!relevant) return;
    if (record.status == DownloadStatus.completed &&
        record.trackIds.any(services.manager.hasTrack)) {
      applyTrackAction(record.trackIds, pending.action, pending.playlistId);
      return;
    }
    if (pending.action == TrackAction.play) {
      // Leave the pending “Preparing track…” state; nothing will load.
      playback.onBackendError("Couldn’t play ${record.title}.");
      return;
    }
    showError("Couldn’t finish the requested action for ${record.title}.");
  }

  /// Applies a queue, playlist, favorite, or play action to library tracks.
  void applyTrackAction(
    List<String> trackIds,
    TrackAction action, [
    String? playlistId,
  ]) {
    final available = trackIds.where(services.manager.hasTrack).toList();
    if (available.isEmpty) return;
    switch (action) {
      case TrackAction.playNext:
        playback.addNextMany(available);
        showMessage("Ready to play next.");
      case TrackAction.queue:
        playback.addLastMany(available);
        showMessage("Added to the queue.");
      case TrackAction.addToPlaylist:
        if (playlistId == null) return;
        unawaited(
          run(() {
            services.manager.addTracksToPlaylist(playlistId, available);
            touchLibrary();
            showMessage("Added to playlist.");
          }),
        );
      case TrackAction.favorite:
        unawaited(
          run(() {
            services.library.favoriteTracks(available);
            touchLibrary();
            showMessage("Added to favorites.");
          }),
        );
      case TrackAction.play:
        final autoplay = playback.loading ? playback.playing : true;
        playback.playTracks(available);
        if (!autoplay) playback.toggle();
        showMessage("Preparing track…");
    }
  }

  /// Saves lyrics for library tracks in the background so they show
  /// offline: inside the audio file where Melody can rewrite it.
  void _saveLyrics(Iterable<String> trackIds) {
    if (_closed) return;
    final embedder = services.lyricsEmbedder;
    if (embedder != null) {
      embedder.embed(trackIds);
    } else {
      services.lyrics.prefetch([for (final id in trackIds) ?lyricsTrack(id)]);
    }
  }

  /// A library track's source and file, for lyrics lookups.
  LyricsTrack? lyricsTrack(String trackId) {
    if (!services.manager.hasTrack(trackId)) return null;
    try {
      return (
        source: services.manager.getTrack(trackId).source,
        path: services.manager.trackPath(trackId),
      );
    } on ArgumentError {
      // Its stored path is outside the music folders.
      return null;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    playlists.abandonImport();
    backend.close();
    playback.close();
    persistence.close();
    services.lyricsEmbedder?.close();
    // Running jobs observe cancellation at their next yt-dlp callback.
    services.downloads.shutdown();
    unawaited(_playbackSubscription.cancel());
    unawaited(_messages.close());
  }
}
