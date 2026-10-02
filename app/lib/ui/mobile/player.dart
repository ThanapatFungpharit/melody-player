import "dart:math";

import "package:flutter/material.dart" hide RepeatMode;

import "../../app/app_state.dart";
import "../../application/models.dart";
import "../shared/playback_widgets.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";
import "controls.dart";
import "pages.dart";

/// The mini player above the navigation bar.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Watch([app.playbackState, app.libraryRevision], builder: (context) {
        final playback = app.playback;
        final info = NowPlayingInfo.of(app);
        final hasMedia = playback.currentTrackId != null || playback.externalTitle.isNotEmpty;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              spacing: 4,
              children: [
                Expanded(
                  child: Tooltip(
                    message: "Open Now Playing",
                    child: InkWell(
                      onTap: () => pushPanel(context, app, AppPanel.player, NowPlaying(app)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          spacing: 10,
                          children: [
                            Icon(Icons.graphic_eq_rounded, color: scheme.primary),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 1,
                                children: [
                                  Text(
                                    info.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    info.credit,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: hasMedia ? playback.toggle : null,
                  tooltip: playback.playing ? "Pause" : "Play",
                  constraints: const BoxConstraints.tightFor(width: touchTarget, height: touchTarget),
                  icon: Icon(playback.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                TouchIconButton(Icons.skip_next_rounded, "Next track", hasMedia ? playback.next : null),
              ],
            ),
            Watch([app.playbackProgress], builder: (context) {
              final duration = app.playback.durationMs;
              return LinearProgressIndicator(
                value: min(1, app.playback.positionMs / max(1, duration)),
                minHeight: 3,
                color: scheme.primary,
              );
            }),
          ],
        );
      }),
    );
  }
}

/// Now Playing; device buttons adjust volume, so only mute is offered.
class NowPlaying extends StatelessWidget {
  const NowPlaying(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final cover = max(176.0, min(340.0, min(size.width - 64, size.height * 0.42)));
    return Watch([app.playbackState, app.playbackVolume, app.libraryRevision], builder: (context) {
      final playback = app.playback;
      final info = NowPlayingInfo.of(app);
      final hasMedia = playback.currentTrackId != null || playback.externalTitle.isNotEmpty;
      final repeat = playback.queue.repeat;
      final muted = playback.muted || playback.volume == 0;
      return ListView(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text("Now Playing", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ),
              TouchIconButton(
                Icons.keyboard_arrow_down_rounded,
                "Close Now Playing",
                () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          Padding(padding: const EdgeInsets.all(8), child: Center(child: Artwork(app, info.thumbnail, size: cover))),
          const SizedBox(height: 12),
          Text(
            info.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            info.credit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          SeekBar(app),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TouchIconButton(
                Icons.shuffle_rounded,
                "Shuffle upcoming tracks",
                playback.queue.upcomingCount >= 2 ? playback.shuffleUpcoming : null,
              ),
              TouchIconButton(Icons.skip_previous_rounded, "Previous track", hasMedia ? playback.previous : null),
              IconButton.filledTonal(
                onPressed: hasMedia ? playback.toggle : null,
                tooltip: playback.playing ? "Pause" : "Play",
                iconSize: 38,
                constraints: const BoxConstraints.tightFor(width: 64, height: 64),
                icon: Icon(playback.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              TouchIconButton(Icons.skip_next_rounded, "Next track", hasMedia ? playback.next : null),
              IconButton(
                onPressed: playback.cycleRepeat,
                tooltip: repeatLabel(repeat),
                constraints: const BoxConstraints.tightFor(width: touchTarget, height: touchTarget),
                icon: Icon(repeatIcon(repeat), color: repeat != RepeatMode.off ? scheme.primary : null),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: info.canFavorite ? () => app.toggleFavorite(playback.currentTrackId!) : null,
                tooltip: info.favorite ? "Remove favorite" : "Favorite",
                icon: Icon(
                  info.favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: info.favorite ? Colors.pink.shade400 : null,
                ),
              ),
              TouchIconButton(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                muted ? "Restore sound" : "Mute",
                playback.toggleMute,
              ),
              TouchIconButton(
                Icons.stop_rounded,
                "Stop playback and clear notification",
                playback.mediaSessionActive ? playback.stop : null,
              ),
              TextButton.icon(
                onPressed: () => pushPanel(context, app, AppPanel.queue, MobileQueue(app)),
                icon: const Icon(Icons.queue_music_rounded),
                label: const Text("Queue"),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "Use your device’s volume buttons to adjust loudness.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    });
  }
}
