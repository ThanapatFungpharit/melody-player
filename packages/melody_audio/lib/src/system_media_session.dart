import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_media_session/flutter_media_session.dart";

import "audio_engine.dart";
import "notification_artwork.dart";

/// Receives a system media command the engine could not satisfy alone.
typedef MediaActionListener =
    void Function(MediaCommand command, Duration? seekPosition);

/// Custom Android notification shortcuts, in order of preference. At most two
/// of the available ones are shown.
enum MediaShortcut { shuffle, repeat, favorite }

/// Artwork in the form the platform's media session can load. Android and the
/// web take URIs, but the Windows plugin opens only http(s) URIs or plain
/// paths, and the macOS one strips "file://" without decoding escapes.
@visibleForTesting
String? platformArtwork(String uri, {TargetPlatform? platform}) {
  if (uri.isEmpty) return null;
  if (kIsWeb || !uri.toLowerCase().startsWith("file:")) return uri;
  final target = platform ?? defaultTargetPlatform;
  final windows = target == TargetPlatform.windows;
  if (!windows && target != TargetPlatform.macOS) return uri;
  try {
    return Uri.parse(uri).toFilePath(windows: windows);
  } on UnsupportedError {
    return uri;
  }
}

/// The (at most two) shortcuts the Android notification shows. The first two
/// of [preference] are the chosen pair and keep their slots; a later one
/// stands in for an unavailable pick in that pick's slot, so a button never
/// slides to the other side while the queue changes.
@visibleForTesting
List<MediaShortcut> notificationShortcuts(
  List<MediaShortcut> preference,
  bool Function(MediaShortcut) available,
) {
  final pair = preference.take(2).toList();
  final spares = preference.skip(2).where(available).iterator;
  final shown = <MediaShortcut>[];
  for (final pick in pair) {
    if (available(pick)) {
      shown.add(pick);
    } else if (spares.moveNext()) {
      shown.add(spares.current);
    }
  }
  return shown;
}

/// What system controls show, with placeholders for empty fields.
MediaMetadata _metadata(
  String title,
  String artist,
  String album,
  String artworkUri,
  int durationMs,
) => MediaMetadata(
  title: title.isEmpty ? "Melody" : title,
  artist: artist.isEmpty ? "Unknown artist" : artist,
  album: album.isEmpty ? null : album,
  artworkUri: platformArtwork(artworkUri),
  duration: Duration(milliseconds: durationMs),
);

/// Everything lock-screen, notification, and desktop media controls show.
@immutable
class MediaSessionState {
  const MediaSessionState({
    required this.title,
    this.artist = "",
    this.album = "",
    this.artworkUri = "",
    this.automaticFocalPoint = false,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.playing = false,
    this.loading = false,
    this.hasNext = false,
    this.hasPrevious = false,
    this.repeatMode = AudioRepeatMode.off,
    this.canRepeat = false,
    this.canShuffle = false,
    this.canFavorite = false,
    this.favorite = false,
    this.shortcuts = const [
      MediaShortcut.shuffle,
      MediaShortcut.favorite,
      MediaShortcut.repeat,
    ],
    this.keepAlive = false,
  });

  /// An empty title releases the session.
  final String title;
  final String artist;
  final String album;
  final String artworkUri;

  /// Crop notification artwork around its salient subject instead of the
  /// center.
  final bool automaticFocalPoint;
  final Duration duration;
  final Duration position;
  final bool playing;
  final bool loading;
  final bool hasNext;
  final bool hasPrevious;
  final AudioRepeatMode repeatMode;
  final bool canRepeat;
  final bool canShuffle;
  final bool canFavorite;
  final bool favorite;
  final List<MediaShortcut> shortcuts;

  /// Keep the process alive in the background (a paused session included).
  final bool keepAlive;

  bool get isActive => title.trim().isNotEmpty;

  List<Object> get _fields => [
    title,
    artist,
    album,
    artworkUri,
    automaticFocalPoint,
    duration,
    position,
    playing,
    loading,
    hasNext,
    hasPrevious,
    repeatMode,
    canRepeat,
    canShuffle,
    canFavorite,
    favorite,
    ...shortcuts,
    keepAlive,
  ];

  @override
  bool operator ==(Object other) =>
      other is MediaSessionState && listEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);
}

/// Process-scoped system media session shared with the persistent decoder.
class SystemMediaSession {
  SystemMediaSession._();

  static final SystemMediaSession instance = SystemMediaSession._();
  MediaActionListener? _actionListener;

  final FlutterMediaSession _session = FlutterMediaSession();
  final NotificationArtwork _notificationArtwork = NotificationArtwork();
  bool _active = false;
  bool _keepAlive = false;
  Future<void>? _activationFuture;
  int _lifecycleEpoch = 0;
  StreamSubscription<MediaAction>? _actionSubscription;
  (String, String, String, String, int)? _metadataSnapshot;
  (bool, bool, bool, AudioRepeatMode, bool, bool, bool, bool, String)?
  _actionsSnapshot;
  int _nativePositionMs = 0;
  int _nativeDurationMs = 0;
  bool _nativePlaying = false;
  MediaRepeatMode _nativeRepeatMode = MediaRepeatMode.none;
  int _nativeMetadataToken = 0;
  bool _automaticFocalPoint = false;
  String _sourceArtworkUri = "";
  int _syncRevision = 0;
  int _nativeStateRevision = 0;
  bool _nativeStateObserved = false;
  Future<void> _syncTail = Future<void>.value();
  Future<void> _playbackStateTail = Future<void>.value();
  bool _nativeLoading = false;

  void attach(MediaActionListener listener) {
    _actionListener = listener;
  }

  void detach(MediaActionListener listener) {
    if (identical(_actionListener, listener)) _actionListener = null;
  }

  /// The metadata last published, with the app's artwork rather than the
  /// square notification copy.
  ({String title, String artist, String album, String artworkUri})
  get currentMetadata {
    final snapshot = _metadataSnapshot;
    return (
      title: snapshot?.$1 ?? "",
      artist: snapshot?.$2 ?? "",
      album: snapshot?.$3 ?? "",
      artworkUri: snapshot == null ? "" : _sourceArtworkUri,
    );
  }

  Future<void> _installActionHandler() async {
    await _actionSubscription?.cancel();
    _actionSubscription = FlutterMediaSessionPlatform.instance.onMediaAction
        .listen((action) {
          unawaited(
            _handleAction(action.name, seekPosition: action.seekPosition),
          );
        });
  }

  Future<void> _handleAction(String action, {Duration? seekPosition}) async {
    final command = MediaCommand.parse(action);
    if (command == null) return;
    if (command == MediaCommand.shuffleUpcoming ||
        command == MediaCommand.cycleRepeat) {
      // Windows flips its own shuffle and repeat toggles before reporting a
      // press. Melody's shuffle is one-shot and its repeat cycle is its own,
      // so put the toggles back to Melody's state; the app's next sync then
      // shows the new repeat mode.
      unawaited(
        _queuePlaybackState().catchError((Object error) {
          debugPrint("Media control state reset failed: $error");
        }),
      );
    }
    try {
      final handled = await AudioEngine.instance.handleMediaAction(
        command,
        seekPosition: seekPosition,
      );
      // The engine applied the action. Its Stop also releases this session
      // after the decoder is cleared and reports "stopped" to the app.
      if (handled) return;
    } catch (error) {
      debugPrint("SystemMediaSession: native action failed: $error");
    }
    // A queue-less preview may still need application policy (for
    // example Skip Next returning to the durable library queue).
    _sendAction(command, seekPosition: seekPosition);
  }

  Future<void> _ensureActive() async {
    if (_active) return;
    final active = _activationFuture;
    if (active != null) return active;
    final activation = _activate();
    _activationFuture = activation;
    try {
      await activation;
    } finally {
      if (identical(_activationFuture, activation)) _activationFuture = null;
    }
  }

  Future<void> _activate() async {
    // Windows needs its identity before SMTC is initialized, otherwise the
    // first media flyout can label an unpackaged build as an unknown app.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _session.setWindowsAppUserModelId(
        "Melody.MusicPlayer",
        displayName: "Melody",
      );
    }
    // Listen to the raw action stream so Android custom controls reach Melody.
    await _installActionHandler();
    await _session.activate();
    // Match Melody's 10-second skip buttons in macOS Now Playing. Only the
    // Darwin plugin implements skip intervals.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await _session.setSkipIntervals(forwardSeconds: 10, backwardSeconds: 10);
    }
    // just_audio and audio_session handle audio focus. Enabling the media
    // session's focus handler as well would make the two native focus requests
    // interrupt one another.
    await _session.setAutoHandleInterruptions(false);
    _active = true;
  }

  /// Start background retention with playback itself, independently of a
  /// later metadata sync from the app.
  Future<void> ensurePlaybackActive() async {
    if (kIsWeb) return;
    final epoch = _lifecycleEpoch;
    await _ensureActive();
    if (epoch != _lifecycleEpoch || !_active) return;
    if (!_keepAlive) {
      await _session.setBackgroundKeepAlive(true);
      _keepAlive = true;
    }
  }

  /// Publishes [state]. Syncs apply in order and a newer one supersedes any
  /// still in progress. [reattach] forces a full republish, for a session the
  /// OS may have dropped while the app was away.
  Future<void> sync(MediaSessionState state, {bool reattach = false}) async {
    final revision = ++_syncRevision;
    final sync = _syncTail.then((_) => _sync(state, reattach, revision));
    _syncTail = sync.catchError((Object _) {});
    await sync;
  }

  Future<void> _sync(
    MediaSessionState state,
    bool reattach,
    int revision,
  ) async {
    if (revision != _syncRevision) return;
    if (reattach) {
      _active = false;
      _metadataSnapshot = null;
      _actionsSnapshot = null;
    }
    await _ensureActive();
    if (revision != _syncRevision) return;
    final keepAlive = state.keepAlive;
    if (_keepAlive != keepAlive || reattach) {
      await _session.setBackgroundKeepAlive(keepAlive);
      _keepAlive = keepAlive;
    }
    if (revision != _syncRevision) return;
    final title = state.title.trim();
    final artist = state.artist.trim();
    final album = state.album.trim();
    final artworkUri = state.artworkUri.trim();
    final automaticFocalPoint = state.automaticFocalPoint;
    _automaticFocalPoint = automaticFocalPoint;
    final nativeStateRevision = _nativeStateRevision;
    Future<String>? preparingArtwork;
    var artworkPending = false;
    if (artworkUri.isNotEmpty) {
      preparingArtwork = _notificationArtwork.prepare(
        artworkUri,
        automatic: automaticFocalPoint,
      );
    }
    final preparedArtworkUri = preparingArtwork == null
        ? artworkUri
        : await preparingArtwork.timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              artworkPending = true;
              return artworkUri;
            },
          );
    if (revision != _syncRevision) return;
    // The app can deliver a snapshot that was queued before a native pause or
    // seek. Once the decoder has reported state, its timeline is authoritative.
    if (!_nativeStateObserved && nativeStateRevision == _nativeStateRevision) {
      _nativePositionMs = _nonNegative(state.position).inMilliseconds;
      _nativeDurationMs = _nonNegative(state.duration).inMilliseconds;
      _nativePlaying = state.playing;
      _nativeLoading = state.loading;
    }
    final durationMs = _nativeDurationMs;
    final currentPlaying = _nativePlaying;

    final metadataSnapshot = (
      title,
      artist,
      album,
      preparedArtworkUri,
      durationMs,
    );
    if (_metadataSnapshot != metadataSnapshot) {
      await FlutterMediaSessionPlatform.instance.updateMetadata(
        _metadata(title, artist, album, preparedArtworkUri, durationMs),
      );
      _metadataSnapshot = metadataSnapshot;
      _sourceArtworkUri = artworkUri;
      final token = ++_nativeMetadataToken;
      if (artworkPending) {
        // Slow remote artwork was published uncropped. Replace it once the
        // prepared copy is ready: a paused player sends no further syncs.
        unawaited(
          _publishPreparedArtwork(preparingArtwork!, token).catchError(
            (Object error) =>
                debugPrint("Prepared artwork update failed: $error"),
          ),
        );
      }
    }
    if (revision != _syncRevision) return;

    final repeat = state.repeatMode;
    final actionsSnapshot = (
      currentPlaying,
      state.hasNext,
      state.hasPrevious,
      repeat,
      state.canRepeat,
      state.canShuffle,
      state.canFavorite,
      state.favorite,
      state.shortcuts.join(","),
    );
    if (_actionsSnapshot != actionsSnapshot) {
      final shortcuts = <MediaAction>[];
      for (final shortcut in notificationShortcuts(
        state.shortcuts,
        (shortcut) => switch (shortcut) {
          MediaShortcut.shuffle => state.canShuffle,
          MediaShortcut.repeat => state.canRepeat,
          MediaShortcut.favorite => state.canFavorite,
        },
      )) {
        if (shortcut == MediaShortcut.shuffle) {
          shortcuts.add(
            MediaAction.custom(
              name: "shuffleUpcoming",
              customLabel: "Shuffle upcoming tracks",
              customIconResource: "ic_melody_shuffle",
            ),
          );
        } else if (shortcut == MediaShortcut.repeat) {
          shortcuts.add(
            MediaAction.custom(
              name: "cycleRepeat",
              customLabel: switch (repeat) {
                AudioRepeatMode.track => "Repeat track",
                AudioRepeatMode.queue => "Repeat queue",
                AudioRepeatMode.off => "Repeat off",
              },
              customIconResource: switch (repeat) {
                AudioRepeatMode.track => "ic_melody_repeat_one",
                AudioRepeatMode.queue => "ic_melody_repeat_all",
                AudioRepeatMode.off => "ic_melody_repeat_off",
              },
            ),
          );
        } else {
          shortcuts.add(
            MediaAction.custom(
              name: "toggleFavorite",
              customLabel: state.favorite ? "Remove favorite" : "Add favorite",
              customIconResource: state.favorite
                  ? "ic_melody_favorite_filled"
                  : "ic_melody_favorite_outline",
            ),
          );
        }
      }
      final actions = <MediaAction>{
        if (state.hasPrevious) MediaAction.skipToPrevious,
        if (currentPlaying) MediaAction.pause else MediaAction.play,
        if (state.hasNext) MediaAction.skipToNext,
        MediaAction.seekTo,
        if (defaultTargetPlatform == TargetPlatform.android) ...shortcuts,
        if (defaultTargetPlatform != TargetPlatform.android) ...[
          MediaAction.rewind,
          MediaAction.fastForward,
          // Windows and Apple have no custom buttons, but do have built-in
          // shuffle and repeat controls. Favorite has no counterpart.
          if (state.canShuffle) const MediaAction("shuffle"),
          if (state.canRepeat) const MediaAction("repeat"),
        ],
      };
      await FlutterMediaSessionPlatform.instance.updateAvailableActions(
        actions,
      );
      _actionsSnapshot = actionsSnapshot;
    }
    if (revision != _syncRevision) return;

    _nativeRepeatMode = switch (repeat) {
      AudioRepeatMode.track => MediaRepeatMode.one,
      AudioRepeatMode.queue => MediaRepeatMode.all,
      AudioRepeatMode.off => MediaRepeatMode.none,
    };
    await _queuePlaybackState();
  }

  /// Decoder events continue to update the system timeline while the app is
  /// suspended or its widget tree is being rebuilt.
  ///
  /// They are recorded even while the session is inactive or (re)activating:
  /// once the decoder has reported state, app snapshots no longer seed the
  /// timeline, so a dropped pause or track change would stay published.
  void onEngineEvent(AudioEngineEvent event) {
    switch (event) {
      case AudioPositionChanged(:final position):
        _nativePositionMs = position.inMilliseconds;
      case AudioDurationChanged(:final duration):
        _nativeDurationMs = duration.inMilliseconds;
        unawaited(
          _publishNativeMetadata(_nativeMetadataToken).catchError(
            (Object error) =>
                debugPrint("Native media metadata update failed: $error"),
          ),
        );
      case AudioStateChanged(:final state):
        switch (state) {
          case AudioPlaybackState.playing:
            _nativePlaying = true;
            _nativeLoading = false;
          case AudioPlaybackState.loading:
            _nativeLoading = true;
          case AudioPlaybackState.paused ||
              AudioPlaybackState.completed ||
              AudioPlaybackState.stopped:
            _nativePlaying = false;
            _nativeLoading = false;
        }
      case AudioFailed():
        _nativePlaying = false;
        _nativeLoading = false;
      case AudioTrackChanged():
        _nativePositionMs = 0;
        _nativeDurationMs = 0;
      case AudioLoaded():
        // Carries no timeline state and must not make an in-flight app
        // snapshot look superseded.
        return;
    }
    _nativeStateRevision++;
    _nativeStateObserved = true;
    // An activating session publishes the recorded state when its sync ends.
    if (!_active) return;
    unawaited(
      _queuePlaybackState().catchError((Object error) {
        debugPrint("Native media state update failed: $error");
      }),
    );
  }

  Future<void> _queuePlaybackState() {
    final update = _playbackStateTail.then(
      (_) => _publishNativePlaybackState(),
    );
    _playbackStateTail = update.catchError((Object _) {});
    return update;
  }

  Future<void> _publishNativePlaybackState() async {
    if (!_active) return;
    await FlutterMediaSessionPlatform.instance.updatePlaybackState(
      PlaybackState(
        status: _nativeLoading && _nativePlaying
            ? PlaybackStatus.buffering
            : _nativePlaying
            ? PlaybackStatus.playing
            : PlaybackStatus.paused,
        position: Duration(milliseconds: _nativePositionMs),
        // Media3 requires a positive playback speed even when paused. The
        // status freezes its timeline; a zero speed rejects the state update.
        speed: 1.0,
        repeatMode: _nativeRepeatMode,
      ),
    );
  }

  /// The engine advanced to another queue row by itself.
  void onEngineTrack({
    required String title,
    required String artist,
    required String album,
    required String artworkUri,
  }) {
    if (title.isEmpty) return;
    // The new row's timeline starts over even while the session activates;
    // its metadata comes from the app's next sync then.
    _nativeStateRevision++;
    _nativeStateObserved = true;
    _nativePositionMs = 0;
    _nativeDurationMs = 0;
    if (!_active) return;
    _syncRevision++;
    _metadataSnapshot = (title, artist, album, artworkUri, 0);
    _sourceArtworkUri = artworkUri;
    final token = ++_nativeMetadataToken;
    unawaited(
      _publishNativeMetadata(token).catchError(
        (Object error) =>
            debugPrint("Native media metadata update failed: $error"),
      ),
    );
  }

  Future<void> _publishPreparedArtwork(
    Future<String> preparing,
    int token,
  ) async {
    final prepared = await preparing;
    final snapshot = _metadataSnapshot;
    if (!_active ||
        snapshot == null ||
        token != _nativeMetadataToken ||
        prepared == snapshot.$4) {
      return;
    }
    _metadataSnapshot = (
      snapshot.$1,
      snapshot.$2,
      snapshot.$3,
      prepared,
      snapshot.$5,
    );
    _nativeMetadataToken++;
    await FlutterMediaSessionPlatform.instance.updateMetadata(
      _metadata(snapshot.$1, snapshot.$2, snapshot.$3, prepared, snapshot.$5),
    );
  }

  Future<void> _publishNativeMetadata(int token) async {
    final snapshot = _metadataSnapshot;
    if (!_active || snapshot == null || token != _nativeMetadataToken) return;
    final artworkUri = _sourceArtworkUri;
    final preparedArtwork = artworkUri.isEmpty
        ? null
        : await _notificationArtwork.prepare(
            artworkUri,
            automatic: _automaticFocalPoint,
          );
    if (!_active || token != _nativeMetadataToken) return;
    await FlutterMediaSessionPlatform.instance.updateMetadata(
      _metadata(
        snapshot.$1,
        snapshot.$2,
        snapshot.$3,
        preparedArtwork ?? "",
        _nativeDurationMs,
      ),
    );
  }

  /// Releases the session and its background keep-alive.
  Future<void> deactivateForStop() async {
    _syncRevision++;
    _lifecycleEpoch++;
    try {
      await _activationFuture;
    } catch (_) {
      // A failed activation must not prevent explicit Stop from releasing the
      // background lease and clearing the session.
    }
    await _deactivate();
  }

  void _sendAction(MediaCommand command, {Duration? seekPosition}) {
    _actionListener?.call(command, seekPosition);
  }

  Future<void> _deactivate() async {
    try {
      await _actionSubscription?.cancel();
    } catch (error) {
      debugPrint("SystemMediaSession: action cleanup failed: $error");
    }
    _actionSubscription = null;
    if (_keepAlive) {
      try {
        await _session.setBackgroundKeepAlive(false);
      } catch (error) {
        debugPrint("SystemMediaSession: keep-alive release failed: $error");
      }
      _keepAlive = false;
    }
    _nativeStateObserved = false;
    _nativePlaying = false;
    _nativeLoading = false;
    _nativePositionMs = 0;
    _nativeDurationMs = 0;
    _sourceArtworkUri = "";
    // Clear before the platform call: if it fails, the next activation must
    // still republish metadata and actions instead of trusting stale caches.
    _metadataSnapshot = null;
    _actionsSnapshot = null;
    if (!_active) return;
    _active = false;
    await _session.deactivate();
  }
}

Duration _nonNegative(Duration value) =>
    value < Duration.zero ? Duration.zero : value;
