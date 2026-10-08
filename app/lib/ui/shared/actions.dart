import "dart:async";

import "package:flutter/material.dart";

import "../app_state.dart";
import "../../application/models.dart";
import "../../core/library/models.dart";
import "dialogs.dart";
import "format.dart";

/// One entry in a track, result, or collection action menu. Desktop shows
/// these in popup menus; mobile shows them in a bottom sheet.
class MenuAction {
  const MenuAction(
    this.label,
    this.icon,
    this.onSelected, {
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final FutureOr<void> Function() onSelected;
  final bool enabled;
}

List<MenuAction> libraryTrackActions(
  BuildContext context,
  MelodyApp app,
  Track track,
  TrackDetails details,
  List<Playlist> playlists,
) => [
  MenuAction(
    "Play next",
    Icons.queue_play_next_rounded,
    () => app.playback.addNext(track.id),
  ),
  MenuAction(
    "Add to queue",
    Icons.add_to_queue_rounded,
    () => app.playback.addLast(track.id),
  ),
  for (final playlist in playlists)
    MenuAction(
      "Add to ${playlist.name}",
      Icons.playlist_add_rounded,
      () => app.run(() => app.playlists.addTrack(playlist.id, track.id)),
    ),
  MenuAction(
    details.favorite ? "Remove favorite" : "Favorite",
    Icons.favorite_border_rounded,
    () => app.toggleFavorite(track.id),
  ),
  MenuAction(
    "Edit title",
    Icons.edit_rounded,
    () => showRenameTrackDialog(context, app, track),
  ),
  MenuAction(
    "View details",
    Icons.info_outline_rounded,
    () => showTrackDetailsDialog(context, app, track),
  ),
  MenuAction(
    "Delete track and file…",
    Icons.delete_forever_rounded,
    () => showDeleteTrackDialog(context, app, track),
  ),
];

List<MenuAction> searchResultActions(
  BuildContext context,
  MelodyApp app,
  SearchResult result,
  List<Playlist> playlists, {
  bool includePrimaryActions = false,
}) {
  final search = app.search;
  final local = search.availableTrack(result);
  final favorite = search.isFavorite(result);
  return [
    if (includePrimaryActions && local == null)
      MenuAction(
        result.isPlaylist ? "Download playlist" : "Download",
        Icons.download_rounded,
        () => search.downloadResult(result),
      ),
    MenuAction(
      "Play next",
      Icons.queue_play_next_rounded,
      () => search.actOnResult(result, TrackAction.playNext),
    ),
    MenuAction(
      "Add to queue",
      Icons.add_to_queue_rounded,
      () => search.actOnResult(result, TrackAction.queue),
    ),
    MenuAction(
      favorite ? "Remove favorite" : "Favorite",
      Icons.favorite_border_rounded,
      () => search.actOnResult(result, TrackAction.favorite),
    ),
    for (final playlist in playlists)
      MenuAction(
        "Add to ${playlist.name}",
        Icons.playlist_add_rounded,
        () =>
            search.actOnResult(result, TrackAction.addToPlaylist, playlist.id),
      ),
    MenuAction(
      "View details",
      Icons.info_outline_rounded,
      () => showSearchResultDetails(context, result),
    ),
  ];
}

List<MenuAction> playlistTrackActions(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
  Track track,
  int index,
  List<Playlist> otherPlaylists,
  TrackDetails details,
) {
  final playlists = app.playlists;
  return [
    MenuAction(
      "Move up",
      Icons.arrow_upward_rounded,
      () => app.run(() => playlists.reorder(playlist.id, index, index - 1)),
      enabled: index > 0,
    ),
    MenuAction(
      "Move down",
      Icons.arrow_downward_rounded,
      () => app.run(() => playlists.reorder(playlist.id, index, index + 2)),
      enabled: index < playlist.trackIds.length - 1,
    ),
    MenuAction(
      "Play next",
      Icons.queue_play_next_rounded,
      () => app.playback.addNext(track.id),
    ),
    MenuAction(
      "Add to queue",
      Icons.add_to_queue_rounded,
      () => app.playback.addLast(track.id),
    ),
    MenuAction(
      details.favorite ? "Remove favorite" : "Favorite",
      Icons.favorite_border_rounded,
      () => app.toggleFavorite(track.id),
    ),
    MenuAction(
      "View details",
      Icons.info_outline_rounded,
      () => showTrackDetailsDialog(context, app, track),
    ),
    for (final target in otherPlaylists) ...[
      MenuAction(
        "Copy to ${target.name}",
        Icons.content_copy_rounded,
        () => app.run(
          () => playlists.transferTrack(
            playlist.id,
            target.id,
            track.id,
            move: false,
          ),
        ),
      ),
      MenuAction(
        "Move to ${target.name}",
        Icons.drive_file_move_outline,
        () => app.run(
          () => playlists.transferTrack(
            playlist.id,
            target.id,
            track.id,
            move: true,
          ),
        ),
      ),
    ],
    MenuAction(
      "Remove from playlist",
      Icons.remove_circle_outline_rounded,
      () => app.run(() => playlists.removeTrack(playlist.id, track.id)),
    ),
  ];
}

List<MenuAction> queueRowActions(MelodyApp app, int index) => [
  MenuAction(
    "Move up",
    Icons.arrow_upward_rounded,
    () => app.playback.reorderQueue(index, index - 1),
    enabled: index > 0,
  ),
  MenuAction(
    "Move down",
    Icons.arrow_downward_rounded,
    () => app.playback.reorderQueue(index, index + 2),
    enabled: index < app.playback.queue.items.length - 1,
  ),
  MenuAction(
    "Remove from queue",
    Icons.remove_circle_outline_rounded,
    () => app.playback.removeQueueItem(index),
  ),
];

List<MenuAction> playlistActions(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
) => [
  MenuAction(
    "Export playlist",
    Icons.ios_share_rounded,
    () => exportPlaylist(app, playlist),
  ),
  MenuAction(
    "Rename playlist",
    Icons.edit_rounded,
    () => showRenamePlaylistDialog(context, app, playlist),
  ),
  MenuAction(
    "Delete playlist",
    Icons.delete_outline_rounded,
    () => showDeletePlaylistDialog(context, app, playlist),
  ),
];

/// Retries every failed download and reports how many started.
Future<void> retryFailed(MelodyApp app) => app.run(() async {
  final started = await app.services.downloads.retryFailed();
  if (started > 0) app.showMessage("Retrying ${plural(started, "download")}.");
});
