import "dart:async";
import "dart:typed_data";

import "package:audioplayers/audioplayers.dart";
import "package:flet/flet.dart";
import "package:flutter/foundation.dart";

import "native_playback_registry.dart";

class _NativeQueueItem {
  const _NativeQueueItem({required this.trackId, required this.source});

  final String trackId;
  final String source;

  factory _NativeQueueItem.fromMap(Map<String, dynamic> value) {
    return _NativeQueueItem(
      trackId: (value["track_id"] as String? ?? "").trim(),
      source: (value["source"] as String? ?? "").trim(),
    );
  }
}

/// Melody's long-lived, extension-owned source boundary.
///
/// Candidate and preloaded players prepare away from the active decoder. A
/// source switch swaps players only after preparation succeeds, so Flutter UI
/// patches, filesystem checks, and decoder setup never interrupt the current
/// track or block the UI isolate.
class ManagedAudioService extends FletService implements NativePlaybackEngine {
  ManagedAudioService({required super.control});

  AudioPlayer? _activePlayer;
  AudioPlayer? _retiringPlayer;
  Future<AudioPlayer>? _preloadFuture;
  Object? _preloadedSource;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
  double _volume = 1;
  bool _volumeUpdating = false;
  bool _foreground = true;
  int _positionBucket = -1;
  int _loadToken = 0;
  int _preloadToken = 0;
  int _activeGeneration = 0;
  Object? _activeSource;
  String? _activeTrackId;
  List<_NativeQueueItem> _queue = const [];
  int _queueIndex = -1;
  String _repeatMode = "off";
  bool _queueTransitioning = false;

  @override
  void init() {
    super.init();
    control.addInvokeMethodListener(_invokeMethod);
    activeNativePlaybackEngine = this;
    _volume = control.getDouble("volume", 1)!;
    final source = control.getString("src", "")!.trim();
    if (source.isNotEmpty) {
      unawaited(_loadSource(source, 0).catchError((Object error) {
        _event("error", {
          "message": "The native audio source could not be prepared.",
        });
      }));
    }
  }

  bool _sameSource(Object? first, Object? second) {
    if (identical(first, second)) return true;
    if (first is Uint8List && second is Uint8List) {
      return listEquals(first, second);
    }
    return first == second;
  }

  Source _source(Object source) {
    if (source is Uint8List) return BytesSource(source);
    if (source is List<int>) return BytesSource(Uint8List.fromList(source));
    if (source is! String) {
      throw ArgumentError("ManagedAudio source must be a path, URL, or bytes");
    }
    final uri = Uri.tryParse(source);
    final remote = uri?.scheme == "https" || uri?.scheme == "http";
    return remote ? UrlSource(source) : DeviceFileSource(source);
  }

  Future<AudioPlayer> _preparePlayer(Object source) async {
    final player = AudioPlayer();
    try {
      await player.setReleaseMode(ReleaseMode.stop);
      await player
          .setSource(_source(source))
          .timeout(const Duration(seconds: 20));
      await player.setVolume(_volume);
      return player;
    } catch (_) {
      unawaited(player.dispose().catchError((Object _) {}));
      rethrow;
    }
  }

  Future<void> _loadSource(
    Object source,
    int generation, {
    bool autoplay = false,
    Duration startPosition = Duration.zero,
  }) async {
    final token = ++_loadToken;
    final Future<AudioPlayer> candidateFuture;
    if (_sameSource(_preloadedSource, source) && _preloadFuture != null) {
      candidateFuture = _preloadFuture!;
      _preloadFuture = null;
      _preloadedSource = null;
      _preloadToken++;
    } else {
      await _cancelPreload();
      candidateFuture = _preparePlayer(source);
    }

    final candidate = await candidateFuture;
    if (_disposed || token != _loadToken) {
      unawaited(candidate.dispose().catchError((Object _) {}));
      return;
    }
    await _activatePlayer(
      candidate,
      source,
      generation,
      token,
      autoplay: autoplay,
      startPosition: startPosition,
    );
  }

  Future<void> _activatePlayer(
    AudioPlayer candidate,
    Object source,
    int generation,
    int token, {
    bool autoplay = false,
    Duration startPosition = Duration.zero,
  }) async {
    if (_disposed || token != _loadToken) {
      unawaited(candidate.dispose().catchError((Object _) {}));
      return;
    }
    // Everything through the loaded event is synchronous on the Dart isolate.
    // Detaching the retiring stream must not yield: a newer load could
    // otherwise invalidate this candidate after the old subscriptions were
    // cancelled but before the new player was installed.
    _cancelSubscriptionsSoon();
    final previous = _activePlayer;
    if (_retiringPlayer == null) {
      _retiringPlayer = previous;
    } else if (previous != null && previous != _retiringPlayer) {
      unawaited(previous.dispose().catchError((Object _) {}));
    }
    _activePlayer = candidate;
    _activeSource = source;
    _activeGeneration = generation;
    _positionBucket = -1;

    _subscriptions.add(candidate.onDurationChanged.listen((value) {
      _event("duration_change", {
        "duration": value.inMilliseconds,
        "generation": generation,
      });
    }));
    _subscriptions.add(candidate.onPlayerStateChanged.listen((value) {
      if (value.name == "completed") return;
      _event("state_change", {
        "state": value.name,
        "generation": generation,
      });
    }));
    _subscriptions.add(candidate.onPositionChanged.listen((value) {
      // The native decoder and media session remain authoritative in the
      // background. Wake Python only every five seconds while its UI is not
      // visible; foreground seek controls still receive one update per second.
      final intervalMs = _foreground ? 1000 : 5000;
      final bucket = value.inMilliseconds ~/ intervalMs;
      if (bucket != _positionBucket) {
        _positionBucket = bucket;
        _event("position_change", {
          "position": value.inMilliseconds,
          "generation": generation,
        });
      }
    }));
    _subscriptions.add(candidate.onPlayerComplete.listen((_) {
      _playerCompleted(candidate, generation);
    }));

    if (!_disposed && token == _loadToken && candidate == _activePlayer) {
      _event("loaded", {"generation": generation});
    }
    final duration = await candidate.getDuration();
    if (duration != null &&
        !_disposed &&
        token == _loadToken &&
        candidate == _activePlayer) {
      _event("duration_change", {
        "duration": duration.inMilliseconds,
        "generation": generation,
      });
    }
    if (autoplay &&
        !_disposed &&
        token == _loadToken &&
        candidate == _activePlayer) {
      if (startPosition > Duration.zero) {
        await candidate.seek(startPosition);
      }
      await _retirePrevious();
      if (!_disposed && token == _loadToken && candidate == _activePlayer) {
        await candidate.resume();
      }
    }
    if (!_disposed && token == _loadToken && candidate == _activePlayer) {
      unawaited(_preloadQueueSuccessor());
    }
  }

  List<_NativeQueueItem> _parseQueue(dynamic value) {
    final raw = value is List ? value : const <dynamic>[];
    return raw
        .whereType<Map>()
        .map(
            (item) => _NativeQueueItem.fromMap(Map<String, dynamic>.from(item)))
        .where((item) => item.trackId.isNotEmpty && item.source.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _setQueue(Map<String, dynamic> data) async {
    final items = _parseQueue(data["items"]);
    _repeatMode = data["repeat_mode"] as String? ?? "off";
    if (items.isEmpty) {
      _queue = const [];
      _queueIndex = -1;
      _activeTrackId = null;
      await _clearSource();
      return;
    }
    final requestedIndex = (data["current_index"] as num?)?.toInt() ?? 0;
    _queue = items;
    _queueIndex = requestedIndex.clamp(0, items.length - 1).toInt();
    final item = _queue[_queueIndex];
    _activeTrackId = item.trackId;
    await _loadSource(
      item.source,
      (data["generation"] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> _updateQueue(Map<String, dynamic> data) async {
    final items = _parseQueue(data["items"]);
    _repeatMode = data["repeat_mode"] as String? ?? "off";
    if (items.isEmpty) {
      _queue = const [];
      _queueIndex = -1;
      _activeTrackId = null;
      await _clearSource();
      return;
    }
    final currentTrackId = _activeTrackId;
    final requestedIndex = (data["current_index"] as num?)?.toInt() ?? 0;
    _queue = items;
    final activeIndex = currentTrackId == null
        ? -1
        : _queue.indexWhere((item) => item.trackId == currentTrackId);
    _queueIndex = activeIndex >= 0
        ? activeIndex
        : requestedIndex.clamp(0, _queue.length - 1).toInt();
    _activeTrackId = _queue[_queueIndex].trackId;
    await _preloadQueueSuccessor();
  }

  int? _nextQueueIndex({required bool automatic}) {
    if (_queue.isEmpty || _queueIndex < 0) return null;
    if (automatic && _repeatMode == "track") return _queueIndex;
    if (_queueIndex + 1 < _queue.length) return _queueIndex + 1;
    if (_repeatMode == "playlist") return 0;
    return null;
  }

  Future<void> _preloadQueueSuccessor() async {
    final index = _nextQueueIndex(automatic: true);
    if (index == null || index == _queueIndex) {
      await _cancelPreload();
      return;
    }
    final source = _queue[index].source;
    if (_sameSource(source, _activeSource) ||
        _sameSource(_preloadedSource, source)) {
      return;
    }
    try {
      await _preloadSource(source);
    } catch (_) {
      // Speculative decoding must never interrupt the active track. A normal
      // transition will retry this source and surface a generation-scoped
      // playback error if it is actually selected.
    }
  }

  void _playerCompleted(AudioPlayer player, int generation) {
    if (_disposed ||
        player != _activePlayer ||
        generation != _activeGeneration) {
      return;
    }
    if (_queue.isEmpty || _queueIndex < 0) {
      _event("state_change", {
        "state": "completed",
        "generation": generation,
      });
      return;
    }
    unawaited(_completeQueueItem(generation));
  }

  Future<void> _completeQueueItem(int generation) async {
    if (_queueTransitioning || generation != _activeGeneration) return;
    final next = _nextQueueIndex(automatic: true);
    if (next == null) {
      _event("state_change", {
        "state": "completed",
        "generation": generation,
      });
      return;
    }
    await _transitionTo(next);
  }

  Future<void> _transitionTo(int index) async {
    if (_queueTransitioning ||
        _disposed ||
        index < 0 ||
        index >= _queue.length) {
      return;
    }
    _queueTransitioning = true;
    final item = _queue[index];
    final generation = _activeGeneration + 1;
    _queueIndex = index;
    _activeTrackId = item.trackId;
    _event("track_change", {
      "track_id": item.trackId,
      "index": index,
      "generation": generation,
    });
    try {
      await _loadSource(item.source, generation, autoplay: true);
    } catch (_) {
      _event("error", {
        "message": "The next native audio source could not be prepared.",
      });
    } finally {
      _queueTransitioning = false;
    }
  }

  @override
  Future<bool> handleMediaAction(
    String action, {
    Duration? seekPosition,
  }) async {
    if (_disposed) return false;
    final player = _activePlayer;
    switch (action) {
      case "play":
        if (player == null) return false;
        final position = await player.getCurrentPosition();
        final duration = await player.getDuration();
        if (position != null && duration != null && position >= duration) {
          await player.seek(Duration.zero);
        }
        await _retirePrevious();
        if (!_disposed && player == _activePlayer) await player.resume();
        return true;
      case "pause":
        if (player == null) return false;
        await player.pause();
        await _retirePrevious();
        return true;
      case "skipToNext":
        if (_queue.isEmpty || _queueIndex < 0) return false;
        final next = _nextQueueIndex(automatic: false);
        if (next == null) {
          if (player != null) {
            await player.pause();
            await player.seek(Duration.zero);
          }
        } else {
          await _transitionTo(next);
        }
        return true;
      case "skipToPrevious":
        if (_queue.isEmpty || _queueIndex < 0 || player == null) return false;
        final position = await player.getCurrentPosition();
        if (position != null && position > const Duration(seconds: 5)) {
          await player.seek(Duration.zero);
          return true;
        }
        var previous = _queueIndex - 1;
        if (previous < 0) {
          previous = _repeatMode == "playlist" ? _queue.length - 1 : 0;
        }
        if (previous == _queueIndex) {
          await player.seek(Duration.zero);
          await player.resume();
        } else {
          await _transitionTo(previous);
        }
        return true;
      case "seekTo":
        if (player == null || seekPosition == null) return false;
        await player.seek(seekPosition);
        return true;
      case "rewind":
      case "fastForward":
        if (player == null) return false;
        final position = await player.getCurrentPosition() ?? Duration.zero;
        final delta = action == "rewind"
            ? const Duration(seconds: -10)
            : const Duration(seconds: 10);
        final targetMs = (position + delta).inMilliseconds;
        await player.seek(Duration(milliseconds: targetMs < 0 ? 0 : targetMs));
        return true;
      case "stop":
        if (player == null) return false;
        final generation = _activeGeneration;
        await player.pause();
        await _clearSource();
        _event("state_change", {
          "state": "stopped",
          "generation": generation,
        });
        return true;
      default:
        return false;
    }
  }

  Future<void> _preloadSource(Object source) async {
    await _cancelPreload();
    if (_disposed) return;
    final token = ++_preloadToken;
    final future = _preparePlayer(source);
    _preloadedSource = source;
    _preloadFuture = future;
    try {
      final player = await future;
      if (_disposed || token != _preloadToken) {
        // A consumed future is owned by _loadSource; cancellation owns all
        // other obsolete candidates.
        if (_preloadFuture == future) {
          _preloadFuture = null;
          _preloadedSource = null;
          unawaited(player.dispose().catchError((Object _) {}));
        }
      }
    } catch (_) {
      if (_preloadFuture == future) {
        _preloadFuture = null;
        _preloadedSource = null;
      }
      rethrow;
    }
  }

  Future<void> _cancelPreload() async {
    _preloadToken++;
    final future = _preloadFuture;
    _preloadFuture = null;
    _preloadedSource = null;
    if (future == null) return;
    unawaited(future.then((player) async {
      if (player != _activePlayer) await player.dispose();
    }).catchError((Object _) {}));
  }

  Future<void> _retirePrevious() async {
    final previous = _retiringPlayer;
    _retiringPlayer = null;
    if (previous == null) return;
    try {
      await previous.pause();
    } finally {
      // Decoder disposal is cleanup, not part of the critical handoff. Once
      // the previous player is paused, let the ready candidate begin while
      // the old native resources are released asynchronously.
      unawaited(previous.dispose().catchError((Object _) {}));
    }
  }

  Future<void> _clearSource() async {
    _loadToken++;
    await _cancelPreload();
    await _cancelSubscriptions();
    final active = _activePlayer;
    final retiring = _retiringPlayer;
    _activePlayer = null;
    _retiringPlayer = null;
    _activeSource = null;
    await Future.wait([
      if (active != null) active.dispose(),
      if (retiring != null && retiring != active) retiring.dispose(),
    ]);
  }

  Future<void> _cancelSubscriptions() async {
    final subscriptions =
        List<StreamSubscription<dynamic>>.from(_subscriptions);
    _subscriptions.clear();
    await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()));
  }

  void _cancelSubscriptionsSoon() {
    final subscriptions =
        List<StreamSubscription<dynamic>>.from(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  void _event(String name, [dynamic value]) {
    if (!_disposed) control.triggerEvent(name, value);
  }

  @override
  void update() {
    _volume = control.getDouble("volume", 1)!;
    if (!_volumeUpdating && !_disposed) {
      _volumeUpdating = true;
      unawaited(_updateVolume());
    }
  }

  Future<void> _updateVolume() async {
    try {
      while (!_disposed) {
        final value = _volume;
        final players = <AudioPlayer>{
          if (_activePlayer != null) _activePlayer!,
          if (_retiringPlayer != null) _retiringPlayer!,
        };
        await Future.wait(players.map((player) => player.setVolume(value)));
        if (_volume == value) break;
      }
    } catch (_) {
      _event("error", {"message": "The native audio player did not respond."});
    } finally {
      _volumeUpdating = false;
    }
  }

  Future<dynamic> _invokeMethod(String name, dynamic args) async {
    if (_disposed) return null;
    switch (name) {
      case "load_source":
        final data = Map<String, dynamic>.from(args as Map);
        _queue = const [];
        _queueIndex = -1;
        _activeTrackId = null;
        await _loadSource(
          data["source"] as Object,
          (data["generation"] as num?)?.toInt() ?? 0,
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
        return null;
      case "clear_source":
        _queue = const [];
        _queueIndex = -1;
        _activeTrackId = null;
        await _clearSource();
        return null;
      case "set_foreground":
        final data = Map<String, dynamic>.from(args as Map);
        _foreground = data["foreground"] as bool? ?? true;
        _positionBucket = -1;
        return null;
      case "get_playback_state":
        final player = _activePlayer;
        if (player == null) {
          return <String, int?>{
            "position_ms": null,
            "duration_ms": null,
          };
        }
        final values = await Future.wait<Duration?>([
          player.getCurrentPosition(),
          player.getDuration(),
        ]);
        return <String, int?>{
          "position_ms": values[0]?.inMilliseconds,
          "duration_ms": values[1]?.inMilliseconds,
        };
      case "play":
        final player = _activePlayer;
        if (player == null) return null;
        final position = parseDuration(args["position"]);
        if (position != null && position > Duration.zero) {
          await player.seek(position);
        }
        await _retirePrevious();
        if (!_disposed && player == _activePlayer) await player.resume();
        return null;
      case "resume":
        final player = _activePlayer;
        if (player == null) return null;
        await _retirePrevious();
        if (!_disposed && player == _activePlayer) await player.resume();
        return null;
      case "pause":
        await Future.wait([
          if (_activePlayer != null) _activePlayer!.pause(),
          if (_retiringPlayer != null) _retiringPlayer!.pause(),
        ]);
        await _retirePrevious();
        return null;
      case "seek":
        final position = parseDuration(args["position"]);
        final player = _activePlayer;
        if (position != null && player != null) await player.seek(position);
        return null;
      case "get_duration":
        return await _activePlayer?.getDuration();
      case "get_current_position":
        return await _activePlayer?.getCurrentPosition();
      default:
        throw ArgumentError("Unknown ManagedAudio method: $name");
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(activeNativePlaybackEngine, this)) {
      activeNativePlaybackEngine = null;
    }
    _loadToken++;
    _preloadToken++;
    control.removeInvokeMethodListener(_invokeMethod);
    unawaited(_clearSource().catchError((Object _) {}));
    super.dispose();
  }
}
