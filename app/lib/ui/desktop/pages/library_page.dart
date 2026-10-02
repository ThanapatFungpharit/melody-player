import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../../application/models.dart";
import "../../../core/library/models.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/widgets.dart";
import "../controls.dart";
import "playlists_page.dart";

class LibraryPage extends StatefulWidget {
  const LibraryPage(this.app, {super.key});

  final MelodyApp app;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final TextEditingController _query = TextEditingController(text: widget.app.library.queryText);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final library = app.library;
    final scheme = Theme.of(context).colorScheme;
    InputDecoration field(String hint, {IconData? icon}) => InputDecoration(
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon),
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    );
    return ListenableBuilder(
      listenable: Listenable.merge([library, app.libraryRevision]),
      builder: (context, _) {
        final (tracks, hasMore) = library.page();
        final hasVisible = library.mode == "tracks" ? tracks.isNotEmpty : true;
        final playlists = app.services.manager.listPlaylists();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            ResponsiveGrid(
              spacing: 10,
              center: true,
              children: [
                const GridCell(Heading("Library", "Your favorites, downloads, and local discoveries."), lg: 7),
                GridCell(
                  Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        spacing: 6,
                        children: [
                          TextButton.icon(
                            onPressed: () => pickLocalFiles(app),
                            icon: const Icon(Icons.library_add_rounded),
                            label: const Text("Add files"),
                          ),
                          TextButton.icon(
                            onPressed: app.services.manager.counts().$1 == 0 ? null : () => exportLibrary(app),
                            icon: const Icon(Icons.ios_share_rounded),
                            label: const Text("Export library"),
                          ),
                          PrimaryButton(
                            "Play all",
                            Icons.play_arrow_rounded,
                            tracks.isEmpty ? null : library.playVisible,
                          ),
                          IconButton(
                            onPressed: tracks.isEmpty ? null : library.shuffleVisible,
                            tooltip: "Shuffle visible tracks",
                            icon: const Icon(Icons.shuffle_rounded),
                          ),
                          IconButton(
                            onPressed: tracks.isEmpty
                                ? null
                                : () => queueVisible(app),
                            tooltip: "Add visible tracks to queue",
                            icon: const Icon(Icons.add_to_queue_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                  lg: 5,
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: "tracks", icon: Icon(Icons.music_note_rounded), label: Text("Tracks")),
                  ButtonSegment(value: "playlists", icon: Icon(Icons.queue_music_rounded), label: Text("Playlists")),
                ],
                selected: {library.mode},
                showSelectedIcon: false,
                onSelectionChanged: (value) => library.setMode(value.first),
              ),
            ),
            ResponsiveGrid(
              spacing: 12,
              children: [
                GridCell(
                  TextField(
                    controller: _query,
                    onChanged: library.setQuery,
                    decoration: field("Find in your library", icon: Icons.search_rounded),
                  ),
                  md: 8,
                ),
                GridCell(
                  DropdownButtonFormField<String>(
                    initialValue: library.sortKey,
                    decoration: field(""),
                    items: const [
                      DropdownMenuItem(value: "recent", child: Text("Recently added")),
                      DropdownMenuItem(value: "oldest", child: Text("Oldest added")),
                      DropdownMenuItem(value: "title", child: Text("Title")),
                    ],
                    onChanged: (value) => library.setSort(value ?? "recent"),
                  ),
                  md: 4,
                ),
              ],
            ),
            Expanded(
              child: library.mode == "playlists"
                  ? _playlists(context)
                  : !hasVisible
                  ? const EmptyState(
                      Icons.library_music_rounded,
                      "Nothing matches this view. Search for music or add local files.",
                    )
                  : _tracks(context, tracks, hasMore, playlists),
            ),
          ],
        );
      },
    );
  }

  Widget _tracks(BuildContext context, List<Track> tracks, bool hasMore, List<Playlist> playlists) {
    final app = widget.app;
    final library = app.library;
    final details = app.services.library.detailsMany(tracks.map((track) => track.id));
    final paged = library.pageOffset > 0 || hasMore;
    return ListView.separated(
      itemCount: tracks.length + (paged ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        if (index == tracks.length) {
          return Row(
            children: [
              TextButton.icon(
                onPressed: library.pageOffset == 0 ? null : () => library.changePage(-1),
                icon: const Icon(Icons.chevron_left_rounded),
                label: const Text("Previous"),
              ),
              Expanded(
                child: Text(
                  "${library.pageOffset + 1}–${library.pageOffset + tracks.length}",
                  textAlign: TextAlign.center,
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
        return LibraryTrackRow(app, track, library.pageOffset + index, details[track.id]!, playlists);
      },
    );
  }

  Widget _playlists(BuildContext context) {
    final playlists = widget.app.library.matchingPlaylists();
    if (playlists.isEmpty) {
      return const EmptyState(
        Icons.library_music_rounded,
        "Nothing matches this view. Search for music or add local files.",
      );
    }
    return SingleChildScrollView(
      child: Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [for (final playlist in playlists) PlaylistCard(widget.app, playlist)],
      ),
    );
  }
}

void queueVisible(MelodyApp app) {
  final count = app.playback.addLastMany(app.library.visibleTracks().map((track) => track.id));
  if (count > 0) app.showMessage("Added ${plural(count, "track")} to the queue.");
}

class LibraryTrackRow extends StatelessWidget {
  const LibraryTrackRow(this.app, this.track, this.index, this.details, this.playlists, {super.key});

  final MelodyApp app;
  final Track track;
  final int index;
  final TrackDetails details;
  final List<Playlist> playlists;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return Surface(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: 12,
      hover: true,
      child: Row(
        spacing: 10,
        children: [
          SizedBox(
            width: 30,
            child: Text("${index + 1}", textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Artwork(app, details.thumbnail, size: 44),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 3,
              children: [
                Text(
                  track.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                Text(details.credit, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
              ],
            ),
          ),
          SizedBox(width: 50, child: Text(formatDuration(details.duration), style: muted)),
          IconButton(
            onPressed: () => app.toggleFavorite(track.id),
            tooltip: details.favorite ? "Remove favorite" : "Favorite",
            icon: Icon(
              details.favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: details.favorite ? Colors.pink.shade400 : null,
            ),
          ),
          IconButton(
            onPressed: () => app.playback.playTrack(track.id),
            tooltip: "Play",
            icon: const Icon(Icons.play_arrow_rounded),
          ),
          ActionMenu(() => libraryTrackActions(context, app, track, details, playlists)),
        ],
      ),
    );
  }
}
