import "dart:async";

import "package:flutter/foundation.dart";
import "package:melody_audio/melody_audio.dart";

import "../application/models.dart";
import "../core/storage.dart";

/// The decoder contract the playback controller drives.
abstract class TrackPlayerBackend {
  /// [gain] is the source's loudness normalization factor (0 to 1).
  void load(
    String source, {
    bool autoplay = false,
    int positionMs = 0,
    double gain = 1,
  });
  void setQueue(
    List<AudioQueueItem> items,
    int currentIndex, {
    required RepeatMode repeat,
    bool autoplay = false,
    int positionMs = 0,
  });
  void updateQueue(
    List<AudioQueueItem> items,
    int currentIndex, {
    required RepeatMode repeat,
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
  void Function(MediaCommand command, int? seekPositionMs)? onMediaAction;
}

/// How far, in dB, the audio engine can raise a quiet track on this
/// platform (0 where it can only attenuate).
double get audioMaxBoostDb => AudioEngine.maxBoostDb;

AudioRepeatMode audioRepeatMode(RepeatMode mode) => switch (mode) {
  RepeatMode.off => AudioRepeatMode.off,
  RepeatMode.track => AudioRepeatMode.track,
  RepeatMode.playlist => AudioRepeatMode.queue,
};

/// Generation-safe adapter around the process-scoped [AudioEngine].
///
/// Every explicit request takes a new even generation; native queue
/// transitions use odd ones. Events from a superseded generation are
/// ignored. Source and transport commands are serialized separately so Pause
/// stays responsive while a replacement source prepares.
class NativeAudioBackend implements TrackPlayerBackend {
  NativeAudioBackend({
    AudioEngine? engine,
    SystemMediaSession? session,
    this.useDeviceVolume = false,
    this.operationTimeout = const Duration(seconds: 12),
  }) : _engine = engine ?? AudioEngine.instance,
       _session = session ?? SystemMediaSession.instance {
    _engine.attach(_onEvent);
    _session.attach(_onMediaAction);
  }

  final AudioEngine _engine;
  final SystemMediaSession _session;

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
  MediaSessionState? _mediaPublished;
  MediaSessionState? _mediaPending;
  bool _mediaSessionActive = false;
  bool _mediaReattachPending = false;

  void _onEvent(AudioEngineEvent event) {
    if (_closing) return;
    if (event is AudioTrackChanged) {
      _trackChanged(event);
      return;
    }
    if (event.generation != _generation) return;
    switch (event) {
      case AudioLoaded():
        _loadedEvent();
      case AudioPositionChanged(:final position):
        callbacks.onPosition?.call(position.inMilliseconds);
      case AudioDurationChanged(:final duration):
        callbacks.onDuration?.call(duration.inMilliseconds);
      case AudioStateChanged(:final state):
        _stateChanged(state, event.generation);
      case AudioFailed(:final message):
        _cancelWatchdog();
        callbacks.onError?.call(message);
      case AudioTrackChanged():
        break;
    }
  }

  void _onMediaAction(MediaCommand command, Duration? seekPosition) {
    if (_closing) return;
    callbacks.onMediaAction?.call(command, seekPosition?.inMilliseconds);
  }

  /// Adopts playback the engine retained across a widget-tree rebuild.
  AudioEngineSnapshot? reattachNativeState() {
    if (_closing) return null;
    final state = _engine.snapshot();
    if (!state.hasSource) return null;
    _generation = state.generation;
    _loaded = true;
    _hasActiveSource = true;
    _mediaReattachPending = true;
    return state;
  }

  /// Publishes a coherent snapshot to system controls, coalescing repeats.
  void syncMediaSession(MediaSessionState state) {
    if ((state == _mediaPublished && _mediaPending == null) ||
        state == _mediaPending ||
        _closing ||
        kIsWeb) {
      return;
    }
    // Keep the last published snapshot separate from the queued one so a
    // channel failure stays retryable.
    _mediaPending = state;
    final generation = ++_mediaGeneration;
    final reattach = _mediaReattachPending;
    unawaited(_media.run(() => _runMediaSync(generation, state, reattach)));
  }

  Future<void> _runMediaSync(
    int generation,
    MediaSessionState state,
    bool reattach,
  ) async {
    if (_closing || generation != _mediaGeneration) return;
    try {
      if (state.isActive) {
        _mediaSessionActive = true;
        await _session
            .sync(state, reattach: reattach)
            .timeout(operationTimeout);
      } else if (_mediaSessionActive) {
        await _session.deactivateForStop().timeout(operationTimeout);
        _mediaSessionActive = false;
      }
      if (generation == _mediaGeneration) {
        _mediaPublished = state;
        if (reattach) _mediaReattachPending = false;
        if (_mediaPending == state) _mediaPending = null;
      }
    } catch (error) {
      if (generation == _mediaGeneration && _mediaPending == state) {
        _mediaPending = null;
      }
      // System controls never stop the actual audio path.
      debugPrint("Media-session synchronization failed: $error");
    }
  }

  /// Forces the next snapshot to republish after the app resumes.
  void invalidateMediaSession() {
    if (_closing) return;
    _mediaGeneration++;
    _mediaPublished = null;
    _mediaPending = null;
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
    List<AudioQueueItem> items,
    int currentIndex, {
    required RepeatMode repeat,
    bool autoplay = false,
    int positionMs = 0,
  }) {
    if (_closing) return;
    _beginSource();
    final generation = _generation;
    _schedule(
      () => _engine.setQueue(
        items,
        currentIndex: currentIndex,
        generation: generation,
        repeatMode: audioRepeatMode(repeat),
        autoplay: autoplay,
        position: _milliseconds(positionMs),
      ),
      generation,
    );
    _watchLoad(generation);
  }

  @override
  void updateQueue(
    List<AudioQueueItem> items,
    int currentIndex, {
    required RepeatMode repeat,
  }) {
    if (_closing || _serviceFailed) return;
    _schedule(
      () => _engine.updateQueue(
        items,
        currentIndex: currentIndex,
        repeatMode: audioRepeatMode(repeat),
      ),
      _generation,
    );
  }

  @override
  void load(
    String source, {
    bool autoplay = false,
    int positionMs = 0,
    double gain = 1,
  }) {
    if (_closing) return;
    // A new explicit selection is the retry boundary after a failure.
    _beginSource();
    final generation = _generation;
    _schedule(
      () => _engine.loadSource(
        source,
        generation: generation,
        autoplay: autoplay,
        position: _milliseconds(positionMs),
        gain: gain,
      ),
      generation,
    );
    _watchLoad(generation);
  }

  @override
  void play([int positionMs = 0]) {
    final position = positionMs < 0 ? 0 : positionMs;
    if (!_loaded) {
      _pendingPlayPosition = position;
      return;
    }
    _scheduleTransport(() => _engine.play(position: _milliseconds(position)));
  }

  @override
  void pause() {
    if (!_loaded) _pendingPlayPosition = null;
    _scheduleTransport(_engine.pause);
  }

  @override
  void resume() {
    if (!_loaded) _pendingPlayPosition = _pendingSeekPosition ?? 0;
    _scheduleTransport(_engine.resume);
  }

  @override
  void seek(int positionMs) {
    final position = positionMs < 0 ? 0 : positionMs;
    if (!_loaded) {
      _pendingSeekPosition = position;
      if (_pendingPlayPosition != null) _pendingPlayPosition = position;
      return;
    }
    _scheduleTransport(() => _engine.seek(_milliseconds(position)));
  }

  @override
  void setVolume(double value) {
    final gain = value.clamp(0.0, 1.0);
    _engine.setVolume(useDeviceVolume ? (gain > 0 ? 1.0 : 0.0) : gain);
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
    _engine.cancelLoad();
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
    _bestEffort(_engine.clearSource);
  }

  /// Reconciles position and play state after the app resumes.
  Future<void> refreshState() async {
    if (_closing || !_loaded) return;
    final generation = _generation;
    try {
      final state = await _transport
          .run(_engine.snapshot)
          .timeout(operationTimeout);
      if (_closing || generation != _generation) return;
      if (state.position case final position?) {
        callbacks.onPosition?.call(position.inMilliseconds);
      }
      if (state.duration case final duration?) {
        callbacks.onDuration?.call(duration.inMilliseconds);
      }
      callbacks.onPlaying?.call(state.playing);
    } catch (error) {
      debugPrint("Native audio state refresh failed: $error");
    }
  }

  void close() {
    _closing = true;
    _serviceFailed = true;
    _nextGeneration();
    _mediaGeneration++;
    _mediaPending = null;
    _cancelWatchdog();
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    _engine.detach(_onEvent);
    _session.detach(_onMediaAction);
  }

  void _loadedEvent() {
    _loaded = true;
    _hasActiveSource = true;
    _cancelWatchdog();
    callbacks.onLoaded?.call();
    final play = _pendingPlayPosition;
    final seek = _pendingSeekPosition;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    if (play != null) {
      _scheduleTransport(() => _engine.play(position: _milliseconds(play)));
    } else if (seek != null) {
      _scheduleTransport(() => _engine.seek(_milliseconds(seek)));
    }
  }

  void _stateChanged(AudioPlaybackState state, int generation) {
    switch (state) {
      case AudioPlaybackState.completed:
        if (_completedGeneration == generation) return;
        _completedGeneration = generation;
        callbacks.onCompleted?.call();
      case AudioPlaybackState.stopped:
        _loaded = false;
        _hasActiveSource = false;
        callbacks.onStopped?.call();
      case AudioPlaybackState.playing:
        // A replay without reload may complete again once playback restarts.
        _completedGeneration = -1;
        callbacks.onPlaying?.call(true);
      case AudioPlaybackState.paused:
        callbacks.onPlaying?.call(false);
      case AudioPlaybackState.loading:
        // Only the system media session shows buffering.
        break;
    }
  }

  void _trackChanged(AudioTrackChanged event) {
    if (event.generation <= _generation) return;
    _cancelWatchdog();
    _resetQueues();
    _generation = event.generation;
    _loaded = false;
    _pendingPlayPosition = null;
    _pendingSeekPosition = null;
    callbacks.onTrackChanged?.call(event.trackId, event.index);
    _watchLoad(event.generation);
  }

  void _watchLoad(int generation) {
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

  void _schedule(Future<void> Function() operation, int generation) {
    if (_closing || generation != _generation) return;
    final queue = _operations;
    unawaited(
      queue.run(() async {
        if (_closing || generation != _generation) return;
        try {
          await operation().timeout(operationTimeout);
        } catch (error) {
          debugPrint("Audio operation failed: $error");
          _failService(generation, _unresponsive);
        }
      }),
    );
  }

  void _scheduleTransport(Future<void> Function() operation) {
    final generation = _generation;
    if (_closing) return;
    final queue = _transport;
    unawaited(
      queue.run(() async {
        if (_closing || generation != _generation) return;
        try {
          await operation().timeout(operationTimeout);
        } catch (error) {
          debugPrint("Audio transport operation failed: $error");
          _failService(generation, _unresponsive);
        }
      }),
    );
  }

  void _bestEffort(Future<void> Function() operation) {
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

const _unresponsive =
    "The audio player did not respond. The track may be unsupported or "
    "the playback service may have disconnected.";

Duration _milliseconds(int value) =>
    Duration(milliseconds: value < 0 ? 0 : value);
