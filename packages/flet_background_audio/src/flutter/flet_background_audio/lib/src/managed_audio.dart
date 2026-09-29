import "dart:async";

import "package:audio_session/audio_session.dart";
import "package:flet/flet.dart";
import "package:flutter/foundation.dart";
import "package:just_audio/just_audio.dart";

import "background_audio_session.dart";
import "native_playback_registry.dart";
import "native_queue_policy.dart";

class _NativeQueueItem {
  const _NativeQueueItem({
    required this.trackId,
    required this.source,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUri,
  });

  final String trackId;
  final String source;
  final String title;
  final String artist;
  final String album;
  final String artworkUri;

  factory _NativeQueueItem.fromMap(Map<String, dynamic> value) {
    return _NativeQueueItem(
      trackId: (value["track_id"] as String? ?? "").trim(),
      source: (value["source"] as String? ?? "").trim(),
      title: (value["title"] as String? ?? "").trim(),
      artist: (value["artist"] as String? ?? "").trim(),
      album: (value["album"] as String? ?? "").trim(),
      artworkUri: (value["artwork_uri"] as String? ?? "").trim(),
    );
  }
}

/// Supplies preview bytes to just_audio's range-aware source interface.
// ignore: experimental_member_use
class _MemoryAudioSource extends StreamAudioSource {
  _MemoryAudioSource(this.bytes);

  final Uint8List bytes;

  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final first = (start ?? 0).clamp(0, bytes.length).toInt();
    final last = (end ?? bytes.length).clamp(first, bytes.length).toInt();
    // ignore: experimental_member_use
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: last - first,
      offset: first,
      stream: Stream.value(bytes.sublist(first, last)),
      contentType: "audio/mpeg",
    );
  }
}

/// Process-scoped player; page-scoped Flet services are only command bridges.
/// just_audio owns decoding, buffering, playlists, automatic next, and repeat.
class NativeAudioRuntime implements NativePlaybackEngine {
  NativeAudioRuntime._();

  static final NativeAudioRuntime instance = NativeAudioRuntime._();

  Control? _eventControl;
  AudioPlayer? _player;
  AudioPlayer? _preparingPlayer;
  Future<void>? _sessionFuture;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<_NativeQueueItem> _queue = const [];
  List<int> _playlistQueueIndexes = const [];
  Object? _activeSource;
  String? _activeTrackId;
  String _repeatMode = "off";
  int _queueIndex = -1;
  int _playlistIndex = -1;
  int _generation = 0;
  int _loadToken = 0;
  int? _preparingToken;
  int? _pendingLoadedGeneration;
  int? _reportedErrorGeneration;
  int _positionBucket = -1;
  Duration? _pendingSeekPosition;
  double _volume = 1;
  bool _playbackWanted = false;
  bool _removingGhost = false;

  void attach(Control control) {
    _eventControl = control;
    activeNativePlaybackEngine = this;
    setVolume(control.getDouble("volume", 1)!);
  }

  void detach(Control control) {
    if (identical(_eventControl, control)) _eventControl = null;
  }

  Future<void> _ensureSession() async {
    if (kIsWeb) return;
    final future = _sessionFuture ??= () async {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    }();
    try {
      await future;
    } catch (_) {
      _sessionFuture = null;
      rethrow;
    }
  }

  void _retainPlayback() {
    if (kIsWeb) return;
    unawaited(
      NativeMediaSessionRuntime.instance.ensurePlaybackActive().catchError((
        Object error,
      ) {
        debugPrint("ManagedAudio: media session unavailable: $error");
      }),
    );
  }

  AudioSource _source(Object source) {
    if (source is Uint8List) return _MemoryAudioSource(source);
    if (source is List<int>) {
      return _MemoryAudioSource(Uint8List.fromList(source));
    }
    if (source is! String) {
      throw ArgumentError("ManagedAudio source must be a path, URL, or bytes");
    }
    final uri = Uri.tryParse(source);
    return uri?.scheme == "http" || uri?.scheme == "https"
        ? AudioSource.uri(uri!)
        : AudioSource.file(source);
  }

  List<_NativeQueueItem> _parseQueue(dynamic value) {
    final raw = value is List ? value : const <dynamic>[];
    return raw
        .whereType<Map>()
        .map(
          (item) => _NativeQueueItem.fromMap(Map<String, dynamic>.from(item)),
        )
        .where((item) => item.trackId.isNotEmpty && item.source.isNotEmpty)
        .toList(growable: false);
  }

  LoopMode _loopMode(String mode) => switch (mode) {
    "track" => LoopMode.one,
    "playlist" => LoopMode.all,
    _ => LoopMode.off,
  };

  Future<void> _select({
    required List<AudioSource> sources,
    required List<_NativeQueueItem> queue,
    required List<int> queueIndexes,
    required int initialIndex,
    required Object? activeSource,
    required String? activeTrackId,
    required int generation,
    required String repeatMode,
    required bool autoplay,
    required Duration position,
    required bool preserveMetadata,
  }) async {
    final token = ++_loadToken;
    final previousPlaybackWanted = _playbackWanted;
    _preparingToken = token;
    _pendingSeekPosition = null;
    _playbackWanted = autoplay;
    if (autoplay) _retainPlayback();
    if (sources.isEmpty) {
      await _clearSource();
      return;
    }
    final candidate = AudioPlayer();
    _preparingPlayer = candidate;
    try {
      await _ensureSession();
      await candidate.setVolume(_volume);
      await candidate.setLoopMode(
        queueIndexes.contains(-1) ? LoopMode.off : _loopMode(repeatMode),
      );
      final duration = await candidate
          .setAudioSources(
            sources,
            initialIndex: initialIndex,
            initialPosition: position,
          )
          .timeout(const Duration(seconds: 20));
      if (token != _loadToken) return;
      final previous = _player;
      if (preserveMetadata && previous != null) {
        // Queue edits prepare while the old player is still moving. Transfer
        // its latest playhead rather than the position captured at request time.
        await candidate.seek(previous.position);
        if (token != _loadToken) return;
      }
      _preparingPlayer = null;
      _cancelSubscriptionsSoon();
      _player = candidate;
      _queue = queue;
      _repeatMode = repeatMode;
      _playlistQueueIndexes = queueIndexes;
      _playlistIndex = initialIndex;
      _queueIndex = queueIndexes[initialIndex];
      _activeSource = activeSource;
      _activeTrackId = activeTrackId;
      _generation = generation;
      _preparingToken = null;
      _reportedErrorGeneration = null;
      _pendingLoadedGeneration = null;
      _positionBucket = -1;
      _listen(candidate);

      if (!preserveMetadata && _queueIndex >= 0) {
        _announceTrack(queue[_queueIndex]);
      }
      if (previous != null) {
        try {
          await previous.pause();
        } catch (error) {
          debugPrint("ManagedAudio: retiring player pause failed: $error");
        }
        unawaited(previous.dispose().catchError((Object _) {}));
      }
      _event("loaded", {"generation": generation});
      if (duration != null) {
        _event("duration_change", {
          "duration": duration.inMilliseconds,
          "generation": generation,
        });
      }
      final pendingSeek = _pendingSeekPosition;
      _pendingSeekPosition = null;
      if (pendingSeek != null) await _seekCurrent(candidate, pendingSeek);
      if (token == _loadToken) {
        await candidate.setVolume(_volume);
        if (_playbackWanted) _startPlaying(candidate);
      }
    } catch (_) {
      if (token == _loadToken) {
        _preparingToken = null;
        if (!identical(_player, candidate)) {
          _playbackWanted = previousPlaybackWanted;
        }
      }
      if (token != _loadToken) return;
      rethrow;
    } finally {
      if (identical(_preparingPlayer, candidate)) _preparingPlayer = null;
      if (!identical(_player, candidate)) {
        unawaited(candidate.dispose().catchError((Object _) {}));
      }
    }
  }

  void _listen(AudioPlayer player) {
    _subscriptions.add(
      player.currentIndexStream.listen(
        (index) => _onIndex(player, index),
        onError: (Object error) => _playerError(player, error),
      ),
    );
    _subscriptions.add(
      player.durationStream.listen((duration) {
        if (player != _player || duration == null) return;
        _onIndex(player, player.currentIndex);
        _event("duration_change", {
          "duration": duration.inMilliseconds,
          "generation": _generation,
        });
      }, onError: (Object error) => _playerError(player, error)),
    );
    _subscriptions.add(
      player.positionStream.listen((position) {
        if (player != _player) return;
        _onIndex(player, player.currentIndex);
        final bucket = position.inMilliseconds ~/ 1000;
        if (bucket == _positionBucket) return;
        _positionBucket = bucket;
        _event("position_change", {
          "position": position.inMilliseconds,
          "generation": _generation,
        });
      }, onError: (Object error) => _playerError(player, error)),
    );
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        if (player != _player) return;
        _onIndex(player, player.currentIndex);
        if (state.processingState == ProcessingState.ready &&
            _pendingLoadedGeneration == _generation) {
          _pendingLoadedGeneration = null;
          _event("loaded", {"generation": _generation});
        }
        if (state.processingState == ProcessingState.loading ||
            state.processingState == ProcessingState.buffering) {
          // The native media session needs buffering, while Python's play intent
          // stays unchanged until the decoder reports ready or completed.
          NativeMediaSessionRuntime.instance.onNativePlaybackEvent(
            "state_change",
            {"state": "loading", "generation": _generation},
          );
          return;
        }
        final name = state.processingState == ProcessingState.completed
            ? "completed"
            : state.playing
            ? "playing"
            : "paused";
        if (name != "playing") _publishPosition(player);
        _event("state_change", {"state": name, "generation": _generation});
      }, onError: (Object error) => _playerError(player, error)),
    );
    _subscriptions.add(
      player.playbackEventStream.listen(
        (_) {},
        onError: (Object error) => _playerError(player, error),
      ),
    );
  }

  void _onIndex(AudioPlayer player, int? index) {
    if (player != _player ||
        index == null ||
        _removingGhost ||
        index == _playlistIndex ||
        index >= _playlistQueueIndexes.length) {
      return;
    }
    final wasGhost =
        _playlistIndex >= 0 &&
        _playlistIndex < _playlistQueueIndexes.length &&
        _playlistQueueIndexes[_playlistIndex] < 0;
    _playlistIndex = index;
    final queueIndex = _playlistQueueIndexes[index];
    if (queueIndex < 0 || queueIndex >= _queue.length) return;
    _queueIndex = queueIndex;
    final item = _queue[queueIndex];
    _activeSource = item.source;
    _activeTrackId = item.trackId;
    // Explicit Python requests use even generations; native transitions use
    // odd ones so a concurrent request can never share a generation.
    _generation = _generation.isEven ? _generation + 1 : _generation + 2;
    _positionBucket = -1;
    _reportedErrorGeneration = null;
    _pendingLoadedGeneration = _generation;
    _announceTrack(item);
    _event("track_change", {
      "track_id": item.trackId,
      "index": queueIndex,
      "generation": _generation,
    });
    if (player.processingState == ProcessingState.ready) {
      _pendingLoadedGeneration = null;
      _event("loaded", {"generation": _generation});
    }
    if (wasGhost) unawaited(_removeGhost(player));
  }

  Future<void> _removeGhost(AudioPlayer player) async {
    if (player != _player || _playlistQueueIndexes.isEmpty) return;
    _removingGhost = true;
    try {
      await player.removeAudioSourceAt(0);
      if (player != _player) return;
      _playlistQueueIndexes = _playlistQueueIndexes.sublist(1);
      _playlistIndex = player.currentIndex ?? 0;
      await player.setLoopMode(_loopMode(_repeatMode));
    } catch (error) {
      _playerError(player, error);
    } finally {
      _removingGhost = false;
    }
  }

  void _announceTrack(_NativeQueueItem item) {
    NativeMediaSessionRuntime.instance.onNativeTrack(
      title: item.title,
      artist: item.artist,
      album: item.album,
      artworkUri: item.artworkUri,
    );
  }

  void _playerError(AudioPlayer player, Object error) {
    if (player != _player || _reportedErrorGeneration == _generation) return;
    _reportedErrorGeneration = _generation;
    _playbackWanted = false;
    _event("error", {
      "message": "Native audio playback failed: $error",
      "generation": _generation,
    });
  }

  void _startPlaying(AudioPlayer player) {
    unawaited(
      player.play().catchError((Object error) {
        _playerError(player, error);
      }),
    );
  }

  int? _manualRelativeIndex(AudioPlayer player, int offset) {
    final current = player.currentIndex ?? _playlistIndex;
    if (current < 0 || current >= _playlistQueueIndexes.length) return null;
    final next = current + offset;
    if (next >= 0 && next < _playlistQueueIndexes.length) return next;
    if (_repeatMode == "playlist" && _playlistQueueIndexes.isNotEmpty) {
      return next < 0 ? _playlistQueueIndexes.length - 1 : 0;
    }
    return null;
  }

  Future<void> _setQueue(Map<String, dynamic> data) async {
    final items = _parseQueue(data["items"]);
    if (items.isEmpty) {
      await _clearSource();
      return;
    }
    final index = ((data["current_index"] as num?)?.toInt() ?? 0)
        .clamp(0, items.length - 1)
        .toInt();
    await _select(
      sources: items.map((item) => _source(item.source)).toList(),
      queue: items,
      queueIndexes: List.generate(items.length, (index) => index),
      initialIndex: index,
      activeSource: items[index].source,
      activeTrackId: items[index].trackId,
      generation: (data["generation"] as num?)?.toInt() ?? 0,
      repeatMode: data["repeat_mode"] as String? ?? "off",
      autoplay: data["autoplay"] as bool? ?? false,
      position: Duration(
        milliseconds: (data["position_ms"] as num?)?.toInt() ?? 0,
      ),
      preserveMetadata: false,
    );
  }

  Future<void> _updateQueue(Map<String, dynamic> data) async {
    final items = _parseQueue(data["items"]);
    final repeatMode = data["repeat_mode"] as String? ?? "off";
    final old = _queue;
    final unchanged =
        old.length == items.length &&
        List.generate(old.length, (index) => index).every(
          (index) =>
              old[index].trackId == items[index].trackId &&
              old[index].source == items[index].source,
        );
    if (unchanged && _player != null && !_playlistQueueIndexes.contains(-1)) {
      _queue = items;
      _repeatMode = repeatMode;
      await _player!.setLoopMode(_loopMode(repeatMode));
      return;
    }
    final player = _player;
    if (player == null || _activeSource == null) {
      _queue = items;
      _repeatMode = repeatMode;
      return;
    }
    final position = reconcileNativeQueue(
      items.map((item) => item.trackId).toList(growable: false),
      _activeTrackId,
      (data["current_index"] as num?)?.toInt() ?? 0,
    );
    final sources = <AudioSource>[];
    final indexes = <int>[];
    var initialIndex = position.activeIndex;
    if (initialIndex < 0) {
      sources.add(_source(_activeSource!));
      indexes.add(-1);
      initialIndex = 0;
      if (items.isNotEmpty) {
        for (var offset = 0; offset < items.length; offset++) {
          final index =
              (position.detachedSuccessorIndex + offset) % items.length;
          sources.add(_source(items[index].source));
          indexes.add(index);
        }
      }
    } else {
      for (var index = 0; index < items.length; index++) {
        sources.add(_source(items[index].source));
        indexes.add(index);
      }
    }
    await _select(
      sources: sources,
      queue: items,
      queueIndexes: indexes,
      initialIndex: initialIndex,
      activeSource: _activeSource,
      activeTrackId: _activeTrackId,
      generation: _generation,
      repeatMode: repeatMode,
      autoplay: _playbackWanted,
      position: player.position,
      preserveMetadata: true,
    );
  }

  Future<void> _clearSource() async {
    _loadToken++;
    _preparingToken = null;
    _pendingSeekPosition = null;
    _playbackWanted = false;
    final player = _player;
    final preparing = _preparingPlayer;
    _player = null;
    _preparingPlayer = null;
    _queue = const [];
    _playlistQueueIndexes = const [];
    _queueIndex = -1;
    _playlistIndex = -1;
    _activeSource = null;
    _activeTrackId = null;
    _pendingLoadedGeneration = null;
    _cancelSubscriptionsSoon();
    for (final decoder in <AudioPlayer>{
      if (player != null) player,
      if (preparing != null) preparing,
    }) {
      try {
        await decoder.dispose();
      } catch (error) {
        debugPrint("ManagedAudio: player cleanup failed: $error");
      }
    }
  }

  void _cancelSubscriptionsSoon() {
    final old = List<StreamSubscription<dynamic>>.from(_subscriptions);
    _subscriptions.clear();
    for (final subscription in old) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  void _event(String name, [dynamic value]) {
    NativeMediaSessionRuntime.instance.onNativePlaybackEvent(name, value);
    _eventControl?.triggerEvent(name, value);
  }

  void _publishPosition(AudioPlayer player) {
    if (player != _player) return;
    final position = player.position.inMilliseconds;
    _positionBucket = position ~/ 1000;
    _event("position_change", {
      "position": position,
      "generation": _generation,
    });
  }

  Future<void> _seekCurrent(AudioPlayer player, Duration position) async {
    await player.seek(position);
    // A paused seek can remain in the same one-second bucket. Publish its
    // exact position instead of waiting for the next periodic decoder tick.
    _publishPosition(player);
  }

  void setVolume(double value) {
    _volume = value.clamp(0, 1).toDouble();
    for (final player in <AudioPlayer>{
      if (_player != null) _player!,
      if (_preparingPlayer != null) _preparingPlayer!,
    }) {
      unawaited(
        player.setVolume(_volume).catchError((Object error) {
          _playerError(player, error);
        }),
      );
    }
  }

  @override
  Future<bool> handleMediaAction(
    String action, {
    Duration? seekPosition,
  }) async {
    final player = _player;
    switch (action) {
      case "play":
        if (player == null) return false;
        _playbackWanted = true;
        _retainPlayback();
        if (player.processingState == ProcessingState.completed) {
          await _seekCurrent(player, Duration.zero);
        }
        _startPlaying(player);
        return true;
      case "pause":
        _playbackWanted = false;
        if (player == null) return false;
        await player.pause();
        return true;
      case "skipToNext":
        if (player == null || _queue.isEmpty) return false;
        final next = _manualRelativeIndex(player, 1);
        if (next != null) {
          await player.seek(Duration.zero, index: next);
        } else {
          _playbackWanted = false;
          await player.pause();
          await _seekCurrent(player, Duration.zero);
        }
        return true;
      case "skipToPrevious":
        if (player == null || _queue.isEmpty) return false;
        if (player.position > const Duration(seconds: 5)) {
          await _seekCurrent(player, Duration.zero);
        } else if (_manualRelativeIndex(player, -1) case final previous?) {
          await player.seek(Duration.zero, index: previous);
        } else {
          await _seekCurrent(player, Duration.zero);
        }
        return true;
      case "seekTo":
        if (player == null || seekPosition == null) return false;
        await _seekCurrent(player, seekPosition);
        return true;
      case "rewind":
      case "fastForward":
        if (player == null) return false;
        final delta = action == "rewind" ? -10000 : 10000;
        final position = player.position.inMilliseconds + delta;
        await _seekCurrent(
          player,
          Duration(milliseconds: position < 0 ? 0 : position),
        );
        return true;
      case "stop":
        final generation = _generation;
        try {
          await _clearSource();
        } finally {
          _event("state_change", {
            "state": "stopped",
            "generation": generation,
          });
          await NativeMediaSessionRuntime.instance.deactivateForStop();
        }
        return true;
      default:
        return false;
    }
  }

  Future<dynamic> invokeMethod(String name, dynamic args) async {
    switch (name) {
      case "load_source":
        final data = Map<String, dynamic>.from(args as Map);
        await _select(
          sources: [_source(data["source"] as Object)],
          queue: const [],
          queueIndexes: const [-1],
          initialIndex: 0,
          activeSource: data["source"],
          activeTrackId: null,
          generation: (data["generation"] as num?)?.toInt() ?? 0,
          repeatMode: "off",
          autoplay: data["autoplay"] as bool? ?? false,
          position: Duration(
            milliseconds: (data["position_ms"] as num?)?.toInt() ?? 0,
          ),
          preserveMetadata: true,
        );
        return null;
      case "set_queue":
        await _setQueue(Map<String, dynamic>.from(args as Map));
        return null;
      case "update_queue":
        await _updateQueue(Map<String, dynamic>.from(args as Map));
        return null;
      case "cancel_load":
        _loadToken++;
        _preparingToken = null;
        _pendingSeekPosition = null;
        final candidate = _preparingPlayer;
        _preparingPlayer = null;
        if (candidate != null) {
          unawaited(candidate.dispose().catchError((Object _) {}));
        }
        return null;
      case "clear_source":
        await _clearSource();
        return null;
      case "get_playback_state":
        final player = _player;
        return <String, Object?>{
          "track_id": _activeTrackId,
          "source": _activeSource is String ? _activeSource : null,
          ...NativeMediaSessionRuntime.instance.currentMetadata,
          "queue_index": _queueIndex,
          "generation": _generation,
          "position_ms": player?.position.inMilliseconds,
          "duration_ms": player?.duration?.inMilliseconds,
          "playing": player?.playing ?? false,
        };
      case "play":
        _playbackWanted = true;
        _retainPlayback();
        final position = parseDuration(args["position"]);
        if (_preparingToken != null) {
          if (position != null) _pendingSeekPosition = position;
          return null;
        }
        final player = _player;
        if (player == null) return null;
        if (position != null && position > Duration.zero)
          await _seekCurrent(player, position);
        _startPlaying(player);
        return null;
      case "resume":
        _playbackWanted = true;
        _retainPlayback();
        if (_preparingToken == null && _player != null) _startPlaying(_player!);
        return null;
      case "pause":
        _playbackWanted = false;
        if (_player != null) await _player!.pause();
        return null;
      case "seek":
        final position = parseDuration(args["position"]);
        if (_preparingToken != null) {
          _pendingSeekPosition = position;
        } else if (position != null && _player != null) {
          await _seekCurrent(_player!, position);
        }
        return null;
      case "stop":
        await handleMediaAction("stop");
        return null;
      case "skip_next":
        await handleMediaAction("skipToNext");
        return null;
      case "skip_previous":
        await handleMediaAction("skipToPrevious");
        return null;
      default:
        throw ArgumentError("Unknown ManagedAudio method: $name");
    }
  }
}

/// Only this command bridge follows the Flet page lifecycle.
class ManagedAudioService extends FletService {
  ManagedAudioService({required super.control});

  final NativeAudioRuntime _runtime = NativeAudioRuntime.instance;

  @override
  void init() {
    super.init();
    control.addInvokeMethodListener(_runtime.invokeMethod);
    _runtime.attach(control);
  }

  @override
  void update() => _runtime.setVolume(control.getDouble("volume", 1)!);

  @override
  void dispose() {
    control.removeInvokeMethodListener(_runtime.invokeMethod);
    _runtime.detach(control);
    super.dispose();
  }
}
