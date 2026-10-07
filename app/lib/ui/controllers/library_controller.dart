import "dart:async";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../app_state.dart";
import "../shared/format.dart";
import "../../core/errors.dart" show failureMessage;
import "../../core/library/models.dart";

const libraryPageSize = 50;

/// Library view state and local-track workflows.
class LibraryController extends ChangeNotifier {
  LibraryController(this.app);

  static const queryDebounce = Duration(milliseconds: 150);

  final MelodyApp app;
  String mode = "tracks";
  String queryText = "";
  String sortKey = "recent";
  int pageOffset = 0;
  Timer? _debounce;

  /// The visible page and whether another page follows.
  (List<Track>, bool) page() {
    var fetched = app.services.library.tracks(
      query: queryText,
      sort: sortKey,
      offset: pageOffset,
      limit: libraryPageSize + 1,
    );
    while (fetched.isEmpty && pageOffset > 0) {
      pageOffset = (pageOffset - libraryPageSize).clamp(0, pageOffset);
      fetched = app.services.library.tracks(
        query: queryText,
        sort: sortKey,
        offset: pageOffset,
        limit: libraryPageSize + 1,
      );
    }
    return (
      fetched.take(libraryPageSize).toList(),
      fetched.length > libraryPageSize,
    );
  }

  List<Playlist> matchingPlaylists() {
    final term = queryText.toLowerCase();
    return [
      for (final playlist in app.services.manager.listPlaylists())
        if (term.isEmpty || playlist.name.toLowerCase().contains(term))
          playlist,
    ];
  }

  List<Track> visibleTracks() =>
      app.services.library.tracks(query: queryText, sort: sortKey);

  void changePage(int direction) {
    pageOffset = (pageOffset + direction * libraryPageSize).clamp(0, 1 << 30);
    notifyListeners();
  }

  void setMode(String value) {
    mode = value;
    pageOffset = 0;
    notifyListeners();
  }

  void setSort(String value) {
    sortKey = value;
    pageOffset = 0;
    notifyListeners();
  }

  void setQuery(String value) {
    queryText = value;
    pageOffset = 0;
    _debounce?.cancel();
    _debounce = Timer(queryDebounce, notifyListeners);
  }

  void playVisible() =>
      app.playback.playTracks([for (final track in visibleTracks()) track.id]);

  void shuffleVisible() => app.playback.playTracksShuffled([
    for (final track in visibleTracks()) track.id,
  ]);

  /// Imports local files one by one and reports failures together.
  Future<void> importLocalFiles(List<String> paths) async {
    var imported = 0;
    final importedIds = <String>[];
    final failures = <String>[];
    for (final path in paths) {
      try {
        importedIds.add(await app.services.library.importLocalFile(path));
        imported++;
      } catch (error) {
        failures.add("${p.basename(path)}: ${failureMessage(error)}");
      }
    }
    app.exportImportedTracks(importedIds);
    app.touchLibrary();
    if (failures.isNotEmpty) {
      app.showError(
        "Imported ${plural(imported, "file")}. ${failures.take(3).join(" • ")}",
      );
    } else {
      app.showMessage(
        "Added ${plural(imported, "local file")} to the library.",
      );
    }
  }

  void renameTrack(String trackId, String title) {
    app.services.library.renameTrack(trackId, title);
    app.touchLibrary();
    app.playbackState.emit();
    if (app.playback.currentTrackId == trackId) app.syncSystemMedia();
  }

  /// Detaches the file from the player, then deletes the record and, when
  /// Melody downloaded it, the file.
  Future<void> deleteTrack(String trackId) async {
    app.playback.removeTrack(trackId);
    await app.services.library.deleteTrack(trackId);
    app.touchLibrary();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
