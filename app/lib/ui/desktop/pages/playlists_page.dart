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

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      app.playlists,
      app.libraryRevision,
      app.playbackState,
    ]),
    builder: (context, _) {
      final selected = app.playlists.selectedPlaylistId;
      if (selected != null && app.services.manager.hasPlaylist(selected)) {
        return _PlaylistDetail(app, app.services.manager.getPlaylist(selected));
      }
      app.playlists.selectedPlaylistId = null;
      final playlists = app.services.manager.listPlaylists();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 8,
            children: [
              const Expanded(
                child: Heading(
                  "Playlists",
                  "A collection for every mood and moment.",
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => showImportPlaylistDialog(context, app),
                icon: const Icon(Icons.playlist_add_rounded, size: 20),
                label: const Text("Import playlist"),
              ),
              PrimaryButton(
                "New playlist",
                Icons.add_rounded,
                () => showCreatePlaylistDialog(context, app),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: playlists.isEmpty
                ? const EmptyState(
                    Icons.queue_music_rounded,
                    "Create a playlist or import one from $youtubeMusicName to get started.",
                  )
                : SingleChildScrollView(
                    child: Transform.translate(
                      offset: const Offset(-10, 0),
                      child: CoverGrid(
                        children: [
                          for (final playlist in playlists)
                            (width) =>
                                PlaylistCard(app, playlist, width: width),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      );
    },
  );
}

class PlaylistCard extends StatelessWidget {
  const PlaylistCard(this.app, this.playlist, {super.key, this.width = 196});

  final MelodyApp app;
  final Playlist playlist;
  final double width;

  @override
  Widget build(BuildContext context) {
    final count = playlist.trackIds.length;
    return CoverCard(
      app: app,
      width: width,
      title: playlist.name,
      subtitle: plural(count, "track"),
      artwork: playlistArtwork(app, playlist),
      playlist: true,
      onTap: () => app.playlists.openPlaylist(playlist.id),
      onPlay: count > 0 ? () => app.playlists.play(playlist) : null,
      playTooltip: "Play ${playlist.name}",
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
    final details = app.services.library.detailsMany(
      visible.map((track) => track.id),
    );
    final scheme = context.colors;
    final hue = seedHue(playlist.name);
    final wash = HSLColor.fromAHSL(1, hue, 0.45, 0.5).toColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A soft wash tinted like the playlist's cover placeholder.
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 24, 24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.panel),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [wash.withValues(alpha: 0.22), wash.withValues(alpha: 0)],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              IconButton(
                onPressed: app.playlists.closePlaylist,
                tooltip: "All playlists",
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 28,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Radii.large),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.14),
                            blurRadius: 28,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Artwork(
                        app,
                        playlistArtwork(app, playlist),
                        size: 176,
                        playlist: true,
                        seed: playlist.name,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 8,
                        children: [
                          Text("PLAYLIST", style: context.text.labelSmall),
                          Text(
                            playlist.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.displaySmall,
                          ),
                          Text(
                            plural(tracks.length, "track"),
                            style: context.text.bodyMedium!.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          spacing: 6,
          children: [
            PlayCircle(
              onPressed: tracks.isEmpty
                  ? null
                  : () => app.playlists.play(playlist),
              tooltip: "Play",
              size: 54,
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: tracks.isEmpty
                  ? null
                  : () => app.playlists.shuffle(playlist),
              tooltip: "Shuffle playlist",
              icon: const Icon(Icons.shuffle_rounded),
            ),
            IconButton(
              onPressed: tracks.isEmpty
                  ? null
                  : () => queueCollection(app, tracks),
              tooltip: "Add playlist to queue",
              icon: const Icon(Icons.add_to_queue_rounded),
            ),
            ActionMenu(() => playlistActions(context, app, playlist)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => showBulkAddTracksDialog(context, app, playlist),
              icon: const Icon(Icons.playlist_add_rounded, size: 20),
              label: const Text("Add tracks"),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (tracks.isNotEmpty) ...[
          const TrackListHeader(leadingWidth: 28, trailingWidth: 48),
          const SizedBox(height: 8),
        ],
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
                    final info = details[track.id]!;
                    return TrackListRow(
                      key: ValueKey("${playlist.id}:$position:${track.id}"),
                      app: app,
                      number: position + 1,
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Tooltip(
                            message: "Drag to reorder",
                            child: SizedBox(
                              width: 28,
                              height: 40,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 18,
                                color: scheme.outline,
                              ),
                            ),
                          ),
                        ),
                      ),
                      title: track.displayTitle,
                      subtitle: info.credit,
                      artwork: info.thumbnail,
                      duration: formatDuration(info.duration),
                      current: app.playback.currentTrackId == track.id,
                      onPlay: () => app.playback.playTracks([
                        for (final item in tracks) item.id,
                      ], startIndex: position),
                      playTooltip: "Play from here",
                      trailing: [
                        ActionMenu(
                          () => playlistTrackActions(
                            context,
                            app,
                            playlist,
                            track,
                            position,
                            others,
                            info,
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        if (tracks.length > 50)
          PageNavigation(
            total: tracks.length,
            start: start,
            end: end,
            onChange: app.playlists.changePage,
          ),
      ],
    );
  }
}
