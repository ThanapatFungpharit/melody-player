import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/actions.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";
import "../shell.dart";

class QueuePanel extends StatefulWidget {
  const QueuePanel(this.app, {super.key});

  final MelodyApp app;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final ScrollController _scroll = ScrollController();
  String _query = "";

  @override
  void initState() {
    super.initState();
    // Opens at the current track, then follows the user.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final queue = widget.app.playback.queue;
      scrollToRow(_scroll, queue.currentIndex, queue.items.length);
    });
  }

  void _find(String query) {
    setState(() => _query = query);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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
          final filtering = _query.trim().isNotEmpty;
          final rows = [
            for (var index = 0; index < queue.items.length; index++)
              if (app.services.manager.hasTrack(queue.items[index]) &&
                  (!filtering ||
                      app.services.library.matches(queue.items[index], _query)))
                index,
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
              if (queue.items.isNotEmpty)
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
                      message: "Shuffle the queue",
                      child: _Chip(
                        icon: Icons.shuffle_rounded,
                        label: "Shuffle",
                        onPressed: queue.canShuffle ? app.shuffleQueue : null,
                      ),
                    ),
                    Tooltip(
                      message: "Remove every track but the current one",
                      child: _Chip(
                        icon: Icons.clear_all_rounded,
                        label: "Clear",
                        onPressed: queue.items.length <= 1
                            ? null
                            : app.clearQueue,
                      ),
                    ),
                  ],
                ),
              if (queue.items.length > findableRows)
                TextField(
                  onChanged: _find,
                  decoration: const InputDecoration(
                    hintText: "Find in the queue",
                    prefixIcon: Icon(Icons.search_rounded, size: 20),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(
                        Icons.queue_music_rounded,
                        filtering
                            ? "Nothing in the queue matches this."
                            : "Your temporary playback queue is empty.",
                      )
                    : ReorderableListView.builder(
                        scrollController: _scroll,
                        buildDefaultDragHandles: false,
                        itemCount: rows.length,
                        prototypeItem: TrackListRow(
                          app: app,
                          leading: const SizedBox(width: 26, height: 44),
                          title: LazyShelf.sampleText,
                          subtitle: LazyShelf.sampleText,
                          artwork: "",
                          status: "Queued",
                          favorite: false,
                          onPlay: () {},
                          trailing: [ActionMenu(() => const [])],
                        ),
                        onReorderItem: (oldIndex, newIndex) =>
                            app.playback.reorderQueue(
                              rows[oldIndex],
                              queueDropSlot(rows, oldIndex, newIndex),
                            ),
                        itemBuilder: (context, row) {
                          final index = rows[row];
                          final trackId = queue.items[index];
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
                              enabled: !filtering,
                              child: MouseRegion(
                                cursor: filtering
                                    ? MouseCursor.defer
                                    : SystemMouseCursors.grab,
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
                            artwork: app.services.library.artwork(trackId),
                            status: status,
                            statusHighlight:
                                current || status.startsWith("Up next"),
                            favorite: details.favorite,
                            onFavorite: () => app.toggleFavorite(trackId),
                            onPlay: () => app.playback.playQueueIndex(index),
                            playTooltip: "Play from here",
                            trailing: [
                              ActionMenu(
                                () =>
                                    queueRowActions(context, app, index, track),
                              ),
                            ],
                          );
                        },
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
