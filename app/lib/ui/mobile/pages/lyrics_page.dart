import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/lyrics_view.dart";
import "../../shared/playback_widgets.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class MobileLyrics extends StatelessWidget {
  const MobileLyrics(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Watch(
        [app.playbackState, app.libraryRevision],
        builder: (context) {
          final info = NowPlayingInfo.of(app);
          return Row(
            spacing: 12,
            children: [
              Artwork(app, info.thumbnail, size: 44, seed: info.title),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 1,
                  children: [
                    Text(
                      info.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.titleMedium,
                    ),
                    Text(
                      info.credit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall,
                    ),
                  ],
                ),
              ),
              TouchIconButton(
                Icons.keyboard_arrow_down_rounded,
                "Close lyrics",
                () => Navigator.of(context).maybePop(),
              ),
            ],
          );
        },
      ),
      Expanded(child: LyricsView(app)),
      const SizedBox(height: 8),
      SeekBar(app, stacked: true),
      Watch(
        [app.playbackState, app.playbackVolume, app.libraryRevision],
        builder: (context) {
          final playback = app.playback;
          final info = NowPlayingInfo.of(app);
          final hasMedia = playback.hasMedia;
          final muted = playback.muted || playback.volume == 0;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TouchIconButton(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                muted ? "Restore sound" : "Mute",
                playback.toggleMute,
              ),
              IconButton(
                onPressed: hasMedia ? playback.previous : null,
                tooltip: "Previous track",
                iconSize: 32,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton.filled(
                onPressed: hasMedia ? playback.toggle : null,
                tooltip: playback.playing ? "Pause" : "Play",
                iconSize: 32,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(56),
                  backgroundColor: context.colors.onSurface,
                  foregroundColor: context.colors.surface,
                ),
                icon: Icon(
                  playback.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                onPressed: hasMedia ? playback.next : null,
                tooltip: "Next track",
                iconSize: 32,
                icon: const Icon(Icons.skip_next_rounded),
              ),
              IconButton(
                onPressed: info.canFavorite
                    ? () => app.toggleFavorite(playback.currentTrackId!)
                    : null,
                tooltip: info.favorite ? "Remove favorite" : "Favorite",
                constraints: const BoxConstraints.tightFor(
                  width: touchTarget,
                  height: touchTarget,
                ),
                icon: Icon(
                  info.favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: info.favorite ? context.palette.favorite : null,
                ),
              ),
            ],
          );
        },
      ),
    ],
  );
}
