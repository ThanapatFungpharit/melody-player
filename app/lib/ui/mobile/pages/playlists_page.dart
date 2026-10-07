import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../core/library/models.dart";
import "../../../core/media.dart";
import "../../controllers/home_controller.dart";
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
      if (selected != null && app.services.manager.hasPlaylist(selected)) {
        return _PlaylistDetail(app, app.services.manager.getPlaylist(selected));
      }
      app.playlists.selectedPlaylistId = null;
      final playlists = app.services.manager.listPlaylists();
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
                  "Import $youtubeMusicName playlist",
                  Icons.playlist_add_rounded,
                  () => showImportPlaylistDialog(context, app),
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
            artwork: playlist.trackIds.isEmpty
                ? ""
                : app.services.library
                      .details(playlist.trackIds.first)
                      .thumbnail,
            playlist: true,
            onTap: () => app.playlists.openPlaylist(playlist.id),
            trailing: TouchIconButton(
              Icons.play_arrow_rounded,
              "Play ${playlist.name}",
              () => app.playlists.play(playlist),
            ),
          ),
        if (playlists.isEmpty)
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
    final tracks = app.services.manager.playlistTracks(playlist.id);
    final (start, end) = app.playlists.visibleRange(tracks.length);
    final visible = tracks.sublist(start, end);
    final others = [
      for (final item in app.services.manager.listPlaylists())
        if (item.id != playlist.id) item,
    ];
    final details = app.services.library.detailsMany(
      visible.map((track) => track.id),
    );
    final ids = [for (final track in tracks) track.id];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) app.playlists.closePlaylist();
      },
      child: scrollPage([
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
            tracks.isEmpty
                ? ""
                : app.services.library.details(tracks.first.id).thumbnail,
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
          "${plural(tracks.length, "track")} · Reorder from a track’s actions",
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
        for (final (offset, track) in visible.indexed)
          TrackRow(
            app: app,
            title: track.displayTitle,
            credit: details[track.id]!.credit,
            artwork: details[track.id]!.thumbnail,
            selected: app.playback.currentTrackId == track.id,
            onTap: () =>
                app.playback.playTracks(ids, startIndex: start + offset),
            trailing: MoreButton(
              track.displayTitle,
              () => playlistTrackActions(
                context,
                app,
                playlist,
                track,
                start + offset,
                others,
                details[track.id]!,
              ),
            ),
          ),
        if (tracks.length > 50)
          PageNavigation(
            total: tracks.length,
            start: start,
            end: end,
            onChange: app.playlists.changePage,
          ),
        if (tracks.isEmpty)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => showBulkAddTracksDialog(context, app, playlist),
            icon: const Icon(Icons.add_rounded),
            label: const Text("Add tracks"),
          ),
      ]),
    );
  }
}
