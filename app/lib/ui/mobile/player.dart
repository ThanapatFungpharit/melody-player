import "dart:math";
import "dart:ui";

import "package:flutter/material.dart" hide RepeatMode;

import "../app_state.dart";
import "../../application/models.dart";
import "../shared/actions.dart";
import "../shared/playback_widgets.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";
import "controls.dart";
import "pages/lyrics_page.dart";
import "pages/queue_page.dart";

/// Fling speed, in logical pixels per second, that counts as a swipe.
const _flingVelocity = 300.0;

/// Swipes on [child]: left plays the next track and right the previous one;
/// [onSwipeUp] answers an upward swipe.
class _TrackSwipe extends StatelessWidget {
  const _TrackSwipe(this.app, {required this.child, this.onSwipeUp});

  final MelodyApp app;
  final Widget child;
  final VoidCallback? onSwipeUp;

  @override
  Widget build(BuildContext context) {
    final playback = app.playback;
    final hasMedia =
        playback.currentTrackId != null || playback.externalTitle.isNotEmpty;
    return GestureDetector(
      onHorizontalDragEnd: hasMedia
          ? (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity < -_flingVelocity) playback.next();
              if (velocity > _flingVelocity) playback.previous();
            }
          : null,
      onVerticalDragEnd: onSwipeUp == null
          ? null
          : (details) {
              if ((details.primaryVelocity ?? 0) < -_flingVelocity) {
                onSwipeUp!();
              }
            },
      child: child,
    );
  }
}

/// Closes the page when it is pulled down past its top.
class _PullToClose extends StatefulWidget {
  const _PullToClose({required this.child});

  final Widget child;

  @override
  State<_PullToClose> createState() => _PullToCloseState();
}

class _PullToCloseState extends State<_PullToClose> {
  static const _distance = 80.0;
  double _pulled = 0;
  bool _closing = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final dragging = switch (notification) {
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      OverscrollNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _pulled = 0;
    } else if (notification is OverscrollNotification && dragging) {
      // Clamping physics report the pull as overscroll at the top edge.
      if (notification.overscroll < 0) _pulled -= notification.overscroll;
    } else if (dragging) {
      // Bouncing physics move past the top instead.
      _pulled = max(0, -notification.metrics.pixels);
    }
    if (_pulled > _distance && !_closing) {
      _closing = true;
      Navigator.of(context).maybePop();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener(onNotification: _onScroll, child: widget.child);
}

/// The mini player floating above the navigation bar.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    void open() => pushPanel(
      context,
      app,
      AppPanel.player,
      NowPlaying(app),
      immersive: true,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.large),
        clipBehavior: Clip.antiAlias,
        child: Watch(
          [app.playbackState, app.libraryRevision],
          builder: (context) {
            final playback = app.playback;
            final info = NowPlayingInfo.of(app);
            final hasMedia =
                playback.currentTrackId != null ||
                playback.externalTitle.isNotEmpty;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: "Open Now Playing",
                        child: _TrackSwipe(
                          app,
                          onSwipeUp: open,
                          child: InkWell(
                            onTap: open,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                              child: Row(
                                spacing: 12,
                                children: [
                                  Artwork(
                                    app,
                                    info.thumbnail,
                                    size: 42,
                                    seed: hasMedia ? info.title : "",
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      spacing: 1,
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
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    TouchIconButton(
                      playback.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      playback.playing ? "Pause" : "Play",
                      hasMedia ? playback.toggle : null,
                    ),
                    TouchIconButton(
                      Icons.skip_next_rounded,
                      "Next track",
                      hasMedia ? playback.next : null,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
                LivePosition(
                  app,
                  builder: (context, positionMs) {
                    final duration = knownDurationMs(app);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: LinearProgressIndicator(
                        value: duration > 0 ? min(1, positionMs / duration) : 0,
                        minHeight: 2,
                        color: scheme.primary,
                        backgroundColor: scheme.onSurface.withValues(
                          alpha: 0.12,
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Now Playing; device buttons adjust volume, so only mute is offered.
class NowPlaying extends StatelessWidget {
  const NowPlaying(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => Watch(
    [app.playbackState, app.playbackVolume, app.libraryRevision],
    builder: (context) {
      final scheme = context.colors;
      final dark = Theme.of(context).brightness == Brightness.dark;
      final playback = app.playback;
      final info = NowPlayingInfo.of(app);
      final hasMedia =
          playback.currentTrackId != null || playback.externalTitle.isNotEmpty;
      final repeat = playback.queue.repeat;
      final muted = playback.muted || playback.volume == 0;
      // The backdrop takes the same hue as the cover placeholder, so a
      // track keeps its color from list to full screen.
      final tint = hasMedia
          ? HSLColor.fromAHSL(
              1,
              seedHue(info.title),
              dark ? 0.35 : 0.45,
              dark ? 0.28 : 0.80,
            ).toColor()
          : scheme.surfaceContainerHigh;
      return Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.75],
                colors: [tint, scheme.surface],
              ),
            ),
          ),
          if (info.thumbnail.isNotEmpty)
            Positioned.fill(
              child: Opacity(
                opacity: dark ? 0.35 : 0.3,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.transparent],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      child: Artwork(app, info.thumbnail, size: 400),
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final gutter = constraints.maxWidth < 360 ? 16.0 : 24.0;
                final cover = min(
                  constraints.maxWidth - gutter * 2,
                  max(180.0, constraints.maxHeight - 430),
                );
                // Fills tall screens by spreading the gaps; scrolls when the
                // window is too short for everything.
                return _PullToClose(
                  child: SingleChildScrollView(
                    // Always draggable, so a pull down can close the page.
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 16),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: max(0, constraints.maxHeight - 20),
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Transform.translate(
                                  offset: const Offset(-12, 0),
                                  child: TouchIconButton(
                                    Icons.keyboard_arrow_down_rounded,
                                    "Close Now Playing",
                                    () => Navigator.of(context).maybePop(),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    "NOW PLAYING",
                                    textAlign: TextAlign.center,
                                    style: context.text.labelSmall!.copyWith(
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: touchTarget - 12),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Spacer(),
                            _TrackSwipe(
                              app,
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      Radii.panel,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: dark ? 0.45 : 0.18,
                                        ),
                                        blurRadius: 40,
                                        offset: const Offset(0, 18),
                                      ),
                                    ],
                                  ),
                                  child: Artwork(
                                    app,
                                    info.thumbnail,
                                    size: cover,
                                    seed: hasMedia ? info.title : "",
                                    radius: Radii.panel,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 28),
                            const Spacer(),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    spacing: 4,
                                    children: [
                                      Text(
                                        info.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.headlineSmall,
                                      ),
                                      Text(
                                        info.credit,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.bodyLarge!.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: info.canFavorite
                                      ? () => app.toggleFavorite(
                                          playback.currentTrackId!,
                                        )
                                      : null,
                                  tooltip: info.favorite
                                      ? "Remove favorite"
                                      : "Favorite",
                                  iconSize: 26,
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
                            ),
                            const SizedBox(height: 18),
                            SeekBar(app, stacked: true),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TouchIconButton(
                                  Icons.shuffle_rounded,
                                  "Shuffle upcoming tracks",
                                  playback.queue.upcomingCount >= 2
                                      ? playback.shuffleUpcoming
                                      : null,
                                ),
                                IconButton(
                                  onPressed: hasMedia
                                      ? playback.previous
                                      : null,
                                  tooltip: "Previous track",
                                  iconSize: 38,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                ),
                                IconButton.filled(
                                  onPressed: hasMedia ? playback.toggle : null,
                                  tooltip: playback.playing ? "Pause" : "Play",
                                  iconSize: 40,
                                  style: IconButton.styleFrom(
                                    fixedSize: const Size.square(72),
                                    backgroundColor: scheme.onSurface,
                                    foregroundColor: scheme.surface,
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
                                  iconSize: 38,
                                  icon: const Icon(Icons.skip_next_rounded),
                                ),
                                IconButton(
                                  onPressed: playback.cycleRepeat,
                                  tooltip: repeatLabel(repeat),
                                  constraints: const BoxConstraints.tightFor(
                                    width: touchTarget,
                                    height: touchTarget,
                                  ),
                                  icon: Icon(
                                    repeatIcon(repeat),
                                    color: repeat != RepeatMode.off
                                        ? scheme.primary
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Spacer(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TouchIconButton(
                                  Icons.lyrics_outlined,
                                  "Lyrics",
                                  () => pushPanel(
                                    context,
                                    app,
                                    AppPanel.lyrics,
                                    MobileLyrics(app),
                                  ),
                                ),
                                TouchIconButton(
                                  muted
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                  muted ? "Restore sound" : "Mute",
                                  playback.toggleMute,
                                ),
                                Watch(
                                  [app.sleepTimerState],
                                  builder: (context) => TouchIconButton(
                                    app.sleepTimer.active
                                        ? Icons.bedtime_rounded
                                        : Icons.bedtime_outlined,
                                    sleepTimerStatus(app.sleepTimer),
                                    () => showActionSheet(
                                      context,
                                      sleepTimerStatus(app.sleepTimer),
                                      sleepTimerActions(app),
                                    ),
                                    color: app.sleepTimer.active
                                        ? scheme.primary
                                        : null,
                                  ),
                                ),
                                TouchIconButton(
                                  Icons.stop_rounded,
                                  "Stop playback and clear notification",
                                  hasMedia ? playback.stop : null,
                                ),
                                // Five controls leave no room for the
                                // label on the narrowest phones.
                                if (constraints.maxWidth < 360)
                                  TouchIconButton(
                                    Icons.queue_music_rounded,
                                    "Queue",
                                    () => pushPanel(
                                      context,
                                      app,
                                      AppPanel.queue,
                                      MobileQueue(app),
                                    ),
                                  )
                                else
                                  TextButton.icon(
                                    onPressed: () => pushPanel(
                                      context,
                                      app,
                                      AppPanel.queue,
                                      MobileQueue(app),
                                    ),
                                    icon: const Icon(Icons.queue_music_rounded),
                                    label: const Text("Queue"),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
