import "dart:async";
import "dart:math" show ln10, log, max, min, pow;

import "package:audio_session/audio_session.dart";
import "package:flutter/foundation.dart";
import "package:just_audio/just_audio.dart";

import "native_queue_policy.dart";
import "system_media_session.dart";

/// How the engine repeats when a track or the queue ends.
enum AudioRepeatMode { off, track, queue }

/// One row of the engine's queue, with the metadata system controls show.
@immutable
class AudioQueueItem {
  const AudioQueueItem({
    required this.trackId,
    required this.source,
    this.title = "",
    this.artist = "",
    this.album = "",
    this.artworkUri = "",
    this.gain = 1,
  });

  final String trackId;

  /// A local path or an http(s) URL.
  final String source;
  final String title;
  final String artist;
  final String album;
  final String artworkUri;

  /// Loudness normalization: a linear amplitude factor for this row, from 0
  /// to [AudioEngine.maxGain], applied on top of the volume while it plays.
  final double gain;

  bool get isPlayable => trackId.isNotEmpty && source.isNotEmpty;
}

/// Decoder phases reported to listeners. [loading] reaches only the system
/// media session; the app keeps its play intent until ready or completed.
enum AudioPlaybackState { loading, playing, paused, completed, stopped }

/// A decoder event. Every event carries the generation it belongs to, so
/// listeners can ignore events from a superseded selection.
sealed class AudioEngineEvent {
  const AudioEngineEvent(this.generation);

  final int generation;
}

/// The selected source is ready to play.
final class AudioLoaded extends AudioEngineEvent {
  const AudioLoaded(super.generation);
}

final class AudioDurationChanged extends AudioEngineEvent {
  const AudioDurationChanged(this.duration, super.generation);

  final Duration duration;
}

/// Published at most once per second of playback, and after every seek.
final class AudioPositionChanged extends AudioEngineEvent {
  const AudioPositionChanged(this.position, super.generation);

  final Duration position;
}

final class AudioStateChanged extends AudioEngineEvent {
  const AudioStateChanged(this.state, super.generation);

  final AudioPlaybackState state;
}

/// The engine advanced its queue by itself (completion, repeat, or a system
/// control). Native transitions use odd generations.
final class AudioTrackChanged extends AudioEngineEvent {
  const AudioTrackChanged(this.trackId, this.index, super.generation);

  final String trackId;
  final int index;
}

final class AudioFailed extends AudioEngineEvent {
  const AudioFailed(this.message, super.generation);

  final String message;
}

typedef AudioEngineListener = void Function(AudioEngineEvent event);

/// What the engine is playing right now, for adopting a decoder that outlived
/// the widget tree or refreshing state after the app resumes.
@immutable
class AudioEngineSnapshot {
  const AudioEngineSnapshot({
    required this.generation,
    this.trackId,
    this.source,
    this.title = "",
    this.artist = "",
    this.album = "",
    this.artworkUri = "",
    this.queueIndex = -1,
    this.position,
    this.duration,
    this.playing = false,
  });

  final int generation;
  final String? trackId;

  /// The active path or URL; null when nothing is loaded.
  final String? source;
  final String title;
  final String artist;
  final String album;
  final String artworkUri;
  final int queueIndex;
  final Duration? position;
  final Duration? duration;
  final bool playing;

  bool get hasSource => source != null && source!.isNotEmpty;
}

/// System media commands the engine or the app can carry out.
enum MediaCommand {
  play,
  pause,
  stop,
  skipToNext,
  skipToPrevious,
  seekTo,
  rewind,
  fastForward,
  shuffleUpcoming,
  cycleRepeat,
  toggleFavorite;

  /// Maps a platform action name (`skipToNext`, `shuffleUpcoming`, ...).
  static MediaCommand? parse(String name) {
    final lowered = name.toLowerCase();
    // Windows and Apple report their built-in shuffle and repeat controls
    // under these names.
    if (lowered == "shuffle") return shuffleUpcoming;
    if (lowered == "repeat") return cycleRepeat;
    for (final command in values) {
      if (command.name.toLowerCase() == lowered) return command;
    }
    return null;
  }
}

/// One row of the decoder's playlist. [queueIndex] is -1 for a row outside the
/// queue: a stream, or a playing track whose row was removed.
@immutable
class _NativeRow {
  const _NativeRow(this.queueIndex, this.trackId, this.source);

  final int queueIndex;
  final String trackId;
  final String source;

  bool sameMedia(_NativeRow other) =>
      trackId == other.trackId && source == other.source;
}

/// Process-scoped player shared by the app and the system media session.
/// just_audio owns decoding, buffering, and gapless transitions.
///
/// The queue can be any length, but the decoder only ever holds the playing
/// row and the next [upcomingRows], so the work of a selection or an edit
/// does not grow with the queue. Its playlist is linear: repeating the queue
/// appends the first rows again rather than using the decoder's loop mode, and
/// the window slides forward as tracks finish. Edits change only rows after
/// the playing one, so they never disturb it or shift its index. (Rows already
/// played stay behind it until the next selection. Removing them would shift
/// the index under the decoder's asynchronous events, and they are few.)
///
/// Explicit requests carry an even generation chosen by the caller; queue
/// transitions the engine makes by itself take the next odd one.
class AudioEngine {
  AudioEngine._();

  static final AudioEngine instance = AudioEngine._();

  /// How many rows the decoder holds after the playing one. A gapless
  /// transition needs only one; the rest keep music going for about half an
  /// hour should this isolate ever fall behind the decoder.
  static const upcomingRows = 8;

  SystemMediaSession get _session => SystemMediaSession.instance;

  AudioEngineListener? _listener;
  AudioPlayer? _player;
  AudioPlayer? _preparingPlayer;
  Future<void>? _sessionFuture;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<AudioQueueItem> _queue = const [];
  List<_NativeRow> _rows = const [];

  /// The queue row after a playing track whose own row was removed.
  int _detachedSuccessor = -1;

  /// Serializes changes to the decoder's playlist; [_rowsStale] says a change
  /// to the queue or the playing row has not reached it yet.
  Future<void> _rowSync = Future.value();
  bool _rowsStale = false;
  String? _activeSource;
  String? _activeTrackId;
  AudioRepeatMode _repeatMode = AudioRepeatMode.off;
  int _queueIndex = -1;
  int _playlistIndex = -1;
  int _generation = 0;
  int _loadToken = 0;
  int? _pendingLoadedGeneration;
  int? _reportedErrorGeneration;
  int _positionBucket = -1;
  Duration? _reportedDuration;
  Duration? _pendingSeekPosition;
  double _volume = 1;

  /// The active row's normalization gain, and the preparing selection's.
  double _gain = 1;
  double _preparingGain = 1;

  /// The volume last given to the active decoder, and the ramp moving it.
  double _appliedVolume = 1;
  Timer? _ramp;

  /// Fires as the active track nears a gapless transition to a row with
  /// another gain; [_boundaryGain] is that gain once the volume heads for it.
  Timer? _boundaryTimer;
  double? _boundaryGain;
  bool _playbackWanted = false;

  /// The decoder [_continueQueue] is moving on, so it runs once for it.
  AudioPlayer? _continuing;

  void attach(AudioEngineListener listener, {double volume = 1}) {
    _listener = listener;
    setVolume(volume);
  }

  void detach(AudioEngineListener listener) {
    if (identical(_listener, listener)) _listener = null;
  }

  // -- requests ------------------------------------------------------------

  /// Replaces the engine's source with a single path or URL outside any
  /// queue. [gain] is its normalization gain, as on [AudioQueueItem].
  Future<void> loadSource(
    String source, {
    required int generation,
    bool autoplay = false,
    Duration position = Duration.zero,
    double gain = 1,
  }) async {
    await _select(
      rows: [_NativeRow(-1, "", source)],
      queue: const [],
      generation: generation,
      repeatMode: AudioRepeatMode.off,
      autoplay: autoplay,
      position: position,
      gain: gain,
    );
  }

  /// Installs a complete queue and selects [currentIndex], or the first
  /// playable row after it. Reads only the rows the decoder will hold.
  Future<void> setQueue(
    List<AudioQueueItem> items, {
    required int currentIndex,
    required int generation,
    AudioRepeatMode repeatMode = AudioRepeatMode.off,
    bool autoplay = false,
    Duration position = Duration.zero,
  }) async {
    final length = items.length;
    final rows = length == 0
        ? const <int>[]
        : upcomingQueueRows(
            length: length,
            start: currentIndex.clamp(0, length - 1).toInt(),
            wrap: repeatMode == AudioRepeatMode.queue,
            limit: upcomingRows + 1,
            playable: (row) => items[row].isPlayable,
          );
    if (rows.isEmpty) {
      await clearSource();
      return;
    }
    await _select(
      rows: [for (final row in rows) _rowFor(items, row)],
      queue: items,
      generation: generation,
      repeatMode: repeatMode,
      autoplay: autoplay,
      position: position,
      gain: items[rows.first].gain,
    );
  }

  /// Edits the queue around the active decoder without interrupting it. A
  /// new gain for the active row fades in rather than jumping.
  Future<void> updateQueue(
    List<AudioQueueItem> items, {
    required int currentIndex,
    AudioRepeatMode repeatMode = AudioRepeatMode.off,
  }) {
    _queue = items;
    _repeatMode = repeatMode;
    if (_player == null || _activeSource == null) return Future.value();
    final position = reconcileNativeQueue(
      items.length,
      (row) => items[row].trackId,
      _activeTrackId,
      currentIndex,
    );
    _queueIndex = position.activeIndex;
    _detachedSuccessor = position.detachedSuccessorIndex;
    if (_queueIndex >= 0) {
      final gain = items[_queueIndex].gain;
      if (gain != _gain) _applyGain(gain, fade: true);
    }
    return _syncRows();
  }

  _NativeRow _rowFor(List<AudioQueueItem> items, int row) =>
      _NativeRow(row, items[row].trackId, items[row].source);

  /// What should follow the playing row, from the queue as it is now.
  List<_NativeRow> _upcoming() {
    final queue = _queue;
    final start = _queueIndex >= 0 ? _queueIndex + 1 : _detachedSuccessor;
    return [
      for (final row in upcomingQueueRows(
        length: queue.length,
        start: start,
        wrap: _repeatMode == AudioRepeatMode.queue,
        limit: upcomingRows,
        playable: (row) => queue[row].isPlayable,
      ))
        _rowFor(queue, row),
    ];
  }

  /// Brings the decoder's playlist to the queue. Requests coalesce and run one
  /// at a time; one that arrives meanwhile, such as a transition during an
  /// edit, makes the running pass stop early for the next to start from the
  /// new state.
  Future<void> _syncRows() {
    _rowsStale = true;
    final run = _rowSync.then((_) => _applyRows());
    _rowSync = run.catchError((Object _) {});
    return run;
  }

  /// Keeps the rows that already follow the playing one correctly, removes
  /// the rest, and appends what is missing. Appending one row at a time is
  /// the one insertion every backend does correctly: just_audio_media_kit
  /// cannot insert within a playlist.
  Future<void> _applyRows() async {
    final player = _player;
    if (!_rowsStale || player == null) return;
    _rowsStale = false;
    final wanted = _upcoming();
    final first = _playlistIndex + 1;
    var kept = 0;
    while (kept < wanted.length &&
        first + kept < _rows.length &&
        _rows[first + kept].sameMedia(wanted[kept])) {
      kept++;
    }
    final stale = _rows.length;
    _rows = [..._rows.take(first), ...wanted.take(kept)];
    if (first + kept < stale) {
      await player.removeAudioSourceRange(first + kept, stale);
    }
    for (final row in wanted.skip(kept)) {
      if (player != _player || _rowsStale) return;
      _rows = [..._rows, row];
      await player.addAudioSource(_source(row.source));
    }
    if (player != _player || _rowsStale) return;
    final loopMode = _nativeLoopMode;
    if (player.loopMode != loopMode) await player.setLoopMode(loopMode);
    if (player == _player) _planBoundary();
  }

  /// A playing track whose row was removed does not repeat: its next
  /// transition returns to the queue.
  LoopMode get _nativeLoopMode =>
      _queueIndex < 0 && _repeatMode == AudioRepeatMode.track
      ? LoopMode.off
      : _loopMode(_repeatMode);

  /// Abandons a selection that is still preparing; the active decoder keeps
  /// playing.
  void cancelLoad() {
    _loadToken++;
    _pendingSeekPosition = null;
    final candidate = _preparingPlayer;
    _preparingPlayer = null;
    if (candidate != null) {
      _restorePlaybackIntent();
      unawaited(candidate.dispose().catchError((Object _) {}));
    }
  }

  /// Releases every decoder.
  Future<void> clearSource() async {
    _loadToken++;
    _pendingSeekPosition = null;
    _playbackWanted = false;
    final player = _player;
    final preparing = _preparingPlayer;
    _player = null;
    _preparingPlayer = null;
    _cancelRamp();
    _cancelBoundary();
    _queue = const [];
    _rows = const [];
    _rowSync = Future.value();
    _rowsStale = false;
    _detachedSuccessor = -1;
    _queueIndex = -1;
    _playlistIndex = -1;
    _activeSource = null;
    _activeTrackId = null;
    _pendingLoadedGeneration = null;
    _cancelSubscriptionsSoon();
    if (player != null) {
      // The released decoder can no longer report its own final state, and
      // system controls must not keep advertising it as playing.
      _session.onEngineEvent(
        AudioStateChanged(AudioPlaybackState.stopped, _generation),
      );
    }
    for (final decoder in <AudioPlayer>{?player, ?preparing}) {
      try {
        await decoder.dispose();
      } catch (error) {
        debugPrint("AudioEngine: player cleanup failed: $error");
      }
    }
  }

  AudioEngineSnapshot snapshot() {
    final player = _player;
    final metadata = _session.currentMetadata;
    return AudioEngineSnapshot(
      generation: _generation,
      trackId: _activeTrackId,
      source: _activeSource,
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      artworkUri: metadata.artworkUri,
      queueIndex: _queueIndex,
      position: player?.position,
      duration: player?.duration,
      playing: player?.playing ?? false,
    );
  }

  /// Starts playback. A positive [position] seeks first; zero keeps the
  /// position a preparing selection was requested at.
  Future<void> play({Duration position = Duration.zero}) async {
    _playbackWanted = true;
    _retainPlayback();
    if (_preparingPlayer != null) {
      if (position > Duration.zero) _pendingSeekPosition = position;
      return;
    }
    final player = _player;
    if (player != null) await _resume(player, position: position);
  }

  Future<void> resume() async {
    _playbackWanted = true;
    _retainPlayback();
    final player = _player;
    if (_preparingPlayer == null && player != null) await _resume(player);
  }

  Future<void> pause() async {
    _playbackWanted = false;
    await _player?.pause();
  }

  Future<void> seek(Duration position) async {
    final player = _player;
    if (_preparingPlayer != null) {
      _pendingSeekPosition = position;
    } else if (player != null) {
      await _seekCurrent(player, position);
    }
  }

  /// Sets the listener's volume, which the active row's normalization gain
  /// scales. Applied at once, cutting short a gain fade.
  void setVolume(double value) {
    _volume = value.clamp(0, 1).toDouble();
    _cancelRamp();
    // Nearing a transition, the next track's level is the one to keep.
    _setPlayerVolume(_level(_boundaryGain ?? _gain));
    final preparing = _preparingPlayer;
    if (preparing != null && !identical(preparing, _player)) {
      _sendVolume(preparing, _level(_preparingGain));
    }
    _planBoundary();
  }

  /// How long a new gain for the playing row takes to fade in.
  static const gainRamp = Duration(milliseconds: 1500);

  /// How long before a gapless transition to a quieter row the outgoing
  /// track eases down to that row's level. The engine learns of a native
  /// transition only after it is audible, so without this the next track's
  /// first moments would play at the previous track's gain.
  static const boundaryLead = Duration(milliseconds: 150);
  static const _boundarySlack = Duration(milliseconds: 50);

  /// Moves the active decoder to the volume times [gain]: at once for a new
  /// track, or as a fade when the playing track's gain changes.
  void _applyGain(double gain, {required bool fade}) {
    _gain = _clampGain(gain);
    _boundaryGain = null;
    final to = _level(_gain);
    if (fade) {
      _rampVolume(to, gainRamp, const Duration(milliseconds: 50));
    } else {
      _cancelRamp();
      _setPlayerVolume(to);
    }
    _planBoundary();
  }

  /// Moves the active decoder's volume to [to] over [duration], in equal
  /// steps of decibels (which sound even).
  void _rampVolume(double to, Duration duration, Duration step) {
    _cancelRamp();
    final from = _appliedVolume;
    final steps = max(1, duration.inMicroseconds ~/ step.inMicroseconds);
    if (steps == 1 || from <= 0 || to <= 0 || (from - to).abs() < 0.001) {
      _setPlayerVolume(to);
      return;
    }
    var done = 0;
    _ramp = Timer.periodic(step, (timer) {
      done++;
      _setPlayerVolume(
        done >= steps ? to : from * pow(to / from, done / steps),
      );
      if (done >= steps) _cancelRamp();
    });
  }

  /// The gain of the row a native transition would play next, when it
  /// differs from the active row's.
  double? _nextGain(AudioPlayer player) {
    final next = player.nextIndex;
    if (next == null || next == player.currentIndex || next >= _rows.length) {
      return null;
    }
    final row = _rows[next].queueIndex;
    if (row < 0 || row >= _queue.length) return null;
    final gain = _clampGain(_queue[row].gain);
    return (gain - _gain).abs() < 0.001 ? null : gain;
  }

  /// Schedules the volume change for the next gapless transition from the
  /// playhead, so it lands on the boundary rather than when the engine
  /// hears about it. Replanned on every play, pause, seek, track, queue,
  /// gain, and volume change; an approach that did not end in a transition
  /// (a pause or seek near the end) is undone.
  void _planBoundary() {
    _cancelBoundaryTimer();
    final player = _player;
    final duration = player?.duration;
    final active =
        player != null &&
        duration != null &&
        player.playing &&
        player.processingState == ProcessingState.ready;
    final next = active ? _nextGain(player) : null;
    if (_boundaryGain case final heading?) {
      // Still heading for the same transition: let the approach finish.
      if (active &&
          next == heading &&
          duration - player.position <= boundaryLead + _boundarySlack) {
        return;
      }
      _boundaryGain = null;
      _cancelRamp();
      _setPlayerVolume(_level(_gain));
    }
    if (!active || next == null) return;
    // A louder next track switches at the boundary; a quieter one is
    // reached by then.
    final lead = next < _gain ? boundaryLead : Duration.zero;
    final wait = duration - player.position - lead;
    _boundaryTimer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => _approachBoundary(player, duration),
    );
  }

  void _approachBoundary(AudioPlayer player, Duration duration) {
    _boundaryTimer = null;
    if (player != _player || !player.playing) return;
    final next = _nextGain(player);
    if (next == null) return;
    final remaining = duration - player.position;
    // Timers can fire early; wait for the edge if it is still far off.
    if (remaining > boundaryLead + _boundarySlack) {
      _planBoundary();
      return;
    }
    _boundaryGain = next;
    final to = _level(next);
    if (next < _gain && remaining > Duration.zero) {
      _rampVolume(to, remaining, const Duration(milliseconds: 25));
    } else {
      _cancelRamp();
      _setPlayerVolume(to);
    }
  }

  void _cancelBoundaryTimer() {
    _boundaryTimer?.cancel();
    _boundaryTimer = null;
  }

  void _cancelBoundary() {
    _cancelBoundaryTimer();
    _boundaryGain = null;
  }

  void _cancelRamp() {
    _ramp?.cancel();
    _ramp = null;
  }

  void _setPlayerVolume(double value) {
    _appliedVolume = value;
    final player = _player;
    if (player != null) _sendVolume(player, value);
  }

  void _sendVolume(AudioPlayer player, double level) {
    unawaited(
      _applyLevel(player, level).catchError((Object error) {
        _playerError(player, error);
      }),
    );
  }

  /// How far normalization may raise a quiet track on this platform, in dB.
  /// Android adds gain with its LoudnessEnhancer effect; media_kit (mpv)
  /// plays volumes up to 130%; AVPlayer on Apple platforms only attenuates.
  static double get maxBoostDb => _android
      ? 12
      : _mpvVolume
      ? 6
      : 0;

  /// How far, in dB, a boost may push peaks over full scale because the
  /// engine limits them. LoudnessEnhancer compresses what its gain would
  /// clip; mpv's volume has no limiter, so a boost there must fit under the
  /// track's peaks.
  static double get limiterHeadroomDb => _android ? 6 : 0;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// [maxBoostDb] as a linear amplitude factor.
  static double get maxGain => pow(10, maxBoostDb / 20).toDouble();

  static double _clampGain(double gain) =>
      gain.isFinite ? gain.clamp(0, maxGain).toDouble() : 1;

  /// mpv applies `(volume / 100)^3`, so an amplitude factor is its cube root
  /// there; other decoders take amplitude as it is.
  static bool get _mpvVolume =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// The decoder level for the listener's volume scaled by [gain]. Above 1
  /// it is a boost: mpv takes it as a volume over 100%, and Android splits
  /// it into full volume plus LoudnessEnhancer gain.
  double _level(double gain) =>
      _volume * (_mpvVolume ? pow(gain, 1 / 3).toDouble() : gain);

  /// Each Android decoder's gain stage for boosts.
  final _enhancers = Expando<AndroidLoudnessEnhancer>();

  AudioPlayer _newPlayer() {
    if (!_android) return AudioPlayer();
    final enhancer = AndroidLoudnessEnhancer();
    final player = AudioPlayer(
      audioPipeline: AudioPipeline(androidAudioEffects: [enhancer]),
    );
    _enhancers[player] = enhancer;
    return player;
  }

  Future<void> _applyLevel(AudioPlayer player, double level) async {
    final enhancer = _enhancers[player];
    if (enhancer == null) {
      await player.setVolume(level);
      return;
    }
    final boostDb = level > 1 ? 20 * log(level) / ln10 : 0.0;
    // The effect is only switched on while it boosts, so unboosted
    // playback takes exactly the same path as without normalization.
    if (boostDb > 0.01) {
      if ((enhancer.targetGain - boostDb).abs() > 0.01) {
        await enhancer.setTargetGain(boostDb);
      }
      if (!enhancer.enabled) await enhancer.setEnabled(true);
    } else if (enhancer.enabled) {
      await enhancer.setEnabled(false);
    }
    await player.setVolume(min(level, 1));
  }

  /// Carries out a system media command on the decoder. Returns false when
  /// the command needs application policy instead.
  Future<bool> handleMediaAction(
    MediaCommand command, {
    Duration? seekPosition,
  }) async {
    final player = _player;
    switch (command) {
      case MediaCommand.play:
        if (player == null) return false;
        _playbackWanted = true;
        _retainPlayback();
        // A preparing selection starts itself when ready, like an app resume.
        if (_preparingPlayer == null) await _resume(player);
        return true;
      case MediaCommand.pause:
        _playbackWanted = false;
        if (player == null) return false;
        await player.pause();
        return true;
      case MediaCommand.skipToNext:
        if (player == null || _queue.isEmpty) return false;
        final next = _playlistIndex + 1;
        if (next < _rows.length) {
          await player.seek(Duration.zero, index: next);
        } else {
          _playbackWanted = false;
          await player.pause();
          await _seekCurrent(player, Duration.zero);
        }
        return true;
      case MediaCommand.skipToPrevious:
        if (player == null || _queue.isEmpty) return false;
        // A rewind stays on this decoder. An earlier row is not in its
        // playlist, so the app selects it like any other row.
        if (player.position > const Duration(seconds: 5) ||
            (_queueIndex == 0 && _repeatMode != AudioRepeatMode.queue)) {
          await _seekCurrent(player, Duration.zero);
          return true;
        }
        return false;
      case MediaCommand.seekTo:
        if (player == null || seekPosition == null) return false;
        await _seekCurrent(player, seekPosition);
        return true;
      case MediaCommand.rewind:
      case MediaCommand.fastForward:
        if (player == null) return false;
        final delta = Duration(
          seconds: command == MediaCommand.rewind ? -10 : 10,
        );
        await _seekCurrent(player, player.position + delta);
        return true;
      case MediaCommand.stop:
        final generation = _generation;
        try {
          await clearSource();
        } finally {
          _event(AudioStateChanged(AudioPlaybackState.stopped, generation));
          await _session.deactivateForStop();
        }
        return true;
      case MediaCommand.shuffleUpcoming:
      case MediaCommand.cycleRepeat:
      case MediaCommand.toggleFavorite:
        return false;
    }
  }

  // -- decoder management --------------------------------------------------

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
      _session.ensurePlaybackActive().catchError((Object error) {
        debugPrint("AudioEngine: media session unavailable: $error");
      }),
    );
  }

  AudioSource _source(String source) {
    // Most sources are file paths, one per queue row: parse only likely URLs.
    final uri =
        source.length > 5 && source.substring(0, 4).toLowerCase() == "http"
        ? Uri.tryParse(source)
        : null;
    return uri?.scheme == "http" || uri?.scheme == "https"
        ? AudioSource.uri(uri!)
        : AudioSource.file(source);
  }

  /// Repeating the queue needs no native mode: its playlist wraps by itself.
  LoopMode _loopMode(AudioRepeatMode mode) =>
      mode == AudioRepeatMode.track ? LoopMode.one : LoopMode.off;

  /// Prepares [rows], the playing row first, beside the active decoder and
  /// swaps them in when ready, so the old selection keeps playing until then.
  Future<void> _select({
    required List<_NativeRow> rows,
    required List<AudioQueueItem> queue,
    required int generation,
    required AudioRepeatMode repeatMode,
    required bool autoplay,
    required Duration position,
    required double gain,
  }) async {
    final token = ++_loadToken;
    _pendingSeekPosition = null;
    _playbackWanted = autoplay;
    if (autoplay) _retainPlayback();
    final candidate = _newPlayer();
    _preparingPlayer = candidate;
    _preparingGain = _clampGain(gain);
    try {
      await _ensureSession();
      await _applyLevel(candidate, _level(_preparingGain));
      await candidate.setLoopMode(_loopMode(repeatMode));
      final duration = await candidate
          .setAudioSources(
            [for (final row in rows) _source(row.source)],
            initialIndex: 0,
            initialPosition: position < Duration.zero
                ? Duration.zero
                : position,
          )
          .timeout(const Duration(seconds: 20));
      if (token != _loadToken) return;
      final previous = _player;
      final active = rows.first;
      _preparingPlayer = null;
      _cancelSubscriptionsSoon();
      _player = candidate;
      _queue = queue;
      _repeatMode = repeatMode;
      _rows = rows;
      // Whatever the old decoder is doing, even hung, is no longer relevant.
      _rowSync = Future.value();
      _rowsStale = false;
      _playlistIndex = 0;
      _queueIndex = active.queueIndex;
      _detachedSuccessor = -1;
      _activeSource = active.source;
      _activeTrackId = active.queueIndex >= 0 ? active.trackId : null;
      _generation = generation;
      _reportedErrorGeneration = null;
      _pendingLoadedGeneration = null;
      _positionBucket = -1;
      _reportedDuration = null;
      _listen(candidate);
      // The candidate was prepared at this level.
      _cancelRamp();
      _gain = _preparingGain;
      _appliedVolume = _level(_gain);
      if (_queueIndex >= 0) _announceTrack(queue[_queueIndex]);
      if (previous != null) {
        try {
          await previous.pause();
        } catch (error) {
          debugPrint("AudioEngine: retiring player pause failed: $error");
        }
        unawaited(previous.dispose().catchError((Object _) {}));
      }
      _announceLoaded(candidate, generation, duration: duration);
      final pendingSeek = _pendingSeekPosition;
      _pendingSeekPosition = null;
      if (pendingSeek != null) await _seekCurrent(candidate, pendingSeek);
      if (token == _loadToken && _playbackWanted) _startPlaying(candidate);
    } catch (_) {
      if (token != _loadToken) return;
      if (!identical(_player, candidate)) _restorePlaybackIntent();
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
    // durationStream is distinct across items, so a transition to an equally
    // long track would never report its duration. Playback events carry the
    // index and duration together.
    _subscriptions.add(
      player.playbackEventStream.listen((event) {
        if (player != _player) return;
        _onIndex(player, event.currentIndex);
        _reportDuration(player, _generation);
        // The playhead may have jumped (a seek, a stall, a native skip).
        _planBoundary();
      }, onError: (Object error) => _playerError(player, error)),
    );
    _subscriptions.add(
      player.positionStream.listen((position) {
        if (player != _player) return;
        _onIndex(player, player.currentIndex);
        final bucket = position.inMilliseconds ~/ 1000;
        if (bucket == _positionBucket) return;
        _positionBucket = bucket;
        _event(AudioPositionChanged(position, _generation));
      }, onError: (Object error) => _playerError(player, error)),
    );
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        // Idle only follows the stop that releases a finished decoder, whose
        // reload reports its own phases.
        if (player != _player ||
            state.processingState == ProcessingState.idle) {
          return;
        }
        _onIndex(player, player.currentIndex);
        // Playing, pausing, buffering, and completing move the boundary.
        _planBoundary();
        if (state.processingState == ProcessingState.ready &&
            _pendingLoadedGeneration == _generation) {
          _pendingLoadedGeneration = null;
          _announceLoaded(player, _generation);
        }
        // System controls extrapolate from the position published with each
        // phase change, so every phase starts from the decoder's exact
        // playhead rather than the last one-second tick.
        _publishPosition(player);
        if (state.processingState == ProcessingState.loading ||
            state.processingState == ProcessingState.buffering) {
          // The media session shows buffering; the app's play intent stays
          // unchanged until the decoder reports ready or completed.
          _session.onEngineEvent(
            AudioStateChanged(AudioPlaybackState.loading, _generation),
          );
          return;
        }
        // The decoder ran out of rows while the queue has more: this isolate
        // fell behind, or an edit removed the row it had just moved to.
        if (state.processingState == ProcessingState.completed &&
            _upcoming().isNotEmpty) {
          unawaited(_continueQueue(player));
          return;
        }
        final phase = state.processingState == ProcessingState.completed
            ? AudioPlaybackState.completed
            : state.playing
            ? AudioPlaybackState.playing
            : AudioPlaybackState.paused;
        _event(AudioStateChanged(phase, _generation));
      }, onError: (Object error) => _playerError(player, error)),
    );
  }

  void _onIndex(AudioPlayer player, int? index) {
    if (player != _player ||
        index == null ||
        index == _playlistIndex ||
        index >= _rows.length) {
      return;
    }
    final row = _rows[index];
    _playlistIndex = index;
    if (row.trackId.isEmpty) return;
    // An edit waiting its turn may already have renumbered the queue.
    final queue = _queue;
    final position = reconcileNativeQueue(
      queue.length,
      (row) => queue[row].trackId,
      row.trackId,
      row.queueIndex,
    );
    _queueIndex = position.activeIndex;
    _detachedSuccessor = position.detachedSuccessorIndex;
    if (_queueIndex < 0) {
      // Its row left the queue just as the decoder moved to it.
      _activeSource = row.source;
      _activeTrackId = row.trackId;
      _syncRowsInBackground(player);
      return;
    }
    final item = queue[_queueIndex];
    _activeSource = item.source;
    _activeTrackId = item.trackId;
    // Explicit app requests use even generations; native transitions use
    // odd ones so a concurrent request can never share a generation.
    _generation = _generation.isEven ? _generation + 1 : _generation + 2;
    _positionBucket = -1;
    _reportedDuration = null;
    _reportedErrorGeneration = null;
    _pendingLoadedGeneration = _generation;
    // The new track starts at its own level straight away.
    _applyGain(item.gain, fade: false);
    _announceTrack(item);
    _event(AudioTrackChanged(item.trackId, _queueIndex, _generation));
    if (player.processingState == ProcessingState.ready) {
      _pendingLoadedGeneration = null;
      _announceLoaded(player, _generation);
    }
    // Slides the window forward.
    _syncRowsInBackground(player);
  }

  void _syncRowsInBackground(AudioPlayer player) => unawaited(
    _syncRows().catchError((Object error) => _playerError(player, error)),
  );

  /// Moves a decoder that ended early on to the queue's next row.
  Future<void> _continueQueue(AudioPlayer player) async {
    if (identical(_continuing, player)) return;
    _continuing = player;
    try {
      await _syncRows();
      final next = _playlistIndex + 1;
      if (player != _player || next >= _rows.length) return;
      // A completed decoder drops play() until a pause clears it.
      await player.pause();
      if (_completionOutlivesSeek) await player.stop();
      await player.seek(Duration.zero, index: next);
      if (_playbackWanted) _startPlaying(player);
    } catch (error) {
      _playerError(player, error);
    } finally {
      if (identical(_continuing, player)) _continuing = null;
    }
  }

  void _announceTrack(AudioQueueItem item) {
    _session.onEngineTrack(
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
    _event(AudioFailed("Native audio playback failed: $error", _generation));
  }

  void _startPlaying(AudioPlayer player) {
    unawaited(
      player.play().catchError((Object error) {
        _playerError(player, error);
      }),
    );
  }

  /// Starts the active decoder. just_audio ignores play() on a completed
  /// source, so a Play press after completion restarts it like a new request.
  Future<void> _resume(AudioPlayer player, {Duration? position}) async {
    if (player.processingState == ProcessingState.completed && player.playing) {
      // just_audio keeps `playing` true after completion and drops play()
      // until a pause clears it; media_kit also stays at the end after a seek.
      await player.pause();
    }
    if (position != null && position > Duration.zero) {
      await _seekCurrent(player, position);
    } else if (player.processingState == ProcessingState.completed) {
      await _seekCurrent(player, Duration.zero);
    }
    _startPlaying(player);
  }

  /// Play intent of an abandoned selection must not leak into later queue
  /// edits, which rebuild the retained decoder with the current intent.
  void _restorePlaybackIntent() {
    _playbackWanted = _player?.playing ?? false;
  }

  void _cancelSubscriptionsSoon() {
    final old = List<StreamSubscription<dynamic>>.from(_subscriptions);
    _subscriptions.clear();
    for (final subscription in old) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  void _event(AudioEngineEvent event) {
    _session.onEngineEvent(event);
    _listener?.call(event);
  }

  /// Reports that the selection is ready, followed by its duration. The app
  /// drops durations that arrive while it waits for a transition to load, so
  /// one reported before this is sent again.
  void _announceLoaded(
    AudioPlayer player,
    int generation, {
    Duration? duration,
  }) {
    _event(AudioLoaded(generation));
    _reportedDuration = null;
    _reportDuration(player, generation, duration: duration);
  }

  /// Reports the active item's duration once per value and track.
  void _reportDuration(
    AudioPlayer player,
    int generation, {
    Duration? duration,
  }) {
    final current = duration ?? player.duration;
    if (player != _player || current == null || current == _reportedDuration) {
      return;
    }
    _reportedDuration = current;
    _event(AudioDurationChanged(current, generation));
    _planBoundary();
  }

  void _publishPosition(AudioPlayer player) {
    if (player != _player) return;
    final position = player.position;
    _positionBucket = position.inMilliseconds ~/ 1000;
    _event(AudioPositionChanged(position, _generation));
  }

  /// just_audio_media_kit stays `completed` after a seek out of the end, so
  /// the decoder would play without ever reporting playing or completion
  /// again, and the next Play would only seek a paused, finished source.
  bool get _completionOutlivesSeek =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  Future<void> _seekCurrent(AudioPlayer player, Duration position) async {
    if (_completionOutlivesSeek &&
        player.processingState == ProcessingState.completed) {
      // Release the finished decoder. just_audio keeps the index and the
      // position below, and the next play reloads the source from there.
      await player.stop();
    }
    await player.seek(position < Duration.zero ? Duration.zero : position);
    if (player == _player) _planBoundary();
    // A paused seek can remain in the same one-second bucket. Publish its
    // exact position instead of waiting for the next periodic decoder tick.
    _publishPosition(player);
  }
}
