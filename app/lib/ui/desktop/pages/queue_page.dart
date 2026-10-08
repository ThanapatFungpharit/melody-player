import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/actions.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";
import "../shell.dart";

/// Starts on the page holding the current track, then follows the user.
class QueuePaging {
  int? offset;

  (int, int) visibleRange(int total, int currentIndex) {
    offset ??= (currentIndex < 0 ? 0 : currentIndex) ~/ 50 * 50;
    final (start, end) = pageBounds(total, offset!);
    offset = start;
    return (start, end);
  }
}

class QueuePanel extends StatefulWidget {
  const QueuePanel(this.app, {super.key});

  final MelodyApp app;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final QueuePaging _paging = QueuePaging();

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) => Watch(
        [app.playbackState, app.libraryRevision],
        builder: (context) {
          final compact = constraints.maxWidth < 600;
          final queue = app.playback.queue;
          final mode = queueModeStatus(queue);
          final (start, end) = _paging.visibleRange(
            queue.items.length,
            queue.currentIndex,
          );
          final rows = <(int, String)>[
            for (var index = start; index < end; index++)
              if (app.services.manager.hasTrack(queue.items[index]))
                (index, queue.items[index]),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              ContextHeader(
                app,
                "Queue",
                "${queue.items.length} tracks · ${mode.label}",
                compact: compact,
              ),
              if (rows.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Tooltip(
                      message: mode.description,
                      child: _Chip(
                        icon: mode.icon,
                        label: mode.label,
                        active: true,
                        onPressed: app.playback.cycleRepeat,
                      ),
                    ),
                    Tooltip(
                      message: "Shuffle upcoming tracks",
                      child: _Chip(
                        icon: Icons.shuffle_rounded,
                        label: "Shuffle",
                        onPressed: queue.upcomingCount < 2
                            ? null
                            : app.playback.shuffleUpcoming,
                      ),
                    ),
                    Tooltip(
                      message: "Clear upcoming tracks",
                      child: _Chip(
                        icon: Icons.clear_all_rounded,
                        label: "Clear",
                        onPressed: queue.items.length <= 1
                            ? null
                            : app.playback.clearQueue,
                      ),
                    ),
                  ],
                ),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(
                        Icons.queue_music_rounded,
                        "Your temporary playback queue is empty.",
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: rows.length,
                        onReorderItem: (oldIndex, newIndex) =>
                            app.playback.reorderQueue(
                              rows[oldIndex].$1,
                              start +
                                  (newIndex > oldIndex
                                      ? newIndex + 1
                                      : newIndex),
                            ),
                        itemBuilder: (context, row) {
                          final (index, trackId) = rows[row];
                          final track = app.services.manager.getTrack(trackId);
                          final details = app.services.library.details(trackId);
                          final current = index == queue.currentIndex;
                          final status = queueItemStatus(queue, index);
                          return TrackListRow(
                            key: ValueKey("queue:$index:$trackId"),
                            app: app,
                            current: current,
                            leading: ReorderableDragStartListener(
                              index: row,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Tooltip(
                                  message: current
                                      ? "Current track • Drag to reorder"
                                      : "Drag to reorder",
                                  child: SizedBox(
                                    width: 26,
                                    height: 44,
                                    child: Icon(
                                      current
                                          ? Icons.graphic_eq_rounded
                                          : Icons.drag_indicator_rounded,
                                      size: 18,
                                      color: current
                                          ? scheme.primary
                                          : scheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            title: track.displayTitle,
                            subtitle: details.credit,
                            artwork: details.thumbnail,
                            status: status,
                            statusHighlight:
                                current || status.startsWith("Up next"),
                            onPlay: () => app.playback.playQueueIndex(index),
                            playTooltip: "Play from here",
                            trailing: [
                              ActionMenu(() => queueRowActions(app, index)),
                            ],
                          );
                        },
                      ),
              ),
              if (queue.items.length > 50)
                PageNavigation(
                  total: queue.items.length,
                  start: start,
                  end: end,
                  onChange: (direction) => setState(
                    () =>
                        _paging.offset = (_paging.offset ?? 0) + direction * 50,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: active
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainer,
        foregroundColor: active ? scheme.primary : scheme.onSurface,
        textStyle: context.text.labelMedium,
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}
