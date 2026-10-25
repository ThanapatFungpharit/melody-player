import "dart:async";

import "playback.dart";

/// Minutes offered for a timed sleep timer.
const sleepTimerChoices = [15, 30, 45, 60, 90];

/// Pauses playback after a chosen time, or when the playing track ends.
///
/// The timer lives only in memory: it ends with the app or once it pauses.
/// Waiting for the end of a track also ends when nothing is left to play.
class SleepTimer {
  SleepTimer(
    this.playback, {
    DateTime Function()? now,
    Timer Function(Duration delay, void Function() callback)? createTimer,
  }) : _now = now ?? DateTime.now,
       _createTimer = createTimer ?? Timer.new {
    _subscription = playback.changes.listen(_playbackChanged);
  }

  final PlaybackController playback;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _createTimer;
  late final StreamSubscription<PlaybackChange> _subscription;

  /// Called whenever the timer starts, ends, or changes mode.
  void Function()? onChanged;

  DateTime? _deadline;
  bool _endOfTrack = false;
  Timer? _timer;

  bool get active => _deadline != null || _endOfTrack;

  /// Whether the timer waits for the playing track to end.
  bool get endOfTrack => _endOfTrack;

  /// Time left on a timed timer; null when it waits for the track to end
  /// or is off.
  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Pauses playback once [duration] has passed.
  void start(Duration duration) {
    _reset();
    _deadline = _now().add(duration);
    _timer = _createTimer(duration, _expire);
    onChanged?.call();
  }

  /// Pauses playback as the playing track ends, before the next one starts.
  void stopAtEndOfTrack() {
    _reset();
    _endOfTrack = true;
    _scheduleTrackEnd();
    onChanged?.call();
  }

  void cancel() {
    if (!active) return;
    _reset();
    onChanged?.call();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    _endOfTrack = false;
  }

  void _expire() {
    if (playback.playing) playback.toggle();
    _reset();
    onChanged?.call();
  }

  // The pause lands this far before the end, so the engine's gapless
  // handoff to the next track never starts.
  static const _trackEndLeadMs = 250;

  void _playbackChanged(PlaybackChange change) {
    if (!_endOfTrack || change == PlaybackChange.volume) return;
    // The queue ran out or was stopped: there is nothing left to pause.
    if (!playback.playing && !playback.loading && !playback.hasMedia) {
      cancel();
      return;
    }
    _scheduleTrackEnd();
  }

  /// Arms a pause for the end of the playing track, from the latest known
  /// position. Progress reports keep re-arming it, so seeks are followed.
  void _scheduleTrackEnd() {
    _timer?.cancel();
    _timer = null;
    final duration = playback.durationMs;
    if (!playback.playing || playback.loading || duration <= 0) return;
    final left = duration - playback.positionMs - _trackEndLeadMs;
    _timer = _createTimer(Duration(milliseconds: left < 0 ? 0 : left), _expire);
  }

  void close() {
    _timer?.cancel();
    unawaited(_subscription.cancel());
  }
}
