import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../core/library/models.dart";
import "../../../core/media.dart";
import "../../controllers/home_controller.dart";
import "../../controllers/playlists_controller.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class MobilePlaylists extends StatelessWidget {
  const MobilePlaylists(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => Watch(
    [app.playlists, app.libraryRevision, app.playbackState],
    builder: (context) {
      final selected = app.playlists.selectedPlaylistId;
      if (selected != null && app.playlists.exists(selected)) {
        return _PlaylistDetail(app, app.playlists.playlist(selected));
      }
      app.playlists.selectedPlaylistId = null;
      final playlists = app.playlists.all();
      return scrollPage([
        MobileHeading(
          "Playlists",
          subtitle: "Collections made by you",
          large: true,
          actions: [
            MoreButton(
              "Playlist actions",
              () => [
                MenuAction(
                  "Import playlist",
                  Icons.playlist_add_rounded,
                  () => showActionSheet(
                    context,
                    "Import playlist",
                    importPlaylistActions(context, app),
                  ),
                ),
              ],
            ),
          ],
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => showCreatePlaylistDialog(context, app),
          icon: const Icon(Icons.add_rounded),
          label: const Text("New playlist"),
        ),
        for (final playlist in playlists)
          TrackRow(
            app: app,
            title: playlist.name,
            credit: "${playlist.trackIds.length} tracks",
            artwork: playlistArtwork(app, playlist),
            playlist: true,
            onTap: () => app.playlists.openPlaylist(playlist.id),
            trailing: TouchIconButton(
              Icons.play_arrow_rounded,
              "Play ${playlist.name}",
              () => app.playlists.play(playlist),
            ),
          ),
        // Favorites is always listed, so only the user's own can be missing.
        if (playlists.length == 1)
          const EmptyState(
            Icons.album_rounded,
            "Create a playlist or import one from $youtubeMusicName.",
          ),
      ]);
    },
  );
}

class _PlaylistDetail extends StatelessWidget {
  const _PlaylistDetail(this.app, this.playlist);

  final MelodyApp app;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final favorites = PlaylistsController.isFavorites(playlist.id);
    final tracks = app.playlists.tracks(playlist.id);
    final query = app.playlists.trackQuery;
    final filtering = query.trim().isNotEmpty;
    // Each row's place in the playlist.
    final rows = [
      for (final (position, track) in tracks.indexed)
        if (!filtering || app.services.library.matches(track.id, query))
          position,
    ];
    final ids = [for (final track in tracks) track.id];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) app.playlists.closePlaylist();
      },
      child: reorderablePage(
        // The controller takes the drop slot.
        reorderable: !filtering,
        onReorder: (oldIndex, newIndex) => app.run(
          () => app.playlists.reorder(
            playlist.id,
            oldIndex,
            newIndex > oldIndex ? newIndex + 1 : newIndex,
          ),
        ),
        header: [
          Row(
            children: [
              Transform.translate(
                offset: const Offset(-8, 0),
                child: TouchIconButton(
                  Icons.arrow_back_rounded,
                  "All playlists",
                  app.playlists.closePlaylist,
                ),
              ),
              const Spacer(),
              MoreButton(
                playlist.name,
                () => [
                  if (tracks.isNotEmpty) ...[
                    if (!favorites)
                      MenuAction(
                        "Add tracks",
                        Icons.playlist_add_rounded,
                        () => showBulkAddTracksDialog(context, app, playlist),
                      ),
                    MenuAction(
                      "Add playlist to queue",
                      Icons.add_to_queue_rounded,
                      () => queueCollection(app, tracks),
                    ),
                  ],
                  ...playlistActions(context, app, playlist),
                ],
              ),
            ],
          ),
          Center(
            child: Artwork(
              app,
              playlistArtwork(app, playlist),
              size: 200,
              playlist: true,
              seed: playlist.name,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.headlineMedium!.copyWith(fontSize: 28),
          ),
          Text(
            "${plural(tracks.length, "track")} · Drag a track to reorder",
            style: context.text.bodySmall,
          ),
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: tracks.isEmpty
                      ? null
                      : () => app.playlists.play(playlist),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text("Play"),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: tracks.isEmpty
                    ? null
                    : () => app.playlists.shuffle(playlist),
                icon: const Icon(Icons.shuffle_rounded),
                label: const Text("Shuffle"),
              ),
            ],
          ),
          ImportProgress(app, playlist.id),
          if (tracks.length > findableRows)
            TextFormField(
              key: ValueKey("find:${playlist.id}"),
              initialValue: query,
              onChanged: app.playlists.setTrackQuery,
              decoration: const InputDecoration(
                hintText: "Find in this playlist",
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
        ],
        itemCount: rows.length,
        itemBuilder: (context, row) {
          final position = rows[row];
          final track = tracks[position];
          final info = app.services.library.details(track.id);
          return TrackRow(
            key: ValueKey("${playlist.id}:$position:${track.id}"),
            app: app,
            title: track.displayTitle,
            credit: info.credit,
            artwork: app.services.library.artwork(track.id),
            selected: app.playback.currentTrackId == track.id,
            favorite: info.favorite,
            onTap: () => app.playback.playTracks(ids, startIndex: position),
            leading: filtering ? null : reorderHandle(context, row),
            trailing: MoreButton(
              track.displayTitle,
              () => playlistTrackActions(
                context,
                app,
                playlist,
                track,
                position,
                info,
              ),
            ),
          );
        },
        footer: [
          if (tracks.isEmpty && favorites)
            const EmptyState(
              Icons.favorite_border_rounded,
              "Favorite a track and it appears here.",
            )
          else if (tracks.isEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () => showBulkAddTracksDialog(context, app, playlist),
              icon: const Icon(Icons.add_rounded),
              label: const Text("Add tracks"),
            ),
        ],
      ),
    );
  }
}
