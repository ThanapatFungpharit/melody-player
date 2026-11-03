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
    return Watch(
      [app.playbackState, app.libraryRevision],
      builder: (context) {
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
        return reorderablePage(
          controller: _scroll,
          onReorder: (oldIndex, newIndex) => app.playback.reorderQueue(
            rows[oldIndex],
            queueDropSlot(rows, oldIndex, newIndex),
          ),
          reorderable: !filtering,
          header: [
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
            if (queue.items.isNotEmpty) ...[
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
                  Tooltip(
                    message: "Shuffle the queue",
                    child: chip(
                      Icons.shuffle_rounded,
                      "Shuffle",
                      queue.canShuffle ? app.shuffleQueue : null,
                    ),
                  ),
                  Tooltip(
                    message: "Remove every track but the current one",
                    child: chip(
                      Icons.clear_all_rounded,
                      "Clear",
                      queue.items.length <= 1 ? null : app.clearQueue,
                    ),
                  ),
                ],
              ),
            ],
            if (queue.items.length > findableRows)
              TextField(
                onChanged: _find,
                decoration: const InputDecoration(
                  hintText: "Find in the queue",
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
          ],
          itemCount: rows.length,
          itemBuilder: (context, row) {
            final index = rows[row];
            final trackId = queue.items[index];
            final track = app.services.manager.getTrack(trackId);
            final details = app.services.library.details(trackId);
            return TrackRow(
              key: ValueKey("queue:$index:$trackId"),
              app: app,
              title: track.displayTitle,
              credit:
                  "${queueItemStatus(queue, index)} · ${details.uploader.isEmpty ? "Queued track" : details.uploader}",
              artwork: app.services.library.artwork(trackId),
              selected: index == queue.currentIndex,
              favorite: details.favorite,
              onTap: () => app.playback.playQueueIndex(index),
              leading: filtering ? null : reorderHandle(context, row),
              trailing: MoreButton(
                track.displayTitle,
                () => queueRowActions(context, app, index, track),
              ),
            );
          },
          footer: [
            if (rows.isEmpty)
              EmptyState(
                Icons.queue_music_rounded,
                filtering
                    ? "Nothing in the queue matches this."
                    : "Play music or add tracks to start your queue.",
              ),
          ],
        );
      },
    );
  }
}
