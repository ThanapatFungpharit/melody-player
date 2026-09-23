import "dart:async";

import "package:audioplayers/audioplayers.dart";
import "package:flet/flet.dart";
import "package:flutter/foundation.dart";
import "package:flutter_media_session/flutter_media_session.dart";

import "native_playback_registry.dart";

class BackgroundAudioSessionService extends FletService {
  BackgroundAudioSessionService({required super.control});

  final FlutterMediaSession _session = FlutterMediaSession();
  bool _active = false;
  bool _keepAlive = false;
  bool _disposed = false;
  (String, String, String, String, int)? _metadataSnapshot;
  (bool, bool, bool)? _actionsSnapshot;

  @override
  void init() {
    super.init();
    control.addInvokeMethodListener(_invokeMethod);
    _installActionHandler();
    // Apply the music audio context before Flet's Audio service creates its
    // native player. Android's player then owns audio focus and automatically
    // pauses/resumes for calls; iOS uses a playback session that survives lock.
    unawaited(_configureAudioContext());
  }

  void _installActionHandler() {
    _session.setActionHandler(
      onPlay: () => _handleAction("play"),
      onPause: () => _handleAction("pause"),
      onSkipToNext: () => _handleAction("skipToNext"),
      onSkipToPrevious: () => _handleAction("skipToPrevious"),
      onStop: () => _handleAction("stop"),
      onSeekTo: (position) => _handleAction("seekTo", seekPosition: position),
      onRewind: () => _handleAction("rewind"),
      onFastForward: () => _handleAction("fastForward"),
    );
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
        if (action == "stop") await _deactivate();
        return;
      }
    } catch (error) {
      debugPrint("BackgroundAudioSession: native action failed: $error");
    }
    // A queue-less preview may still need Python application policy (for
    // example Skip Next returning to the durable library queue).
    _sendAction(action, seekPosition: seekPosition);
  }

  Future<void> _configureAudioContext() async {
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            stayAwake: true,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gain,
          ),
          iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
        ),
      );
    } catch (error) {
      debugPrint("BackgroundAudioSession: audio context unavailable: $error");
    }
  }

  Future<void> _ensureActive() async {
    if (_active || _disposed) {
      return;
    }
    await _configureAudioContext();
    // Windows needs its identity before SMTC is initialized, otherwise the
    // first media flyout can label an unpackaged build as an unknown app.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _session.setWindowsAppUserModelId(
        "Melody.MusicPlayer",
        displayName: "Melody",
      );
    }
    // FlutterMediaSession.deactivate() intentionally clears this subscription,
    // so reinstall it whenever an inactive session is brought back.
    _installActionHandler();
    await _session.activate();
    // Match Melody's transport controls and keep skip behavior consistent on
    // Android notification controls, iOS lock screen, and desktop SMTC.
    await _session.setSkipIntervals(
      forwardSeconds: 10,
      backwardSeconds: 10,
    );
    // audioplayers already owns and handles audio focus. Enabling the media
    // shim's focus handler as well would make the two native focus requests
    // interrupt one another.
    await _session.setAutoHandleInterruptions(false);
    _active = true;
  }

  Future<dynamic> _invokeMethod(String name, dynamic args) async {
    switch (name) {
      case "sync":
        await _sync(Map<String, dynamic>.from(args as Map));
        return null;
      case "deactivate":
        await _deactivate();
        return null;
      default:
        throw Exception("Unknown BackgroundAudioSession method: $name");
    }
  }

  Future<void> _sync(Map<String, dynamic> data) async {
    if (_disposed) {
      return;
    }
    final reattach = data["reattach"] as bool? ?? false;
    if (reattach) {
      // activate() is idempotent when Android's MediaSessionService survived
      // an activity detach. Re-running the attachment also repairs action
      // handlers if the platform service was recreated while the page slept.
      _active = false;
      _metadataSnapshot = null;
      _actionsSnapshot = null;
    }
    await _ensureActive();
    final keepAlive = data["keep_alive"] as bool? ?? false;
    if (_keepAlive != keepAlive || reattach) {
      await _session.setBackgroundKeepAlive(keepAlive);
      _keepAlive = keepAlive;
    }
    final title = (data["title"] as String?)?.trim() ?? "";
    final artist = (data["artist"] as String?)?.trim();
    final album = (data["album"] as String?)?.trim();
    final artworkUri = (data["artwork_uri"] as String?)?.trim();
    final durationMs = (data["duration_ms"] as num?)?.toInt() ?? 0;
    final positionMs = (data["position_ms"] as num?)?.toInt() ?? 0;
    final playing = data["playing"] as bool? ?? false;
    final loading = data["loading"] as bool? ?? false;

    final metadataSnapshot = (
      title,
      artist ?? "",
      album ?? "",
      artworkUri ?? "",
      durationMs,
    );
    if (_metadataSnapshot != metadataSnapshot) {
      await FlutterMediaSessionPlatform.instance.updateMetadata(
        MediaMetadata(
          title: title.isEmpty ? "Melody" : title,
          artist: artist == null || artist.isEmpty ? "Unknown artist" : artist,
          album: album == null || album.isEmpty ? null : album,
          artworkUri:
              artworkUri == null || artworkUri.isEmpty ? null : artworkUri,
          duration: Duration(milliseconds: durationMs),
        ),
      );
      _metadataSnapshot = metadataSnapshot;
    }

    final hasNext = data["has_next"] as bool? ?? false;
    final hasPrevious = data["has_previous"] as bool? ?? false;
    final actionsSnapshot = (playing, hasNext, hasPrevious);
    if (_actionsSnapshot != actionsSnapshot) {
      final actions = <MediaAction>{
        if (playing) MediaAction.pause else MediaAction.play,
        MediaAction.stop,
        MediaAction.seekTo,
        MediaAction.rewind,
        MediaAction.fastForward,
        if (hasNext) MediaAction.skipToNext,
        if (hasPrevious) MediaAction.skipToPrevious,
      };
      await FlutterMediaSessionPlatform.instance
          .updateAvailableActions(actions);
      _actionsSnapshot = actionsSnapshot;
    }

    final repeatMode = switch (data["repeat_mode"] as String? ?? "off") {
      "track" => MediaRepeatMode.one,
      "playlist" => MediaRepeatMode.all,
      _ => MediaRepeatMode.none,
    };
    await FlutterMediaSessionPlatform.instance.updatePlaybackState(
      PlaybackState(
        status: loading
            ? PlaybackStatus.buffering
            : playing
                ? PlaybackStatus.playing
                : PlaybackStatus.paused,
        position: Duration(milliseconds: positionMs),
        speed: playing && !loading ? 1.0 : 0.0,
        repeatMode: repeatMode,
        shuffleModeEnabled: data["shuffle"] as bool? ?? false,
      ),
    );
  }

  void _sendAction(String action, {Duration? seekPosition}) {
    if (_disposed) {
      return;
    }
    control.triggerEvent("action", {
      "action": action,
      "seek_position_ms": seekPosition?.inMilliseconds,
    });
  }

  Future<void> _deactivate() async {
    if (!_active) {
      return;
    }
    if (_keepAlive) {
      await _session.setBackgroundKeepAlive(false);
      _keepAlive = false;
    }
    _active = false;
    await _session.deactivate();
    _metadataSnapshot = null;
    _actionsSnapshot = null;
  }

  @override
  void dispose() {
    _disposed = true;
    control.removeInvokeMethodListener(_invokeMethod);
    _session.clearActionHandler();
    if (_keepAlive) {
      _keepAlive = false;
      unawaited(
          _session.setBackgroundKeepAlive(false).catchError((Object _) {}));
    }
    unawaited(_session.deactivate().catchError((Object _) {}));
    super.dispose();
  }
}
