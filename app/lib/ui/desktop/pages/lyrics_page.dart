import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/lyrics_view.dart";
import "../../shared/playback_widgets.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../shell.dart";

class LyricsPanel extends StatelessWidget {
  const LyricsPanel(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Watch(
          [app.playbackState, app.playbackVolume, app.libraryRevision],
          builder: (context) {
            final playback = app.playback;
            final info = NowPlayingInfo.of(app);
            final muted = playback.muted || playback.volume == 0;
            return ContextHeader(
              app,
              "Lyrics",
              "${info.title} · ${info.credit}",
              compact: constraints.maxWidth < 600,
              actions: [
                IconButton(
                  onPressed: info.canFavorite
                      ? () => app.toggleFavorite(playback.currentTrackId!)
                      : null,
                  tooltip: info.favorite ? "Remove favorite" : "Favorite",
                  icon: Icon(
                    info.favorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: info.favorite ? context.palette.favorite : null,
                  ),
                ),
                IconButton(
                  onPressed: playback.toggleMute,
                  tooltip: muted ? "Unmute" : "Mute",
                  icon: Icon(
                    muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  ),
                ),
              ],
            );
          },
        ),
        Expanded(child: LyricsView(app)),
      ],
    ),
  );
}
