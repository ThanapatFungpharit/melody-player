import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../../core/library/models.dart";
import "../../../core/media.dart";
import "../../controllers/home_controller.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([app.playlists, app.libraryRevision]),
    builder: (context, _) {
      final selected = app.playlists.selectedPlaylistId;
      if (selected != null && app.services.manager.hasPlaylist(selected)) {
        return _PlaylistDetail(app, app.services.manager.getPlaylist(selected));
      }
      app.playlists.selectedPlaylistId = null;
      final playlists = app.services.manager.listPlaylists();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 20,
        children: [
          ResponsiveGrid(
            spacing: 10,
            center: true,
            children: [
              const GridCell(Heading("Playlists", "A collection for every mood and moment."), md: 7),
              GridCell(
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => showImportPlaylistDialog(context, app),
                        icon: const Icon(Icons.playlist_add_rounded),
                        label: const Text("Import playlist"),
                      ),
                      PrimaryButton(
                        "New playlist",
                        Icons.add_rounded,
                        () => showCreatePlaylistDialog(context, app),
                      ),
                    ],
                  ),
                ),
                md: 5,
              ),
            ],
          ),
          Expanded(
            child: playlists.isEmpty
                ? const Center(
                    child: EmptyState(
                      Icons.queue_music_rounded,
                      "Create a playlist or import one from $youtubeMusicName to get started.",
                    ),
                  )
                : SingleChildScrollView(
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 18,
                      children: [for (final playlist in playlists) PlaylistCard(app, playlist)],
                    ),
                  ),
          ),
        ],
      );
    },
  );
}

class PlaylistCard extends StatelessWidget {
  const PlaylistCard(this.app, this.playlist, {super.key});

  final MelodyApp app;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final count = playlist.trackIds.length;
    final artwork = count > 0 ? app.services.library.details(playlist.trackIds.first).thumbnail : "";
    return Surface(
      width: 204,
      padding: const EdgeInsets.all(12),
      radius: 20,
      hover: true,
      onTap: () => app.playlists.openPlaylist(playlist.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 7,
        children: [
          Stack(
            children: [
              Artwork(app, artwork, size: 180, playlist: true),
              Positioned(
                right: 8,
                bottom: 8,
                child: IconButton.filled(
                  onPressed: count > 0 ? () => app.playlists.play(playlist) : null,
                  tooltip: "Play ${playlist.name}",
                  icon: const Icon(Icons.play_arrow_rounded, size: 24),
                ),
              ),
            ],
          ),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          Text(
            plural(count, "track"),
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PlaylistDetail extends StatelessWidget {
  const _PlaylistDetail(this.app, this.playlist);

  final MelodyApp app;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final tracks = app.services.manager.playlistTracks(playlist.id);
    final (start, end) = app.playlists.visibleRange(tracks.length);
    final visible = tracks.sublist(start, end);
    final others = [
      for (final item in app.services.manager.listPlaylists())
        if (item.id != playlist.id) item,
    ];
    final details = app.services.library.detailsMany(visible.map((track) => track.id));
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        Row(
          spacing: 8,
          children: [
            IconButton(
              onPressed: app.playlists.closePlaylist,
              tooltip: "All playlists",
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  Text(plural(tracks.length, "track"), style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => showBulkAddTracksDialog(context, app, playlist),
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text("Add to playlist"),
            ),
            PrimaryButton("Play", Icons.play_arrow_rounded, tracks.isEmpty ? null : () => app.playlists.play(playlist)),
            IconButton(
              onPressed: tracks.isEmpty ? null : () => app.playlists.shuffle(playlist),
              tooltip: "Shuffle playlist",
              icon: const Icon(Icons.shuffle_rounded),
            ),
            IconButton(
              onPressed: tracks.isEmpty ? null : () => queueCollection(app, tracks),
              tooltip: "Add playlist to queue",
              icon: const Icon(Icons.add_to_queue_rounded),
            ),
            ActionMenu(() => playlistActions(context, app, playlist, tracks)),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: tracks.isEmpty
              ? const EmptyState(
                  Icons.playlist_add_rounded,
                  "This playlist is empty. Add tracks from Search or Library.",
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: visible.length,
                  // onReorderItem reports the index after removal; the
                  // controller takes the drop slot, as the queue does.
                  onReorderItem: (oldIndex, newIndex) => app.run(
                    () => app.playlists.reorder(
                      playlist.id,
                      start + oldIndex,
                      start + (newIndex > oldIndex ? newIndex + 1 : newIndex),
                    ),
                  ),
                  itemBuilder: (context, index) {
                    final track = visible[index];
                    final position = start + index;
                    return Padding(
                      key: ValueKey("${playlist.id}:$position:${track.id}"),
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Surface(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          spacing: 8,
                          children: [
                            ReorderableDragStartListener(
                              index: index,
                              child: const MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Tooltip(
                                  message: "Drag to reorder",
                                  child: SizedBox(width: 28, height: 44, child: Icon(Icons.drag_indicator_rounded, size: 20)),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 28,
                              child: Text(
                                "${position + 1}",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ),
                            Artwork(app, details[track.id]!.thumbnail, size: 48),
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
                                  Text(
                                    details[track.id]!.credit,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              formatDuration(details[track.id]!.duration),
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                            IconButton(
                              onPressed: () => app.playback.playTracks(
                                [for (final item in tracks) item.id],
                                startIndex: position,
                              ),
                              tooltip: "Play from here",
                              icon: const Icon(Icons.play_arrow_rounded),
                            ),
                            ActionMenu(
                              () => playlistTrackActions(
                                context,
                                app,
                                playlist,
                                track,
                                position,
                                others,
                                details[track.id]!,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (tracks.length > 50)
          PageNavigation(total: tracks.length, start: start, end: end, onChange: app.playlists.changePage),
      ],
    );
  }
}
