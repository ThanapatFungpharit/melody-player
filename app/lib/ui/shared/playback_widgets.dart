import "dart:async";
import "dart:math";

import "package:flutter/material.dart" hide RepeatMode;
import "package:flutter/scheduler.dart";

import "../app_state.dart";
import "../../application/models.dart";
import "format.dart";

/// What the player shows for the current selection.
class NowPlayingInfo {
  const NowPlayingInfo(
    this.title,
    this.credit,
    this.thumbnail,
    this.favorite,
    this.canFavorite,
  );

  final String title;
  final String credit;
  final String thumbnail;
  final bool favorite;
  final bool canFavorite;

  static NowPlayingInfo of(MelodyApp app) {
    final playback = app.playback;
    var title = playback.externalTitle.isNotEmpty
        ? playback.externalTitle
        : "Nothing playing";
    var credit = playback.externalUploader.isNotEmpty
        ? playback.externalUploader
        : "Choose music to start listening";
    var thumbnail = playback.externalThumbnail;
    var favorite = false;
    var canFavorite = false;
    final id = playback.currentTrackId;
    if (id != null &&
        playback.externalTitle.isEmpty &&
        app.services.manager.hasTrack(id)) {
      final track = app.services.manager.getTrack(id);
      final details = app.services.library.details(id);
      title = track.displayTitle;
      credit = details.credit;
      thumbnail = details.thumbnail;
      favorite = details.favorite;
      canFavorite = true;
    }
    if (playback.loading) credit = "Preparing track…";
    return NowPlayingInfo(title, credit, thumbnail, favorite, canFavorite);
  }
}

/// Calls [onTick] with the estimated playback position on every playback
/// update and, while the position advances, again once it reaches
/// [nextChange] of the last one: the next position at which the caller
/// shows something different (null: nothing until the next update). Views redraw when they visibly change rather
/// than every frame, so playback leaves the UI idle between those moments.
class PositionTicker {
  PositionTicker(this.app, this.onTick, {required this.nextChange}) {
    app.playbackProgress.addListener(_changed);
    _schedule(app.estimatedPositionMs());
  }

  final MelodyApp app;
  final void Function(int positionMs) onTick;

  /// The first position after the given one that changes what is shown.
  final int? Function(int positionMs) nextChange;
  Timer? _timer;

  void _changed() => _tick();

  /// Reschedules after what the caller shows changed by itself.
  void refresh() => _schedule(app.estimatedPositionMs());

  void _tick() {
    final position = app.estimatedPositionMs();
    onTick(position);
    _schedule(position);
  }

  void _schedule(int positionMs) {
    _timer?.cancel();
    _timer = null;
    // Hidden or minimized, nothing draws; the next engine report after
    // the app resumes reschedules.
    if (!app.positionAdvancing || !SchedulerBinding.instance.framesEnabled) {
      return;
    }
    final next = nextChange(positionMs);
    if (next == null) return;
    // A stalled stream holds the estimate still; poll at frame rate at most.
    _timer = Timer(Duration(milliseconds: max(16, next - positionMs)), _tick);
  }

  void dispose() {
    app.playbackProgress.removeListener(_changed);
    _timer?.cancel();
  }
}

/// Rebuilds with the playback position whenever the clock's second or the
/// bar's device pixel changes, rather than every frame.
class LivePosition extends StatefulWidget {
  const LivePosition(this.app, {super.key, required this.builder});

  final MelodyApp app;
  final Widget Function(BuildContext context, int positionMs) builder;

  @override
  State<LivePosition> createState() => _LivePositionState();
}

class _LivePositionState extends State<LivePosition> {
  late final PositionTicker _ticker;
  late int _position;
  double _pixelRatio = 1;

  @override
  void initState() {
    super.initState();
    _position = widget.app.estimatedPositionMs();
    _ticker = PositionTicker(widget.app, _tick, nextChange: _nextChange);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(int position) {
    if (position != _position) setState(() => _position = position);
  }

  int _nextChange(int positionMs) {
    final second = (positionMs ~/ 1000 + 1) * 1000;
    final duration = widget.app.playback.durationMs;
    // The physical pixels the position can span: at most the whole width.
    final box = context.findRenderObject();
    final pixels = box is RenderBox && box.hasSize
        ? box.size.width * _pixelRatio
        : 0.0;
    if (duration <= 0 || pixels <= 0) return second;
    final perPixel = duration / pixels;
    final pixel = ((positionMs / perPixel).floor() + 1) * perPixel;
    return min(second, pixel.ceil());
  }

  @override
  Widget build(BuildContext context) {
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return widget.builder(context, _position);
  }
}

/// Seek slider that keeps the user's drag position until release. Inline
/// puts the times beside the track; [stacked] puts them underneath.
class SeekBar extends StatefulWidget {
  const SeekBar(this.app, {super.key, this.stacked = false});

  final MelodyApp app;
  final bool stacked;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return LivePosition(
      app,
      builder: (context, positionMs) {
        final playback = app.playback;
        final duration = playback.durationMs;
        final max = duration > 0 ? duration.toDouble() : 1.0;
        final value = duration > 0
            ? (_dragging ?? positionMs.toDouble()).clamp(0.0, max)
            : 0.0;
        final scheme = Theme.of(context).colorScheme;
        final style = TextStyle(
          fontSize: 11.5,
          color: scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        final position = Text(
          formatMilliseconds(_dragging?.toInt() ?? positionMs),
          textAlign: widget.stacked ? TextAlign.left : TextAlign.right,
          style: style,
        );
        final total = Text(
          playback.loading
              ? "Loading…"
              : duration > 0
              ? formatMilliseconds(duration)
              : "–:––",
          textAlign: widget.stacked ? TextAlign.right : TextAlign.left,
          style: style,
        );
        final slider = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: scheme.primary,
            thumbColor: scheme.primary,
            overlayColor: scheme.primary.withValues(alpha: 0.12),
            trackHeight: widget.stacked ? 5 : 4,
            padding: widget.stacked ? EdgeInsets.zero : null,
          ),
          child: Slider(
            value: value,
            max: max,
            onChangeStart: duration > 0
                ? (value) => setState(() => _dragging = value)
                : null,
            onChanged: duration > 0
                ? (value) => setState(() => _dragging = value)
                : null,
            onChangeEnd: duration > 0
                ? (value) {
                    setState(() => _dragging = null);
                    playback.seek(value.toInt());
                  }
                : null,
          ),
        );
        if (widget.stacked) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 28, child: slider),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [position, total],
              ),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 44, child: position),
            Expanded(child: SizedBox(height: 22, child: slider)),
            SizedBox(width: 52, child: total),
          ],
        );
      },
    );
  }
}

IconData repeatIcon(RepeatMode mode) =>
    mode == RepeatMode.track ? Icons.repeat_one_rounded : Icons.repeat_rounded;

String repeatLabel(RepeatMode mode) => switch (mode) {
  RepeatMode.off => "Repeat off",
  RepeatMode.track => "Repeat track",
  RepeatMode.playlist => "Repeat queue",
};
