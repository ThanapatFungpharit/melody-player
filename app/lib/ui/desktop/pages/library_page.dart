import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../application/models.dart";
import "../../../core/library/models.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

const _sortLabels = {
  "recent": "Recently added",
  "oldest": "Oldest added",
  "title": "Title",
};

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
        final (tracks, hasMore) = library.page();
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
            Row(
              spacing: 6,
              children: [
                PlayCircle(
                  onPressed: tracks.isEmpty ? null : library.playVisible,
                  tooltip: "Play all",
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: tracks.isEmpty ? null : library.shuffleVisible,
                  tooltip: "Shuffle these tracks",
                  icon: const Icon(Icons.shuffle_rounded),
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
                    for (final MapEntry(:key, :value) in _sortLabels.entries)
                      PopupMenuItem(value: key, height: 40, child: Text(value)),
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
                          _sortLabels[library.sortKey] ?? "Sort",
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
              child: tracks.isEmpty
                  ? const EmptyState(
                      Icons.library_music_rounded,
                      "Nothing matches this view. Search for music or add local files.",
                    )
                  : _tracks(context, tracks, hasMore),
            ),
          ],
        );
      },
    );
  }

  Widget _tracks(BuildContext context, List<Track> tracks, bool hasMore) {
    final app = widget.app;
    final library = app.library;
    final details = app.services.library.detailsMany(
      tracks.map((track) => track.id),
    );
    final paged = library.pageOffset > 0 || hasMore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TrackListHeader(trailingWidth: 48 + 40 + 8),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length + (paged ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == tracks.length) {
                return Row(
                  children: [
                    TextButton.icon(
                      onPressed: library.pageOffset == 0
                          ? null
                          : () => library.changePage(-1),
                      icon: const Icon(Icons.chevron_left_rounded),
                      label: const Text("Previous"),
                    ),
                    Expanded(
                      child: Text(
                        "${library.pageOffset + 1}–${library.pageOffset + tracks.length}",
                        textAlign: TextAlign.center,
                        style: context.text.bodySmall,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: hasMore ? () => library.changePage(1) : null,
                      icon: const Icon(Icons.chevron_right_rounded),
                      label: const Text("Next"),
                      iconAlignment: IconAlignment.end,
                    ),
                  ],
                );
              }
              final track = tracks[index];
              return LibraryTrackRow(
                app,
                track,
                library.pageOffset + index,
                details[track.id]!,
              );
            },
          ),
        ),
      ],
    );
  }
}

class LibraryTrackRow extends StatelessWidget {
  const LibraryTrackRow(
    this.app,
    this.track,
    this.index,
    this.details, {
    super.key,
  });

  final MelodyApp app;
  final Track track;
  final int index;
  final TrackDetails details;

  @override
  Widget build(BuildContext context) => TrackListRow(
    app: app,
    number: index + 1,
    title: track.displayTitle,
    subtitle: details.credit,
    artwork: app.services.library.artwork(track.id),
    duration: formatDuration(details.duration),
    favorite: details.favorite,
    onFavorite: () => app.toggleFavorite(track.id),
    onPlay: () => app.library.playFrom(index),
    playTooltip: "Play from here",
    current: app.playback.currentTrackId == track.id,
    trailing: [
      ActionMenu(() => libraryTrackActions(context, app, track, details)),
    ],
  );
}
