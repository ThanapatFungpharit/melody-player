import "dart:async";

import "package:flet/flet.dart";
import "package:flutter/foundation.dart";
import "package:flutter_media_session/flutter_media_session.dart";

import "native_playback_registry.dart";
import "notification_artwork.dart";

/// Process-scoped media session shared with the persistent decoder.
class NativeMediaSessionRuntime {
  NativeMediaSessionRuntime._();

  static final NativeMediaSessionRuntime instance = NativeMediaSessionRuntime._();
  Control? _actionControl;

  final FlutterMediaSession _session = FlutterMediaSession();
  final NotificationArtwork _notificationArtwork = NotificationArtwork();
  bool _active = false;
  bool _keepAlive = false;
  bool _disposed = false;
  Future<void>? _activationFuture;
  int _lifecycleEpoch = 0;
  StreamSubscription<MediaAction>? _actionSubscription;
  (String, String, String, String, int)? _metadataSnapshot;
  (bool, bool, bool, String, bool, bool, bool, bool, String)? _actionsSnapshot;
  int _nativePositionMs = 0;
  int _nativeDurationMs = 0;
  bool _nativePlaying = false;
  MediaRepeatMode _nativeRepeatMode = MediaRepeatMode.none;
  int _nativeMetadataToken = 0;
  int _syncRevision = 0;
  int _nativeStateRevision = 0;
  bool _nativeStateObserved = false;
  Future<void> _syncTail = Future<void>.value();
  Future<void> _playbackStateTail = Future<void>.value();
  bool _nativeLoading = false;

  void attach(Control control) {
    _actionControl = control;
  }

  void detach(Control control) {
    if (identical(_actionControl, control)) _actionControl = null;
  }

  Map<String, String> get currentMetadata {
    final snapshot = _metadataSnapshot;
    return <String, String>{
      "title": snapshot?.$1 ?? "",
      "artist": snapshot?.$2 ?? "",
      "album": snapshot?.$3 ?? "",
      "artwork_uri": snapshot?.$4 ?? "",
    };
  }

  Future<void> _installActionHandler() async {
    await _actionSubscription?.cancel();
    if (_disposed) return;
    _actionSubscription =
        FlutterMediaSessionPlatform.instance.onMediaAction.listen((action) {
      unawaited(_handleAction(action.name, seekPosition: action.seekPosition));
    });
  }

  Future<void> _handleAction(
    String action, {
    Duration? seekPosition,
  }) async {
    if (_disposed) return;
    try {
      final handled = await activeNativePlaybackEngine?.handleMediaAction(
            action,
            seekPosition: seekPosition,
          ) ??
          false;
      if (handled) {
        // A native Stop event is also reported to the Python controller. Let
        // its normal state sync remove the session after this callback returns;
        // stopping the Android service here can terminate the background app.
        return;
      }
    } catch (error) {
      debugPrint("BackgroundAudioSession: native action failed: $error");
    }
    // A queue-less preview may still need Python application policy (for
    // example Skip Next returning to the durable library queue).
    _sendAction(action, seekPosition: seekPosition);
  }

  Future<void> _ensureActive() async {
    if (_active || _disposed) return;
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
    if (_disposed) return;
    await _session.activate();
    // Match Melody's transport controls and keep skip behavior consistent on
    // Android notification controls, iOS lock screen, and desktop SMTC.
    await _session.setSkipIntervals(
      forwardSeconds: 10,
      backwardSeconds: 10,
    );
    // just_audio and audio_session handle audio focus. Enabling the media
    // session's focus handler as well would make the two native focus requests
    // interrupt one another.
    await _session.setAutoHandleInterruptions(false);
    _active = true;
  }

  /// Start background retention with playback itself, independently of a
  /// later Python metadata sync.
  Future<void> ensurePlaybackActive() async {
    if (kIsWeb || _disposed) return;
    final epoch = _lifecycleEpoch;
    await _ensureActive();
    if (epoch != _lifecycleEpoch || !_active) return;
    if (!_keepAlive) {
      await _session.setBackgroundKeepAlive(true);
      _keepAlive = true;
    }
  }

  Future<dynamic> invokeMethod(String name, dynamic args) async {
    switch (name) {
      case "sync":
        final data = Map<String, dynamic>.from(args as Map);
        final revision = ++_syncRevision;
        final sync = _syncTail.then((_) => _sync(data, revision));
        _syncTail = sync.catchError((Object _) {});
        await sync;
        return null;
      case "deactivate":
        await deactivateForStop();
        return null;
      default:
        throw Exception("Unknown BackgroundAudioSession method: $name");
    }
  }

  Future<void> _sync(Map<String, dynamic> data, int revision) async {
    if (_disposed || revision != _syncRevision) {
      return;
    }
    final reattach = data["reattach"] as bool? ?? false;
    if (reattach) {
      _active = false;
      _metadataSnapshot = null;
      _actionsSnapshot = null;
    }
    await _ensureActive();
    if (revision != _syncRevision) return;
    final keepAlive = data["keep_alive"] as bool? ?? false;
    if (_keepAlive != keepAlive || reattach) {
      await _session.setBackgroundKeepAlive(keepAlive);
      _keepAlive = keepAlive;
    }
    if (revision != _syncRevision) return;
    final title = (data["title"] as String?)?.trim() ?? "";
    final artist = (data["artist"] as String?)?.trim();
    final album = (data["album"] as String?)?.trim();
    final artworkUri = (data["artwork_uri"] as String?)?.trim();
    final automaticFocalPoint =
        data["auto_focal_point_live_notifications"] as bool? ?? false;
    final nativeStateRevision = _nativeStateRevision;
    final preparedArtworkUri = artworkUri == null || artworkUri.isEmpty
        ? artworkUri
        : await _notificationArtwork.prepare(artworkUri,
            automatic: automaticFocalPoint)
            .timeout(const Duration(seconds: 2), onTimeout: () => artworkUri);
    if (revision != _syncRevision) return;
    final reportedDurationMs = (data["duration_ms"] as num?)?.toInt() ?? 0;
    final reportedPositionMs = (data["position_ms"] as num?)?.toInt() ?? 0;
    final playing = data["playing"] as bool? ?? false;
    final loading = data["loading"] as bool? ?? false;
    // Python can deliver a snapshot that was queued before a native pause or
    // seek. Once the decoder has reported state, its timeline is authoritative.
    if (!_nativeStateObserved && nativeStateRevision == _nativeStateRevision) {
      _nativePositionMs = reportedPositionMs;
      _nativeDurationMs = reportedDurationMs;
      _nativePlaying = playing;
      _nativeLoading = loading;
    }
    final durationMs = _nativeDurationMs;
    final currentPlaying = _nativePlaying;

    final metadataSnapshot = (
      title,
      artist ?? "",
      album ?? "",
      preparedArtworkUri ?? "",
      durationMs,
    );
    if (_metadataSnapshot != metadataSnapshot) {
      await FlutterMediaSessionPlatform.instance.updateMetadata(
        MediaMetadata(
          title: title.isEmpty ? "Melody" : title,
          artist: artist == null || artist.isEmpty ? "Unknown artist" : artist,
          album: album == null || album.isEmpty ? null : album,
          artworkUri: preparedArtworkUri == null || preparedArtworkUri.isEmpty
              ? null
              : preparedArtworkUri,
          duration: Duration(milliseconds: durationMs),
        ),
      );
      _metadataSnapshot = metadataSnapshot;
      _nativeMetadataToken++;
    }
    if (revision != _syncRevision) return;

    final hasNext = data["has_next"] as bool? ?? false;
    final hasPrevious = data["has_previous"] as bool? ?? false;
    final repeat = data["repeat_mode"] as String? ?? "off";
    final canRepeat = data["can_repeat"] as bool? ?? false;
    final canShuffle = data["can_shuffle"] as bool? ?? false;
    final canFavorite = data["can_favorite"] as bool? ?? false;
    final favorite = data["favorite"] as bool? ?? false;
    final notificationActionPair =
        data["notification_action_pair"] as String? ?? "shuffle_favorite";
    final actionsSnapshot = (
      currentPlaying,
      hasNext,
      hasPrevious,
      repeat,
      canRepeat,
      canShuffle,
      canFavorite,
      favorite,
      notificationActionPair,
    );
    if (_actionsSnapshot != actionsSnapshot) {
      final orderedShortcuts = switch (notificationActionPair) {
        "shuffle_repeat" => ["shuffle", "repeat", "favorite"],
        "repeat_favorite" => ["repeat", "favorite", "shuffle"],
        _ => ["shuffle", "favorite", "repeat"],
      };
      final shortcuts = <MediaAction>[];
      for (final shortcut in orderedShortcuts) {
        if (shortcuts.length == 2) break;
        if (shortcut == "shuffle" && canShuffle) {
          shortcuts.add(MediaAction.custom(
            name: "shuffleUpcoming",
            customLabel: "Shuffle upcoming tracks",
            customIconResource: "ic_melody_shuffle",
          ));
        } else if (shortcut == "repeat" && canRepeat) {
          shortcuts.add(MediaAction.custom(
            name: "cycleRepeat",
            customLabel: switch (repeat) {
              "track" => "Repeat track",
              "playlist" => "Repeat queue",
              _ => "Repeat off",
            },
            customIconResource: switch (repeat) {
              "track" => "ic_melody_repeat_one",
              "playlist" => "ic_melody_repeat_all",
              _ => "ic_melody_repeat_off",
            },
          ));
        } else if (shortcut == "favorite" && canFavorite) {
          shortcuts.add(MediaAction.custom(
            name: "toggleFavorite",
            customLabel: favorite ? "Remove favorite" : "Add favorite",
            customIconResource: favorite
                ? "ic_melody_favorite_filled"
                : "ic_melody_favorite_outline",
          ));
        }
      }
      final actions = <MediaAction>{
        if (hasPrevious) MediaAction.skipToPrevious,
        if (currentPlaying) MediaAction.pause else MediaAction.play,
        if (hasNext) MediaAction.skipToNext,
        MediaAction.seekTo,
        if (defaultTargetPlatform == TargetPlatform.android) ...shortcuts,
        if (defaultTargetPlatform != TargetPlatform.android) MediaAction.rewind,
        if (defaultTargetPlatform != TargetPlatform.android)
          MediaAction.fastForward,
      };
      await FlutterMediaSessionPlatform.instance
          .updateAvailableActions(actions);
      _actionsSnapshot = actionsSnapshot;
    }
    if (revision != _syncRevision) return;

    final repeatMode = switch (repeat) {
      "track" => MediaRepeatMode.one,
      "playlist" => MediaRepeatMode.all,
      _ => MediaRepeatMode.none,
    };
    _nativeRepeatMode = repeatMode;
    await _queuePlaybackState();
  }

  /// Decoder events continue to update the system timeline while Python is
  /// suspended or a Flet page is being replaced.
  void onNativePlaybackEvent(String name, dynamic value) {
    if (!_active || value is! Map) return;
    _nativeStateRevision++;
    final data = Map<String, dynamic>.from(value);
    if (name == "position_change") {
      _nativePositionMs = (data["position"] as num?)?.toInt() ?? _nativePositionMs;
    } else if (name == "duration_change") {
      _nativeDurationMs = (data["duration"] as num?)?.toInt() ?? _nativeDurationMs;
      unawaited(_publishNativeMetadata(_nativeMetadataToken).catchError(
        (Object error) => debugPrint("Native media metadata update failed: $error"),
      ));
    } else if (name == "state_change") {
      final state = data["state"] as String?;
      if (state == "playing") {
        _nativePlaying = true;
        _nativeLoading = false;
      }
      if (state == "loading") _nativeLoading = true;
      if (state == "paused" || state == "completed" || state == "stopped") {
        _nativePlaying = false;
        _nativeLoading = false;
      }
    } else if (name == "error") {
      _nativePlaying = false;
      _nativeLoading = false;
    } else if (name == "track_change") {
      _nativePositionMs = 0;
      _nativeDurationMs = 0;
    } else {
      return;
    }
    _nativeStateObserved = true;
    unawaited(_queuePlaybackState().catchError((Object error) {
      debugPrint("Native media state update failed: $error");
    }));
  }

  Future<void> _queuePlaybackState() {
    final update = _playbackStateTail.then((_) => _publishNativePlaybackState());
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

  void onNativeTrack({
    required String title,
    required String artist,
    required String album,
    required String artworkUri,
  }) {
    if (!_active || title.isEmpty) return;
    _syncRevision++;
    _nativeStateRevision++;
    _nativeStateObserved = true;
    _nativePositionMs = 0;
    _nativeDurationMs = 0;
    _metadataSnapshot = (title, artist, album, artworkUri, 0);
    final token = ++_nativeMetadataToken;
    unawaited(_publishNativeMetadata(token).catchError(
      (Object error) => debugPrint("Native media metadata update failed: $error"),
    ));
  }

  Future<void> _publishNativeMetadata(int token) async {
    final snapshot = _metadataSnapshot;
    if (!_active || snapshot == null || token != _nativeMetadataToken) return;
    final artworkUri = snapshot.$4;
    final preparedArtwork = artworkUri.isEmpty
        ? null
        : await _notificationArtwork.prepare(artworkUri, automatic: false);
    if (!_active || token != _nativeMetadataToken) return;
    await FlutterMediaSessionPlatform.instance.updateMetadata(
      MediaMetadata(
        title: snapshot.$1,
        artist: snapshot.$2.isEmpty ? "Unknown artist" : snapshot.$2,
        album: snapshot.$3.isEmpty ? null : snapshot.$3,
        artworkUri: preparedArtwork,
        duration: Duration(milliseconds: _nativeDurationMs),
      ),
    );
  }

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

  void _sendAction(String action, {Duration? seekPosition}) {
    if (_disposed) {
      return;
    }
    _actionControl?.triggerEvent("action", {
      "action": action,
      "seek_position_ms": seekPosition?.inMilliseconds,
    });
  }

  Future<void> _deactivate() async {
    try {
      await _actionSubscription?.cancel();
    } catch (error) {
      debugPrint("BackgroundAudioSession: action cleanup failed: $error");
    }
    _actionSubscription = null;
    if (_keepAlive) {
      try {
        await _session.setBackgroundKeepAlive(false);
      } catch (error) {
        debugPrint("BackgroundAudioSession: keep-alive release failed: $error");
      }
      _keepAlive = false;
    }
    _nativeStateObserved = false;
    _nativePlaying = false;
    _nativeLoading = false;
    _nativePositionMs = 0;
    _nativeDurationMs = 0;
    if (!_active) return;
    _active = false;
    await _session.deactivate();
    _metadataSnapshot = null;
    _actionsSnapshot = null;
  }

}

/// Only the Flet command and event bridge follows the page lifecycle.
class BackgroundAudioSessionService extends FletService {
  BackgroundAudioSessionService({required super.control});

  final NativeMediaSessionRuntime _runtime = NativeMediaSessionRuntime.instance;

  @override
  void init() {
    super.init();
    control.addInvokeMethodListener(_runtime.invokeMethod);
    _runtime.attach(control);
  }

  @override
  void dispose() {
    control.removeInvokeMethodListener(_runtime.invokeMethod);
    _runtime.detach(control);
    super.dispose();
  }
}
