import "dart:async";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../app_state.dart";
import "../shared/format.dart";
import "../../core/errors.dart" show failureMessage;

/// The orders the library can show, by [LibraryService.trackIds] key.
const librarySorts = {
  "recent": "Recently added",
  "oldest": "Oldest added",
  "title": "Title",
  "artist": "Artist",
  "longest": "Longest",
  "played": "Most played",
};

/// Library view state and local-track workflows.
class LibraryController extends ChangeNotifier {
  LibraryController(this.app);

  static const queryDebounce = Duration(milliseconds: 150);

  final MelodyApp app;
  String queryText = "";
  String sortKey = "recent";
  Timer? _debounce;

  /// Whether rows pick tracks for [selected] instead of playing them.
  bool selecting = false;
  final Set<String> selected = {};

  (String, String, int)? _visibleFor;
  List<String> _visible = const [];

  /// The tracks the view shows, in order. Every rebuild asks, so the answer is
  /// kept until the query, the sort, or the library changes.
  List<String> visibleIds() {
    final key = (queryText, sortKey, app.libraryRevision.value);
    if (key != _visibleFor) {
      _visibleFor = key;
      _visible = app.services.library.trackIds(query: queryText, sort: sortKey);
    }
    return _visible;
  }

  void setSort(String value) {
    sortKey = value;
    notifyListeners();
  }

  void setQuery(String value) {
    queryText = value;
    _debounce?.cancel();
    _debounce = Timer(queryDebounce, notifyListeners);
  }

  void playVisible() => app.playback.playTracks(visibleIds());

  /// Plays the visible tracks from the one at [index].
  void playFrom(int index) =>
      app.playback.playTracks(visibleIds(), startIndex: index);

  void shuffleVisible() => app.playback.playTracksShuffled(visibleIds());

  // -- selection -------------------------------------------------------------

  void startSelecting([String? first]) {
    selecting = true;
    selected
      ..clear()
      ..addAll([?first]);
    notifyListeners();
  }

  void stopSelecting() {
    selecting = false;
    selected.clear();
    notifyListeners();
  }

  void toggleSelected(String trackId) {
    if (!selected.remove(trackId)) selected.add(trackId);
    notifyListeners();
  }

  /// Selects everything the view shows, or nothing when it all is already.
  void toggleSelectAll() {
    final visible = visibleIds();
    if (selected.containsAll(visible)) {
      selected.removeAll(visible);
    } else {
      selected.addAll(visible);
    }
    notifyListeners();
  }

  /// The selected tracks in the order they show.
  List<String> get selectedIds => [
    for (final id in visibleIds())
      if (selected.contains(id)) id,
  ];

  void queueSelected() {
    final count = app.playback.addLastMany(selectedIds);
    if (count > 0) {
      app.showMessage("Added ${plural(count, "track")} to the queue.");
    }
    stopSelecting();
  }

  void addSelectedToPlaylist(String playlistId) {
    final count = app.playlists.addTracks(playlistId, selectedIds);
    app.showMessage(
      count > 0
          ? "Added ${plural(count, "track")} to the playlist."
          : "Already in this playlist.",
    );
    stopSelecting();
  }

  Future<void> deleteSelected() async {
    final ids = selectedIds;
    final failures = <String>[];
    for (final id in ids) {
      try {
        await deleteTrack(id);
      } on Object catch (error) {
        failures.add(failureMessage(error));
      }
    }
    stopSelecting();
    if (failures.isNotEmpty) {
      app.showError(failures.take(3).join(" • "));
    } else {
      app.showMessage("Deleted ${plural(ids.length, "track")}.");
    }
  }

  // -- tracks ----------------------------------------------------------------

  /// Imports local files one by one and reports failures together.
  Future<void> importLocalFiles(List<String> paths) async {
    var imported = 0;
    final failures = <String>[];
    for (final path in paths) {
      try {
        await app.services.library.importLocalFile(path);
        imported++;
      } catch (error) {
        failures.add("${p.basename(path)}: ${failureMessage(error)}");
      }
    }
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

  /// Changes what a track is called in the library; its file stays as it is.
  void editTrack(
    String trackId, {
    required String title,
    required String artist,
  }) {
    app.services.library
      ..renameTrack(trackId, title)
      ..setArtist(trackId, artist);
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
