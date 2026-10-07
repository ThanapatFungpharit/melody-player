import "package:flutter/material.dart" hide RepeatMode;

import "../app_state.dart";
import "../../application/models.dart";
import "../shared/playback_widgets.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";

/// Persistent transport and volume controls along the bottom of the window.
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final width = MediaQuery.sizeOf(context).width;
    return SizedBox(
      height: 88,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
        child: Watch(
          [app.playbackState, app.libraryRevision],
          builder: (context) {
            final playback = app.playback;
            final info = NowPlayingInfo.of(app);
            final hasMedia =
                playback.currentTrackId != null ||
                playback.externalTitle.isNotEmpty;
            final repeat = playback.queue.repeat;
            return Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Row(
                    children: [
                      Artwork(
                        app,
                        info.thumbnail,
                        size: 58,
                        seed: hasMedia ? info.title : "",
                      ),
                      const SizedBox(width: 14),
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 3,
                          children: [
                            Text(
                              info.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.titleSmall,
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
                      if (width >= 1000) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          onPressed: info.canFavorite
                              ? () =>
                                    app.toggleFavorite(playback.currentTrackId!)
                              : null,
                          tooltip: info.favorite
                              ? "Remove favorite"
                              : "Favorite",
                          iconSize: 20,
                          icon: Icon(
                            info.favorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: info.favorite
                                ? context.palette.favorite
                                : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 4,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 2,
                      children: [
                        IconButtonTheme(
                          data: const IconButtonThemeData(
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            spacing: 6,
                            children: [
                              IconButton(
                                onPressed: playback.queue.upcomingCount >= 2
                                    ? playback.shuffleUpcoming
                                    : null,
                                tooltip: "Shuffle upcoming tracks",
                                iconSize: 20,
                                icon: const Icon(Icons.shuffle_rounded),
                              ),
                              IconButton(
                                onPressed: hasMedia ? playback.previous : null,
                                tooltip: "Previous track",
                                iconSize: 26,
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                              IconButton.filled(
                                onPressed: hasMedia ? playback.toggle : null,
                                tooltip: playback.playing ? "Pause" : "Play",
                                iconSize: 26,
                                style: IconButton.styleFrom(
                                  fixedSize: const Size.square(40),
                                  minimumSize: const Size.square(40),
                                  backgroundColor: scheme.onSurface,
                                  foregroundColor: scheme.surface,
                                  disabledBackgroundColor:
                                      scheme.surfaceContainerHighest,
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
                                iconSize: 26,
                                icon: const Icon(Icons.skip_next_rounded),
                              ),
                              IconButton(
                                onPressed: playback.cycleRepeat,
                                tooltip: repeatLabel(repeat),
                                iconSize: 20,
                                icon: _ActiveDot(
                                  active: repeat != RepeatMode.off,
                                  child: Icon(
                                    repeatIcon(repeat),
                                    color: repeat != RepeatMode.off
                                        ? scheme.primary
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SeekBar(app),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 3,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ValueListenableBuilder(
                        valueListenable: app.activePanel,
                        builder: (context, panel, _) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (target, tooltip, icon) in const [
                              (
                                AppPanel.lyrics,
                                "Lyrics (Ctrl+Y)",
                                Icons.lyrics_outlined,
                              ),
                              (
                                AppPanel.queue,
                                "Queue (Ctrl+Q)",
                                Icons.queue_music_rounded,
                              ),
                            ])
                              IconButton(
                                onPressed: () => panel == target
                                    ? app.closePanel()
                                    : app.openPanel(target),
                                tooltip: tooltip,
                                isSelected: panel == target,
                                iconSize: 20,
                                icon: _ActiveDot(
                                  active: panel == target,
                                  child: Icon(
                                    icon,
                                    color: panel == target
                                        ? scheme.primary
                                        : null,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: hasMedia ? playback.stop : null,
                        tooltip: "Stop playback and clear notification",
                        iconSize: 20,
                        icon: const Icon(Icons.stop_rounded),
                      ),
                      _VolumeControls(app, wide: width >= 1280),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Marks an active toggle with a small accent dot under its icon.
class _ActiveDot extends StatelessWidget {
  const _ActiveDot({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    alignment: Alignment.center,
    children: [
      child,
      if (active)
        Positioned(
          bottom: -7,
          child: Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: context.colors.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
    ],
  );
}

class _VolumeControls extends StatelessWidget {
  const _VolumeControls(this.app, {required this.wide});

  final MelodyApp app;
  final bool wide;

  @override
  Widget build(BuildContext context) => Watch(
    [app.playbackVolume],
    builder: (context) {
      final playback = app.playback;
      final muted = playback.muted || playback.volume == 0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: playback.toggleMute,
            tooltip: muted ? "Unmute" : "Mute",
            iconSize: 20,
            icon: Icon(
              muted
                  ? Icons.volume_off_rounded
                  : playback.volume < 50
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
            ),
          ),
          SizedBox(
            width: wide ? 112 : 84,
            child: Tooltip(
              message: "Volume ${playback.volume}%",
              child: Slider(
                value: playback.volume.toDouble(),
                max: 100,
                divisions: 100,
                label: "${playback.volume}%",
                onChanged: (value) =>
                    playback.setVolume(value.round(), persist: false),
                onChangeEnd: (value) => playback.setVolume(value.round()),
              ),
            ),
          ),
          if (wide)
            SizedBox(
              width: 34,
              child: Text(
                "${playback.volume}",
                textAlign: TextAlign.right,
                style: context.text.bodySmall!.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      );
    },
  );
}
