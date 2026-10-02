import "package:flutter/material.dart" hide RepeatMode;

import "../../app/app_state.dart";
import "../../application/models.dart";
import "format.dart";
import "widgets.dart";

/// What the player shows for the current selection.
class NowPlayingInfo {
  const NowPlayingInfo(this.title, this.credit, this.thumbnail, this.favorite, this.canFavorite);

  final String title;
  final String credit;
  final String thumbnail;
  final bool favorite;
  final bool canFavorite;

  static NowPlayingInfo of(MelodyApp app) {
    final playback = app.playback;
    var title = playback.externalTitle.isNotEmpty ? playback.externalTitle : "Nothing playing";
    var credit = playback.externalUploader.isNotEmpty
        ? playback.externalUploader
        : "Choose music to start listening";
    var thumbnail = playback.externalThumbnail;
    var favorite = false;
    var canFavorite = false;
    final id = playback.currentTrackId;
    if (id != null && playback.externalTitle.isEmpty && app.services.manager.hasTrack(id)) {
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

/// Seek slider that keeps the user's drag position until release.
class SeekBar extends StatefulWidget {
  const SeekBar(this.app, {super.key, this.compact = false});

  final MelodyApp app;
  final bool compact;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Watch([app.playbackProgress], builder: (context) {
      final playback = app.playback;
      final duration = playback.durationMs;
      final max = duration > 0 ? duration.toDouble() : 1.0;
      final value = duration > 0 ? (_dragging ?? playback.positionMs.toDouble()).clamp(0.0, max) : 0.0;
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      final style = TextStyle(fontSize: 11, color: muted);
      return Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(formatMilliseconds(_dragging?.toInt() ?? playback.positionMs), style: style),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value,
                max: max,
                onChangeStart: duration > 0 ? (value) => setState(() => _dragging = value) : null,
                onChanged: duration > 0 ? (value) => setState(() => _dragging = value) : null,
                onChangeEnd: duration > 0
                    ? (value) {
                        setState(() => _dragging = null);
                        playback.seek(value.toInt());
                      }
                    : null,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              playback.loading ? "Loading…" : formatMilliseconds(duration),
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
        ],
      );
    });
  }
}

IconData repeatIcon(RepeatMode mode) =>
    mode == RepeatMode.track ? Icons.repeat_one_rounded : Icons.repeat_rounded;

String repeatLabel(RepeatMode mode) => switch (mode) {
  RepeatMode.off => "Repeat off",
  RepeatMode.track => "Repeat track",
  RepeatMode.playlist => "Repeat queue",
};
