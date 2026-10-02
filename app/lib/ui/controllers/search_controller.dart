import "dart:async";

import "package:flutter/foundation.dart";

import "../../app/app_state.dart";
import "../../application/downloads.dart";
import "../../application/models.dart";
import "../../core/library/models.dart";
import "../../core/media.dart";

/// Search state and the provider-search workflow.
class MusicSearchController extends ChangeNotifier {
  MusicSearchController(this.app);

  static const pageSize = 24;

  final MelodyApp app;
  String draft = "";
  List<SearchResult> results = [];
  bool busy = false;
  int pageNumber = 1;
  bool hasNext = false;
  String queryText = "";
  String playlistTitle = "";
  String viewMode = "list";
  String? status;
  String? error;

  /// Result URL → intact library track, captured when the page loaded so
  /// rendering never hashes audio files.
  Map<String, Track?> localTracks = {};

  /// Incremented to ask the search field to take focus (Ctrl+L).
  final ValueNotifier<int> focusRequest = ValueNotifier(0);
  int _request = 0;

  Track? availableTrack(SearchResult result) => localTracks[result.url];

  /// Starts a search, or a batch download when several URLs were pasted.
  Future<void> startSearch() async {
    final query = draft.trim();
    if (query.isEmpty) {
      app.showError("Enter a search term or $youtubeMusicName URL.");
      return;
    }
    final urls = extractDownloadUrls(query);
    queryText = query;
    if (urls.length > 1) {
      await startUrlBatch(urls);
      return;
    }
    await _search(query, page: 1, remember: true);
  }

  Future<void> loadPage(int page) async {
    if (busy || page < 1 || queryText.isEmpty) return;
    if (page > pageNumber && !hasNext) return;
    await _search(queryText, page: page, remember: false);
  }

  Future<void> _search(String query, {required int page, required bool remember}) async {
    final request = ++_request;
    busy = true;
    error = null;
    status = "Searching page $page…";
    notifyListeners();
    try {
      final fetched = await app.services.providers.search(
        youtubeProviderId,
        query,
        limit: pageSize + 1,
        offset: (page - 1) * pageSize,
      );
      final local = <String, Track?>{
        for (final item in fetched)
          if (!item.isPlaylist) item.url: await app.services.downloads.availableTrack(item.url),
      };
      if (remember) app.services.store.addRecent("search_history", query, limit: 20);
      if (request != _request) return;
      results = fetched.take(pageSize).toList();
      localTracks = local;
      pageNumber = page;
      hasNext = fetched.length > pageSize;
      playlistTitle = results
          .map((item) => item.playlistTitle)
          .firstWhere((title) => title.isNotEmpty, orElse: () => "");
      status = _statusText();
    } catch (failure) {
      if (request != _request) return;
      results = [];
      hasNext = false;
      error = switch (failure) {
        ArgumentError(:final message) => "$message",
        _ => "$failure",
      };
      status = error;
    } finally {
      if (request == _request) {
        busy = false;
        notifyListeners();
      }
    }
  }

  String _statusText() {
    if (results.isEmpty) return "No matching music was found.";
    final word = results.length == 1 ? "result" : "results";
    final playlist = playlistTitle.isNotEmpty ? "$playlistTitle • " : "";
    return "${playlist}Page $pageNumber • ${results.length} $word";
  }

  void setViewMode(String mode) {
    viewMode = mode;
    notifyListeners();
  }

  /// Schedules several URLs and reports what was started.
  Future<void> startUrlBatch(List<String> urls) async {
    try {
      final batch = await app.services.downloads.startUrls(urls);
      app.showMessage(batchDownloadMessage(batch));
      app.openPanel(AppPanel.downloads);
    } on ArgumentError catch (failure) {
      app.showError("${failure.message}");
    } catch (failure) {
      app.reportFailure(failure);
    }
  }

  static String batchDownloadMessage(DownloadBatch batch) {
    final scheduled = batch.tasks.length;
    if (scheduled == batch.size) {
      return "Started a batch of ${batch.size} songs. Each song will continue independently.";
    }
    if (scheduled > 0) {
      return "Queued $scheduled of ${batch.size} songs. Existing files and active "
          "downloads were reused.";
    }
    return "All requested songs are already in the library or downloading.";
  }

  /// Downloads [result], or applies [after] to the existing track.
  Future<void> downloadResult(
    SearchResult result, {
    String after = "",
    String? playlistId,
    int? requestGeneration,
  }) async {
    bool relevant() =>
        after != "play" ||
        (requestGeneration != null && app.playback.isCurrentRequest(requestGeneration));
    try {
      final wasActive = app.services.downloads.isSourceActive(result.url);
      final task = await app.services.downloads.request(result);
      if (task == null) {
        final existing = await app.services.downloads.availableTrack(result.url);
        if (existing == null) return;
        localTracks[result.url] = existing;
        notifyListeners();
        if (after.isNotEmpty && relevant()) {
          app.applyTrackAction([existing.id], after, playlistId);
        } else if (after.isEmpty) {
          app.showMessage("This track is already in your library.");
        }
        return;
      }
      if (after.isNotEmpty && relevant()) {
        app.pendingDownloadActions[task] = PendingTrackAction(after, playlistId);
        if (requestGeneration != null) app.downloadPlayRequests[task] = requestGeneration;
      }
      app.showMessage(wasActive ? "Download already in progress." : "Downloading…");
    } catch (failure) {
      final message = switch (failure) {
        ArgumentError(:final message) => "$message",
        _ => "$failure",
      };
      if (after == "play" && requestGeneration != null) {
        if (app.playback.isCurrentRequest(requestGeneration)) {
          app.playback.onBackendError(message);
        }
      } else {
        app.showError(message);
      }
    }
  }

  Future<void> actOnResult(SearchResult result, String action, [String? playlistId]) async {
    var existing = availableTrack(result);
    if (existing == null && action == "favorite" && !result.isPlaylist) {
      // Favoriting is metadata-only, so it works for a known record whose
      // file awaits repair.
      existing = app.services.manager.findTrackBySource(result.url);
    }
    if (existing != null) {
      if (action == "favorite") {
        await app.toggleFavorite(existing.id);
      } else {
        app.applyTrackAction([existing.id], action, playlistId);
      }
      return;
    }
    await downloadResult(result, after: action, playlistId: playlistId);
  }

  /// Plays a result: tracks are downloaded first; playlists stream a preview.
  Future<void> playResult(SearchResult result) async {
    final playback = app.playback;
    if (playback.loading && playback.externalTitle == result.title) return;
    final generation = playback.beginPendingTrack(result.title);
    if (!result.isPlaylist) {
      await downloadResult(result, after: "play", requestGeneration: generation);
      return;
    }
    try {
      final stream = await app.services.providers.get(result.providerId).resolveStream(result.url);
      if (!playback.isCurrentRequest(generation)) return;
      final autoplay = playback.playing;
      playback.playStream(
        stream,
        title: result.title,
        uploader: result.uploader,
        thumbnail: result.thumbnail,
      );
      if (!autoplay) playback.toggle();
    } catch (failure) {
      if (playback.isCurrentRequest(generation)) playback.onBackendError("$failure");
    }
  }

  /// Whether a known library record for [result] is a favorite.
  bool isFavorite(SearchResult result) {
    final known = availableTrack(result) ??
        (result.isPlaylist ? null : app.services.manager.findTrackBySource(result.url));
    return known != null && app.services.library.details(known.id).favorite;
  }
}
