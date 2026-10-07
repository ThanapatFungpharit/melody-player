import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/actions.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class MobileQueue extends StatefulWidget {
  const MobileQueue(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileQueue> createState() => _MobileQueueState();
}

class _MobileQueueState extends State<MobileQueue> {
  int? _offset;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = context.colors;
    return Watch(
      [app.playbackState, app.libraryRevision],
      builder: (context) {
        final queue = app.playback.queue;
        final mode = queueModeStatus(queue);
        _offset ??=
            (queue.currentIndex < 0 ? 0 : queue.currentIndex) ~/ 50 * 50;
        final (start, end) = pageBounds(queue.items.length, _offset!);
        _offset = start;
        final rows = <Widget>[];
        for (var index = start; index < end; index++) {
          final trackId = queue.items[index];
          if (!app.services.manager.hasTrack(trackId)) continue;
          final track = app.services.manager.getTrack(trackId);
          final details = app.services.library.details(trackId);
          final position = index;
          rows.add(
            TrackRow(
              app: app,
              title: track.displayTitle,
              credit:
                  "${queueItemStatus(queue, index)} · ${details.uploader.isEmpty ? "Queued track" : details.uploader}",
              artwork: details.thumbnail,
              selected: index == queue.currentIndex,
              onTap: () => app.playback.playQueueIndex(position),
              trailing: MoreButton(
                track.displayTitle,
                () => queueRowActions(app, position),
              ),
            ),
          );
        }
        Widget chip(
          IconData icon,
          String label,
          VoidCallback? onPressed, {
          bool active = false,
        }) => TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 38),
            backgroundColor: active
                ? scheme.primary.withValues(alpha: 0.12)
                : scheme.surfaceContainer,
            foregroundColor: active ? scheme.primary : scheme.onSurface,
            textStyle: context.text.labelMedium,
          ),
          icon: Icon(icon, size: 17),
          label: Text(label),
        );
        return scrollPage([
          MobileHeading(
            "Queue",
            subtitle: "${queue.items.length} tracks · ${mode.label}",
            large: true,
            actions: [
              TouchIconButton(
                Icons.arrow_back_rounded,
                "Back",
                () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          if (rows.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                chip(
                  mode.icon,
                  mode.label,
                  app.playback.cycleRepeat,
                  active: true,
                ),
                chip(
                  Icons.shuffle_rounded,
                  "Shuffle upcoming",
                  queue.upcomingCount < 2 ? null : app.playback.shuffleUpcoming,
                ),
                chip(
                  Icons.clear_all_rounded,
                  "Clear upcoming",
                  queue.items.length <= 1 ? null : app.playback.clearQueue,
                ),
              ],
            ),
          ],
          ...rows,
          if (queue.items.length > 50)
            PageNavigation(
              total: queue.items.length,
              start: start,
              end: end,
              onChange: (direction) =>
                  setState(() => _offset = start + direction * 50),
            ),
          if (rows.isEmpty)
            const EmptyState(
              Icons.queue_music_rounded,
              "Play music or add tracks to start your queue.",
            ),
        ]);
      },
    );
  }
}
