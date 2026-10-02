import "dart:async";

import "package:flutter/foundation.dart";
import "package:melody_audio/melody_audio.dart";

import "../core/storage.dart";

/// The decoder contract the playback controller drives.
abstract class TrackPlayerBackend {
  void load(String source, {bool autoplay = false, int positionMs = 0});
  void setQueue(
    List<Map<String, String>> items,
    int currentIndex, {
    required String repeatMode,
    bool autoplay = false,
    int positionMs = 0,
  });
  void updateQueue(
    List<Map<String, String>> items,
    int currentIndex, {
    required String repeatMode,
  });
  void play([int positionMs = 0]);
  void pause();
  void resume();
  void seek(int positionMs);
  void setVolume(double value);
  void cancelLoad();
  void discardSource();
}

/// Callbacks from the decoder, already filtered to the current generation.
class BackendCallbacks {
  void Function()? onLoaded;
  void Function(int positionMs)? onPosition;
  void Function(int durationMs)? onDuration;
  void Function(bool playing)? onPlaying;
  void Function()? onCompleted;
  void Function(String trackId, int index)? onTrackChanged;
  void Function()? onStopped;
  void Function(String message)? onError;
  void Function(String action, int? seekPositionMs)? onMediaAction;
}

/// Media-session snapshot published to lock-screen and notification controls.
class MediaSessionSnapshot {
  const MediaSessionSnapshot({
    required this.title,
    this.artist = "",
    this.album = "",
    this.artworkUri = "",
    this.autoFocalPoint = false,
    this.durationMs = 0,
    this.positionMs = 0,
    this.playing = false,
    this.loading = false,
    this.hasNext = true,
    this.hasPrevious = true,
    this.repeatMode = "off",
    this.canRepeat = false,
    this.canShuffle = false,
    this.canFavorite = false,
    this.favorite = false,
    this.notificationActionPair = "shuffle_favorite",
    this.keepAlive = false,
  });

  final String title;
  final String artist;
  final String album;
  final String artworkUri;
  final bool autoFocalPoint;
  final int durationMs;
  final int positionMs;
  final bool playing;
  final bool loading;
  final bool hasNext;
  final bool hasPrevious;
  final String repeatMode;
  final bool canRepeat;
  final bool canShuffle;
  final bool canFavorite;
  final bool favorite;
  final String notificationActionPair;
  final bool keepAlive;

  Map<String, Object?> toPayload() => {
    "title": title.trim(),
    "artist": artist,
    "album": album,
    "artwork_uri": artworkUri,
    "auto_focal_point_live_notifications": autoFocalPoint,
    "duration_ms": durationMs < 0 ? 0 : durationMs,
    "position_ms": positionMs < 0 ? 0 : positionMs,
    "playing": playing,
    "loading": loading,
    "has_next": hasNext,
    "has_previous": hasPrevious,
    "repeat_mode": repeatMode,
    "can_repeat": canRepeat,
    "can_shuffle": canShuffle,
    "can_favorite": canFavorite,
    "favorite": favorite,
    "notification_action_pair": notificationActionPair,
    "keep_alive": keepAlive,
  };
}

/// Generation-safe adapter around the process-scoped native player.
///
/// Every explicit request takes a new even generation; native queue
/// transitions use odd ones. Events from a superseded generation are
/// ignored. Source and transport commands are serialized separately so Pause
/// stays responsive while a replacement source prepares.
class NativeAudioBackend implements TrackPlayerBackend {
  NativeAudioBackend({
    NativeAudioRuntime? runtime,
    NativeMediaSessionRuntime? session,
    this.useDeviceVolume = false,
    this.operationTimeout = const Duration(seconds: 12),
  }) : _runtime = runtime ?? NativeAudioRuntime.instance,
       _session = session ?? NativeMediaSessionRuntime.instance {
    _runtime.attach(_onEvent);
    _session.attach(_onMediaAction);
  }

  final NativeAudioRuntime _runtime;
  final NativeMediaSessionRuntime _session;

  /// Phones use the system media volume; app volume only mutes there.
  final bool useDeviceVolume;
  final Duration operationTimeout;
  final BackendCallbacks callbacks = BackendCallbacks();

  int _generation = 0;
  int _completedGeneration = -1;
  bool _loaded = false;
  bool _hasActiveSource = false;
  bool _closing = false;
  bool _serviceFailed = false;
  int? _pendingPlayPosition;
  int? _pendingSeekPosition;
  Timer? _loadWatchdog;
  AsyncMutex _operations = AsyncMutex();
  AsyncMutex _transport = AsyncMutex();
  final AsyncMutex _media = AsyncMutex();
  int _mediaGeneration = 0;
  String? _mediaSnapshot;
  String? _mediaPendingSnapshot;
  bool _mediaSessionActive = false;
  bool _mediaReattachPending = false;

  void _onEvent(String name, Map<String, Object?> data) {
    if (_closing) return;
    final generation = (data["generation"] as num?)?.toInt();
    if (name == "track_change") {
      _trackChanged(data, generation ?? 0);
      return;
    }
    if (generation != _generation) return;
    switch (name) {
      case "loaded":
        _loadedEvent(generation!);
      case "position_change":
        callbacks.onPosition?.call((data["position"] as num?)?.toInt() ?? 0);
      case "duration_change":
        callbacks.onDuration?.call((data["duration"] as num?)?.toInt() ?? 0);
      case "state_change":
        _stateChanged("${data["state"]}", generation!);
      case "error":
        _cancelWatchdog();
        callbacks.onError?.call("${data["message"] ?? "Native audio playback failed"}");
    }
  }

  void _onMediaAction(String action, Duration? seekPosition) {
    if (_closing) return;
    callbacks.onMediaAction?.call(action, seekPosition?.inMilliseconds);
  }

  /// Adopts playback the native runtime retained, if any.
  Future<Map<String, Object?>?> reattachNativeState() async {
    if (_closing) return null;
    final state = Map<String, Object?>.from(
      await _runtime.invokeMethod("get_playback_state", null) as Map,
    );
    if (state["source"] == null || "${state["source"]}".isEmpty) return null;
    _generation = (state["generation"] as num?)?.toInt() ?? 0;
    _loaded = true;
    _hasActiveSource = true;
    _mediaReattachPending = true;
    return state;
  }

  /// Publishes a coherent snapshot to system controls, coalescing repeats.
  void syncMediaSession(MediaSessionSnapshot snapshot) {
    final payload = snapshot.toPayload();
    final key = payload.toString();
    if ((key == _mediaSnapshot && _mediaPendingSnapshot == null) ||
        key == _mediaPendingSnapshot ||
        _closing ||
        kIsWeb) {
      return;
    }
    // Keep the last published snapshot separate from the queued one so a
    // channel failure stays retryable.
    _mediaPendingSnapshot = key;
    final generation = ++_mediaGeneration;
    payload["reattach"] = _mediaReattachPending;
    unawaited(_media.run(() => _runMediaSync(generation, payload, key)));
  }

  Future<void> _runMediaSync(
    int generation,
    Map<String, Object?> payload,
    String key,
  ) async {
    if (_closing || generation != _mediaGeneration) return;
    try {
      if ("${payload["title"]}".isNotEmpty) {
        _mediaSessionActive = true;
        await _session.invokeMethod("sync", payload).timeout(operationTimeout);
      } else if (_mediaSessionActive) {
        await _session.deactivateForStop().timeout(operationTimeout);
        _mediaSessionActive = false;
      }
      if (generation == _mediaGeneration) {
        _mediaSnapshot = key;
        if (payload["reattach"] == true) _mediaReattachPending = false;
        if (_mediaPendingSnapshot == key) _mediaPendingSnapshot = null;
      }
    } catch (error) {
      if (generation == _mediaGeneration && _mediaPendingSnapshot == key) {
        _mediaPendingSnapshot = null;
      }
      // System controls never stop the actual audio path.
      debugPrint("Media-session synchronization failed: $error");
    }
  }

  /// Forces the next snapshot to republish after the app resumes.
  void invalidateMediaSession() {
    if (_closing) return;
    _mediaGeneration++;
    _mediaSnapshot = null;
    _mediaPendingSnapshot = null;
    _mediaReattachPending = true;
  }

  void _beginSource() {
    _serviceFailed = false;
    _cancelWatchdog();
    _nextGeneration();
    _resetQueues();
    _loaded = false;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
  }

  @override
  void setQueue(
    List<Map<String, String>> items,
    int currentIndex, {
    required String repeatMode,
    bool autoplay = false,
    int positionMs = 0,
  }) {
    if (_closing) return;
    _beginSource();
    final generation = _generation;
    _schedule(() => _runtime.invokeMethod("set_queue", {
      "items": items,
      "current_index": currentIndex,
      "generation": generation,
      "repeat_mode": repeatMode,
      "autoplay": autoplay,
      "position_ms": positionMs < 0 ? 0 : positionMs,
    }), generation);
    _watchLoad(generation, "The native playback queue did not respond.");
  }

  @override
  void updateQueue(
    List<Map<String, String>> items,
    int currentIndex, {
    required String repeatMode,
  }) {
    if (_closing || _serviceFailed) return;
    _schedule(() => _runtime.invokeMethod("update_queue", {
      "items": items,
      "current_index": currentIndex,
      "repeat_mode": repeatMode,
    }), _generation);
  }

  @override
  void load(String source, {bool autoplay = false, int positionMs = 0}) {
    if (_closing) return;
    // A new explicit selection is the retry boundary after a failure.
    _beginSource();
    final generation = _generation;
    _schedule(() => _runtime.invokeMethod("load_source", {
      "source": source,
      "generation": generation,
      "autoplay": autoplay,
      "position_ms": positionMs < 0 ? 0 : positionMs,
    }), generation);
    _watchLoad(
      generation,
      "The audio player did not respond. The playback service may have disconnected.",
    );
  }

  @override
  void play([int positionMs = 0]) {
    final position = positionMs < 0 ? 0 : positionMs;
    if (!_loaded) {
      _pendingPlayPosition = position;
      return;
    }
    _scheduleTransport("play", {"position": position});
  }

  @override
  void pause() {
    if (!_loaded) _pendingPlayPosition = null;
    _scheduleTransport("pause", null);
  }

  @override
  void resume() {
    if (!_loaded) _pendingPlayPosition = _pendingSeekPosition ?? 0;
    _scheduleTransport("resume", null);
  }

  @override
  void seek(int positionMs) {
    final position = positionMs < 0 ? 0 : positionMs;
    if (!_loaded) {
      _pendingSeekPosition = position;
      if (_pendingPlayPosition != null) _pendingPlayPosition = position;
      return;
    }
    _scheduleTransport("seek", {"position": position});
  }

  @override
  void setVolume(double value) {
    final gain = value.clamp(0.0, 1.0);
    _runtime.setVolume(useDeviceVolume ? (gain > 0 ? 1.0 : 0.0) : gain);
  }

  @override
  void cancelLoad() {
    if (_closing) return;
    _nextGeneration();
    _loaded = _hasActiveSource;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    _cancelWatchdog();
    _resetQueues();
    if (_serviceFailed) return;
    _bestEffort(() => _runtime.invokeMethod("cancel_load", null));
  }

  @override
  void discardSource() {
    _nextGeneration();
    _loaded = false;
    _hasActiveSource = false;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    _cancelWatchdog();
    _resetQueues();
    if (_closing || _serviceFailed) return;
    _bestEffort(() => _runtime.invokeMethod("clear_source", null));
  }

  /// Reconciles position and play state after the app resumes.
  Future<void> refreshState() async {
    if (_closing || !_loaded) return;
    final generation = _generation;
    try {
      final state = await _transport.run(
        () => _runtime.invokeMethod("get_playback_state", null),
      ).timeout(operationTimeout);
      if (_closing || generation != _generation || state is! Map) return;
      if (state["position_ms"] case final num position) {
        callbacks.onPosition?.call(position.toInt());
      }
      if (state["duration_ms"] case final num duration) {
        callbacks.onDuration?.call(duration.toInt());
      }
      if (state["playing"] case final bool playing) callbacks.onPlaying?.call(playing);
    } catch (error) {
      debugPrint("Native audio state refresh failed: $error");
    }
  }

  void close() {
    _closing = true;
    _serviceFailed = true;
    _nextGeneration();
    _mediaGeneration++;
    _mediaPendingSnapshot = null;
    _cancelWatchdog();
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    _runtime.detach(_onEvent);
    _session.detach(_onMediaAction);
  }

  void _loadedEvent(int generation) {
    _loaded = true;
    _hasActiveSource = true;
    _cancelWatchdog();
    callbacks.onLoaded?.call();
    final play = _pendingPlayPosition;
    final seek = _pendingSeekPosition;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    if (play != null) {
      _scheduleTransport("play", {"position": play});
    } else if (seek != null) {
      _scheduleTransport("seek", {"position": seek});
    }
  }

  void _stateChanged(String state, int generation) {
    if (state == "completed") {
      if (_completedGeneration == generation) return;
      _completedGeneration = generation;
      callbacks.onCompleted?.call();
      return;
    }
    if (state == "stopped") {
      _loaded = false;
      _hasActiveSource = false;
      callbacks.onStopped?.call();
      return;
    }
    // A replay without reload may complete again once playback restarts.
    if (state == "playing") _completedGeneration = -1;
    callbacks.onPlaying?.call(state == "playing");
  }

  void _trackChanged(Map<String, Object?> data, int generation) {
    if (generation <= _generation) return;
    _cancelWatchdog();
    _resetQueues();
    _generation = generation;
    _loaded = false;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    callbacks.onTrackChanged?.call(
      "${data["track_id"]}",
      (data["index"] as num?)?.toInt() ?? 0,
    );
    _watchLoad(generation, "The next track could not be prepared.");
  }

  void _watchLoad(int generation, String message) {
    _loadWatchdog = Timer(operationTimeout, () {
      if (generation == _generation && !_loaded && !_closing) {
        callbacks.onPlaying?.call(false);
        _failService(
          generation,
          "The track could not be loaded by the audio service. The file may "
          "be corrupted or encoded in an unsupported format.",
        );
      }
    });
  }

  void _cancelWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
  }

  void _nextGeneration() {
    // Native queue transitions use odd generations; explicit requests even.
    _generation = (_generation + 2) & ~1;
  }

  /// Obsolete commands cannot hold the next player's queue hostage.
  void _resetQueues() {
    _operations = AsyncMutex();
    _transport = AsyncMutex();
  }

  void _schedule(Future<Object?> Function() operation, int generation) {
    if (_closing || generation != _generation) return;
    final queue = _operations;
    unawaited(queue.run(() async {
      if (_closing || generation != _generation) return;
      try {
        await operation().timeout(operationTimeout);
      } catch (error) {
        debugPrint("Audio operation failed: $error");
        _failService(
          generation,
          "The audio player did not respond. The track may be unsupported or "
          "the playback service may have disconnected.",
        );
      }
    }));
  }

  void _scheduleTransport(String method, Map<String, Object?>? arguments) {
    final generation = _generation;
    if (_closing) return;
    final queue = _transport;
    unawaited(queue.run(() async {
      if (_closing || generation != _generation) return;
      try {
        await _runtime.invokeMethod(method, arguments).timeout(operationTimeout);
      } catch (error) {
        debugPrint("Audio transport operation failed: $error");
        _failService(
          generation,
          "The audio player did not respond. The track may be unsupported or "
          "the playback service may have disconnected.",
        );
      }
    }));
  }

  void _bestEffort(Future<Object?> Function() operation) {
    unawaited(() async {
      try {
        await operation().timeout(operationTimeout);
      } catch (error) {
        debugPrint("Audio cleanup operation failed: $error");
      }
    }());
  }

  /// One terminal failure per generation; recovery cleanup cannot recurse.
  void _failService(int generation, String message) {
    if (_closing || generation != _generation || _serviceFailed) return;
    _serviceFailed = true;
    _loaded = false;
    _hasActiveSource = false;
    _cancelWatchdog();
    callbacks.onError?.call(message);
  }
}
