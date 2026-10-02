import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../shared/actions.dart";
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
    final scheme = Theme.of(context).colorScheme;
    return Watch([app.playbackState, app.libraryRevision], builder: (context) {
      final queue = app.playback.queue;
      final mode = queueModeStatus(queue);
      final (start, end) = _paging.visibleRange(queue.items.length, queue.currentIndex);
      final rows = <(int, String)>[
        for (var index = start; index < end; index++)
          if (app.services.manager.hasTrack(queue.items[index])) (index, queue.items[index]),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          ContextHeader(app, "Queue", "${queue.items.length} tracks · ${mode.label}"),
          if (rows.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Icon(mode.icon, color: scheme.primary, size: 22),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(mode.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(mode.description, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Wrap(
              children: [
                TextButton.icon(
                  onPressed: queue.upcomingCount < 2 ? null : app.playback.shuffleUpcoming,
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text("Shuffle upcoming"),
                ),
                TextButton.icon(
                  onPressed: app.playback.cycleRepeat,
                  icon: Icon(mode.icon),
                  label: Text(mode.label),
                ),
                TextButton.icon(
                  onPressed: queue.items.length <= 1 ? null : app.playback.clearQueue,
                  icon: const Icon(Icons.clear_all_rounded),
                  label: const Text("Clear upcoming"),
                ),
              ],
            ),
          ],
          Expanded(
            child: rows.isEmpty
                ? const EmptyState(Icons.queue_music_rounded, "Your temporary playback queue is empty.")
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: rows.length,
                    onReorderItem: (oldIndex, newIndex) => app.playback.reorderQueue(
                      rows[oldIndex].$1,
                      start + (newIndex > oldIndex ? newIndex + 1 : newIndex),
                    ),
                    itemBuilder: (context, row) {
                      final (index, trackId) = rows[row];
                      final track = app.services.manager.getTrack(trackId);
                      final details = app.services.library.details(trackId);
                      final current = index == queue.currentIndex;
                      final status = queueItemStatus(queue, index);
                      final highlight = current || status.startsWith("Up next");
                      return Padding(
                        key: ValueKey("queue:$index:$trackId"),
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Surface(
                          selected: current,
                          radius: 14,
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            spacing: 8,
                            children: [
                              ReorderableDragStartListener(
                                index: row,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.grab,
                                  child: Tooltip(
                                    message: current ? "Current track • Drag to reorder" : "Drag to reorder",
                                    child: SizedBox(
                                      width: 28,
                                      height: 44,
                                      child: Icon(
                                        current ? Icons.volume_up_rounded : Icons.drag_indicator_rounded,
                                        size: 20,
                                        color: current ? scheme.primary : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Artwork(app, details.thumbnail, size: 48),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 3,
                                  children: [
                                    Text(
                                      track.displayTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: current ? FontWeight.bold : FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      details.credit,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                    ),
                                    Text(
                                      status,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                                        color: highlight ? scheme.primary : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => app.playback.playQueueIndex(index),
                                tooltip: "Play from here",
                                icon: const Icon(Icons.play_arrow_rounded),
                              ),
                              ActionMenu(() => queueRowActions(app, index)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (queue.items.length > 50)
            PageNavigation(
              total: queue.items.length,
              start: start,
              end: end,
              onChange: (direction) => setState(() => _paging.offset = (_paging.offset ?? 0) + direction * 50),
            ),
        ],
      );
    });
  }
}
