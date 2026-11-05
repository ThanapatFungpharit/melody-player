import "dart:async";

import "package:flutter/material.dart";

import "../app_state.dart";
import "../../application/library_service.dart" show LibraryService;
import "../../application/models.dart";
import "../../application/sleep_timer.dart";
import "../../core/library/models.dart";
import "../controllers/playlists_controller.dart";
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

/// Where a playlist can be imported from: an M3U file or a remote link.
List<MenuAction> importPlaylistActions(BuildContext context, MelodyApp app) => [
  MenuAction(
    "From file (M3U)",
    Icons.file_open_rounded,
    () => importPlaylistFile(context, app),
  ),
  MenuAction(
    "From links to songs",
    Icons.add_link_rounded,
    () => showPlaylistFromLinksDialog(context, app),
  ),
  MenuAction(
    "From ${app.settings.musicSource.label} link",
    Icons.link_rounded,
    () => showImportPlaylistDialog(context, app),
  ),
];

const addToPlaylistLabel = "Add to playlist…";

/// Copies a track's link, for a track that has one.
MenuAction? _copyLink(MelodyApp app, Track track) =>
    LibraryService.linksOf([track]).isEmpty
    ? null
    : MenuAction(
        "Copy link",
        Icons.link_rounded,
        () => copyLinks(app, LibraryService.linksOf([track])),
      );

MenuAction _addToPlaylist(
  BuildContext context,
  MelodyApp app,
  Track track, {
  String? except,
}) => MenuAction(
  addToPlaylistLabel,
  Icons.playlist_add_rounded,
  () => showPlaylistPicker(
    context,
    app,
    title: "Add to playlist",
    except: except,
    onChosen: (playlistId) =>
        app.run(() => app.playlists.addTrack(playlistId, track.id)),
  ),
);

List<MenuAction> libraryTrackActions(
  BuildContext context,
  MelodyApp app,
  Track track,
  TrackDetails details,
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
  _addToPlaylist(context, app, track),
  MenuAction(
    details.favorite ? "Remove favorite" : "Favorite",
    details.favorite
        ? Icons.heart_broken_outlined
        : Icons.favorite_border_rounded,
    () => app.toggleFavorite(track.id),
  ),
  MenuAction(
    "Edit details",
    Icons.edit_rounded,
    () => showEditTrackDialog(context, app, track),
  ),
  MenuAction(
    "View details",
    Icons.info_outline_rounded,
    () => showTrackDetailsDialog(context, app, track),
  ),
  ?_copyLink(app, track),
  MenuAction(
    "Delete track and file…",
    Icons.delete_forever_rounded,
    () => showDeleteTrackDialog(context, app, track),
  ),
];

/// What the playing track's menu offers.
List<MenuAction> currentTrackActions(BuildContext context, MelodyApp app) {
  final trackId = app.playback.currentTrackId;
  if (trackId == null || !app.services.manager.hasTrack(trackId)) {
    return const [];
  }
  return libraryTrackActions(
    context,
    app,
    app.services.manager.getTrack(trackId),
    app.services.library.details(trackId),
  );
}

List<MenuAction> searchResultActions(
  BuildContext context,
  MelodyApp app,
  SearchResult result, {
  bool includePrimaryActions = false,
}) {
  final search = app.search;
  final local = search.availableTrack(result);
  final favorite = search.isFavorite(result);
  return [
    if (includePrimaryActions && local == null)
      MenuAction(
        "Download",
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
      favorite ? Icons.heart_broken_outlined : Icons.favorite_border_rounded,
      () => search.actOnResult(result, TrackAction.favorite),
    ),
    MenuAction(
      addToPlaylistLabel,
      Icons.playlist_add_rounded,
      () => showPlaylistPicker(
        context,
        app,
        title: "Add to playlist",
        onChosen: (playlistId) =>
            search.actOnResult(result, TrackAction.addToPlaylist, playlistId),
      ),
    ),
    MenuAction(
      "View details",
      Icons.info_outline_rounded,
      () => showSearchResultDetails(context, result),
    ),
    MenuAction(
      "Copy link",
      Icons.link_rounded,
      () => copyLinks(app, [result.url]),
    ),
  ];
}

List<MenuAction> playlistTrackActions(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
  Track track,
  int index,
  TrackDetails details,
) {
  final playlists = app.playlists;
  final moves = [
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
  ];
  // Favorites follows the favorite marks: a track leaves it by being
  // unfavorited.
  if (PlaylistsController.isFavorites(playlist.id)) {
    return [
      ...moves,
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
      _addToPlaylist(context, app, track),
      MenuAction(
        "View details",
        Icons.info_outline_rounded,
        () => showTrackDetailsDialog(context, app, track),
      ),
      ?_copyLink(app, track),
      MenuAction(
        "Remove from Favorites",
        Icons.heart_broken_outlined,
        () => app.toggleFavorite(track.id),
      ),
    ];
  }
  return [
    ...moves,
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
      details.favorite
          ? Icons.heart_broken_outlined
          : Icons.favorite_border_rounded,
      () => app.toggleFavorite(track.id),
    ),
    MenuAction(
      "View details",
      Icons.info_outline_rounded,
      () => showTrackDetailsDialog(context, app, track),
    ),
    ?_copyLink(app, track),
    _addToPlaylist(context, app, track, except: playlist.id),
    MenuAction(
      "Move to playlist…",
      Icons.drive_file_move_outline,
      () => showPlaylistPicker(
        context,
        app,
        title: "Move to playlist",
        except: playlist.id,
        onChosen: (target) =>
            app.run(() => playlists.moveTrack(playlist.id, target, track.id)),
      ),
    ),
    MenuAction(
      "Remove from playlist",
      Icons.remove_circle_outline_rounded,
      () => app.run(() => playlists.removeTrack(playlist.id, track.id)),
    ),
  ];
}

/// Converts a reorderable list's move between visible [rows] (queue indexes,
/// ascending) into the queue drop slot that `reorderQueue` takes. [newRow] is the index after removal, as onReorderItem reports.
int queueDropSlot(List<int> rows, int oldRow, int newRow) {
  final slot = newRow > oldRow ? newRow + 1 : newRow;
  return slot < rows.length ? rows[slot] : rows.last + 1;
}

/// What the sleep timer is doing, for its menu title and tooltip.
String sleepTimerStatus(SleepTimer timer) {
  if (timer.endOfTrack) return "Sleep timer: pauses after this track";
  final remaining = timer.remaining;
  if (remaining == null) return "Sleep timer";
  // Round up, so the last minute reads "1 min", not "0 min".
  final minutes = (remaining.inSeconds + 59) ~/ 60;
  return "Sleep timer: $minutes min left";
}

List<MenuAction> sleepTimerActions(MelodyApp app) {
  final playback = app.playback;
  final hasMedia = playback.hasMedia;
  return [
    for (final minutes in sleepTimerChoices)
      MenuAction(
        "$minutes minutes",
        Icons.timer_outlined,
        () => app.startSleepTimer(Duration(minutes: minutes)),
      ),
    MenuAction(
      "End of this track",
      Icons.music_note_outlined,
      app.sleepAtEndOfTrack,
      enabled: hasMedia && !app.sleepTimer.endOfTrack,
    ),
    if (app.sleepTimer.active)
      MenuAction("Turn off", Icons.timer_off_outlined, app.cancelSleepTimer),
  ];
}

/// What can be done with the tracks selected in the library.
List<MenuAction> selectedTracksActions(BuildContext context, MelodyApp app) {
  final library = app.library;
  final any = library.selectedIds.isNotEmpty;
  return [
    MenuAction(
      "Add to queue",
      Icons.add_to_queue_rounded,
      library.queueSelected,
      enabled: any,
    ),
    MenuAction(
      addToPlaylistLabel,
      Icons.playlist_add_rounded,
      () => showPlaylistPicker(
        context,
        app,
        title: "Add to playlist",
        onChosen: (playlistId) =>
            app.run(() => library.addSelectedToPlaylist(playlistId)),
      ),
      enabled: any,
    ),
    MenuAction(
      "Delete tracks and files…",
      Icons.delete_forever_rounded,
      () => showDeleteSelectedTracksDialog(context, app),
      enabled: any,
    ),
  ];
}

List<MenuAction> queueRowActions(
  BuildContext context,
  MelodyApp app,
  int index,
  Track track,
) => [
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
    () => app.removeFromQueue(index),
  ),
  _addToPlaylist(context, app, track),
  MenuAction(
    "View details",
    Icons.info_outline_rounded,
    () => showTrackDetailsDialog(context, app, track),
  ),
];

List<MenuAction> playlistActions(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
) => [
  if (playlist.source.isNotEmpty)
    MenuAction(
      "Update from ${app.settings.musicSource.label}",
      Icons.sync_rounded,
      () => app.playlists.updateFromSource(playlist),
      enabled: !app.playlists.importing,
    ),
  MenuAction(
    "Copy links",
    Icons.link_rounded,
    () => copyPlaylistLinks(app, playlist),
    enabled: playlist.trackIds.isNotEmpty,
  ),
  MenuAction(
    "Export playlist",
    Icons.ios_share_rounded,
    () => exportPlaylist(app, playlist),
  ),
  // Favorites belongs to the app; only its tracks' favorite marks change it.
  if (!PlaylistsController.isFavorites(playlist.id)) ...[
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
  ],
];

/// Retries every failed download and reports how many started.
Future<void> retryFailed(MelodyApp app) => app.run(() async {
  final started = await app.services.downloads.retryFailed();
  if (started > 0) app.showMessage("Retrying ${plural(started, "download")}.");
});
