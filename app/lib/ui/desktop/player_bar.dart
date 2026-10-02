import "package:flutter/material.dart" hide RepeatMode;

import "../../app/app_state.dart";
import "../../application/models.dart";
import "../shared/playback_widgets.dart";
import "../shared/widgets.dart";

/// Persistent transport and volume controls across the window.
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    return Container(
      height: 106,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(22)),
      child: Watch([app.playbackState, app.libraryRevision], builder: (context) {
        final playback = app.playback;
        final info = NowPlayingInfo.of(app);
        final hasMedia = playback.currentTrackId != null || playback.externalTitle.isNotEmpty;
        final repeat = playback.queue.repeat;
        return Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Artwork(app, info.thumbnail, size: 76),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          info.credit,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (width >= 1000)
                    IconButton(
                      onPressed: info.canFavorite ? () => app.toggleFavorite(playback.currentTrackId!) : null,
                      tooltip: info.favorite ? "Remove favorite" : "Favorite",
                      icon: Icon(
                        info.favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: info.favorite ? Colors.pink.shade400 : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 8,
                    children: [
                      IconButton(
                        onPressed: playback.queue.upcomingCount >= 2 ? playback.shuffleUpcoming : null,
                        tooltip: "Shuffle upcoming tracks",
                        icon: const Icon(Icons.shuffle_rounded, size: 21),
                      ),
                      IconButton(
                        onPressed: hasMedia ? playback.previous : null,
                        tooltip: "Previous track",
                        icon: const Icon(Icons.skip_previous_rounded, size: 21),
                      ),
                      IconButton.filled(
                        onPressed: hasMedia ? playback.toggle : null,
                        tooltip: playback.playing ? "Pause" : "Play",
                        iconSize: 30,
                        style: IconButton.styleFrom(fixedSize: const Size(46, 46)),
                        icon: Icon(playback.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      ),
                      IconButton(
                        onPressed: hasMedia ? playback.next : null,
                        tooltip: "Next track",
                        icon: const Icon(Icons.skip_next_rounded, size: 21),
                      ),
                      IconButton(
                        onPressed: playback.cycleRepeat,
                        tooltip: repeatLabel(repeat),
                        icon: Icon(
                          repeatIcon(repeat),
                          size: 21,
                          color: repeat != RepeatMode.off ? scheme.primary : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SeekBar(app),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 3,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _VolumeControls(app, wide: width >= 1280),
                  IconButton(
                    onPressed: playback.mediaSessionActive ? playback.stop : null,
                    tooltip: "Stop playback and clear notification",
                    icon: const Icon(Icons.stop_rounded, size: 21),
                  ),
                  ValueListenableBuilder(
                    valueListenable: app.activePanel,
                    builder: (context, panel, _) => IconButton(
                      onPressed: () => app.openPanel(AppPanel.queue),
                      tooltip: "Queue (Ctrl+Q)",
                      isSelected: panel == AppPanel.queue,
                      style: IconButton.styleFrom(
                        backgroundColor: panel == AppPanel.queue ? scheme.primaryContainer : null,
                      ),
                      icon: const Icon(Icons.queue_music_rounded, size: 21),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _VolumeControls extends StatelessWidget {
  const _VolumeControls(this.app, {required this.wide});

  final MelodyApp app;
  final bool wide;

  @override
  Widget build(BuildContext context) => Watch([app.playbackVolume], builder: (context) {
    final playback = app.playback;
    final muted = playback.muted || playback.volume == 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: playback.toggleMute,
          tooltip: muted ? "Unmute" : "Mute",
          icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 21),
        ),
        SizedBox(
          width: wide ? 105 : 80,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
            child: Slider(
              value: playback.volume.toDouble(),
              max: 100,
              divisions: 100,
              label: "${playback.volume}%",
              onChanged: (value) => playback.setVolume(value.round(), persist: false),
              onChangeEnd: (value) => playback.setVolume(value.round()),
            ),
          ),
        ),
        if (wide)
          SizedBox(width: 36, child: Text("${playback.volume}%", style: const TextStyle(fontSize: 11))),
      ],
    );
  });
}
