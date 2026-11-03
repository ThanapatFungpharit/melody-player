import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../controllers/library_controller.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class LibraryPage extends StatefulWidget {
  const LibraryPage(this.app, {super.key});

  final MelodyApp app;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.app.library.queryText,
  );

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final library = app.library;
    return ListenableBuilder(
      listenable: Listenable.merge([
        library,
        app.libraryRevision,
        app.playbackState,
      ]),
      builder: (context, _) {
        final ids = library.visibleIds();
        final total = app.services.manager.counts().$1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: 8,
              children: [
                Expanded(
                  child: Heading(
                    "Library",
                    total == 0
                        ? "Your favorites, downloads, and local discoveries."
                        : "${plural(total, "track")} saved on this device",
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => pickLocalFiles(app),
                  icon: const Icon(Icons.library_add_rounded, size: 19),
                  label: const Text("Add files"),
                ),
                IconButton(
                  onPressed: total == 0 ? null : () => exportLibrary(app),
                  tooltip: "Export library",
                  icon: const Icon(Icons.ios_share_rounded),
                ),
              ],
            ),
            const SizedBox(height: 22),
            if (library.selecting)
              _SelectionBar(app)
            else
              Row(
                spacing: 6,
                children: [
                  PlayCircle(
                    onPressed: ids.isEmpty ? null : library.playVisible,
                    tooltip: "Play all",
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: ids.isEmpty ? null : library.shuffleVisible,
                    tooltip: "Shuffle these tracks",
                    icon: const Icon(Icons.shuffle_rounded),
                  ),
                  IconButton(
                    onPressed: ids.isEmpty ? null : library.startSelecting,
                    tooltip: "Select tracks",
                    icon: const Icon(Icons.checklist_rounded),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _query,
                      onChanged: library.setQuery,
                      decoration: const InputDecoration(
                        hintText: "Find in your library",
                        prefixIcon: Icon(Icons.search_rounded, size: 20),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: "Sort tracks",
                    initialValue: library.sortKey,
                    position: PopupMenuPosition.under,
                    onSelected: library.setSort,
                    itemBuilder: (context) => [
                      for (final MapEntry(:key, :value) in librarySorts.entries)
                        PopupMenuItem(
                          value: key,
                          height: 40,
                          child: Text(value),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 6,
                        children: [
                          Text(
                            librarySorts[library.sortKey] ?? "Sort",
                            style: context.text.labelLarge!.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                          Icon(
                            Icons.sort_rounded,
                            size: 18,
                            color: context.colors.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 20),
            Expanded(
              child: ids.isEmpty
                  ? const EmptyState(
                      Icons.library_music_rounded,
                      "Nothing matches this view. Search for music or add local files.",
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TrackListHeader(
                          numbered: !library.selecting,
                          leadingWidth: library.selecting ? 48 : 0,
                          trailingWidth: 48 + 40 + 8,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView.builder(
                            itemCount: ids.length,
                            prototypeItem: TrackListRow(
                              app: app,
                              number: 1,
                              title: LazyShelf.sampleText,
                              subtitle: LazyShelf.sampleText,
                              artwork: "",
                              favorite: false,
                              trailing: [ActionMenu(() => const [])],
                            ),
                            itemBuilder: (context, index) =>
                                LibraryTrackRow(app, ids[index], index),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// What can be done with the selected tracks.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar(this.app);

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final library = app.library;
    return Row(
      spacing: 6,
      children: [
        IconButton(
          onPressed: library.stopSelecting,
          tooltip: "Stop selecting",
          icon: const Icon(Icons.close_rounded),
        ),
        Text(
          "${library.selectedIds.length} selected",
          style: context.text.titleSmall,
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: library.toggleSelectAll,
          child: const Text("Select all"),
        ),
        const Spacer(),
        for (final action in selectedTracksActions(context, app))
          IconButton(
            onPressed: action.enabled ? action.onSelected : null,
            tooltip: action.label,
            icon: Icon(action.icon),
          ),
      ],
    );
  }
}

class LibraryTrackRow extends StatelessWidget {
  const LibraryTrackRow(this.app, this.trackId, this.index, {super.key});

  final MelodyApp app;
  final String trackId;

  /// Where the track is among the visible ones.
  final int index;

  @override
  Widget build(BuildContext context) {
    // A row may outlive its track for a frame while a deletion finishes.
    if (!app.services.manager.hasTrack(trackId)) return const SizedBox.shrink();
    final library = app.library;
    final track = app.services.manager.getTrack(trackId);
    final details = app.services.library.details(trackId);
    final selecting = library.selecting;
    return TrackListRow(
      app: app,
      number: selecting ? null : index + 1,
      leading: selecting
          ? Checkbox(
              value: library.selected.contains(trackId),
              onChanged: (_) => library.toggleSelected(trackId),
            )
          : null,
      title: track.displayTitle,
      subtitle: details.credit,
      artwork: app.services.library.artwork(trackId),
      duration: formatDuration(details.duration),
      favorite: details.favorite,
      onFavorite: () => app.toggleFavorite(trackId),
      onTap: selecting ? () => library.toggleSelected(trackId) : null,
      onPlay: selecting ? null : () => library.playFrom(index),
      playTooltip: "Play from here",
      current: app.playback.currentTrackId == trackId,
      trailing: [
        ActionMenu(() => libraryTrackActions(context, app, track, details)),
      ],
    );
  }
}
