import "dart:async";
import "dart:collection";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../app_state.dart";
import "../../application/models.dart";
import "../../application/catalog.dart";
import "../../application/downloads.dart";
import "../../application/library_service.dart" show favoritesPlaylistId;
import "../../core/library/models.dart";
import "../../core/media.dart";
import "../shared/format.dart" show plural;

class _ImportSession {
  _ImportSession(
    this.playlistId,
    this.name,
    this.source,
    this.order,
    this.tracks, {
    Map<String, String> resolved = const {},
    this.resolveMetadata = false,
    this.skipped = 0,
  }) : resolved = {...resolved},
       pending = Queue.of(
         tracks.keys.where((key) => !resolved.containsKey(key)),
       ),
       reused = resolved.length;

  final String playlistId;
  final String name;

  /// The link the playlist can be updated from; empty for others.
  final String source;

  /// Every key, in playlist order.
  final List<String> order;

  /// Source key → result to request.
  final Map<String, SearchResult> tracks;

  /// Whether results carry placeholder titles that yt-dlp replaces.
  final bool resolveMetadata;

  /// Entries of the source that matched nothing and cannot be downloaded.
  final int skipped;

  /// Source keys not yet requested.
  final Queue<String> pending;

  /// Key → library track id.
  final Map<String, String> resolved;

  /// Source key → (task, whether this session created the task).
  final Map<String, (String, bool)> activeDownloads = {};
  int reused;
  int downloaded = 0;
  int failed = 0;

  int get total => order.length;
}

/// Playlist view state, management workflows, and remote playlist import.
class PlaylistsController extends ChangeNotifier {
  PlaylistsController(this.app);

  final MelodyApp app;
  String? selectedPlaylistId;

  /// What the open playlist's rows are filtered by.
  String trackQuery = "";
  _ImportSession? _session;
  bool importLoading = false;
  int _generation = 0;
  Completer<void> _wakeup = Completer();

  bool get importing => importLoading || _session != null;

  /// How far the running import into [playlistId] has come, if there is one.
  ({int done, int total})? importProgress(String playlistId) {
    final session = _session;
    if (session == null || session.playlistId != playlistId) return null;
    return (
      done: session.reused + session.downloaded + session.failed,
      total: session.total,
    );
  }

  void openPlaylist(String playlistId) {
    selectedPlaylistId = playlistId;
    trackQuery = "";
    app.navigate(3);
    notifyListeners();
  }

  void closePlaylist() {
    selectedPlaylistId = null;
    trackQuery = "";
    notifyListeners();
  }

  void setTrackQuery(String value) {
    trackQuery = value;
    notifyListeners();
  }

  /// Whether [playlistId] is the app-managed Favorites playlist, whose
  /// tracks change only by favoriting them; its order can still be dragged.
  static bool isFavorites(String playlistId) =>
      playlistId == favoritesPlaylistId;

  bool exists(String playlistId) =>
      isFavorites(playlistId) || app.services.manager.hasPlaylist(playlistId);

  Playlist playlist(String playlistId) => isFavorites(playlistId)
      ? app.services.library.favoritesPlaylist()
      : app.services.manager.getPlaylist(playlistId);

  List<Track> tracks(String playlistId) => isFavorites(playlistId)
      ? app.services.library.favoriteTrackList()
      : app.services.manager.playlistTracks(playlistId);

  /// Favorites first, then the user's playlists.
  List<Playlist> all() => [
    app.services.library.favoritesPlaylist(),
    ...app.services.manager.listPlaylists(),
  ];

  static void _requireEditable(String playlistId) {
    if (isFavorites(playlistId)) {
      throw StateError(
        "Favorites is managed by Melody. Favorite or unfavorite a track to "
        "change it.",
      );
    }
  }

  void play(Playlist playlist) => app.playback.playTracks(playlist.trackIds);

  void shuffle(Playlist playlist) =>
      app.playback.playTracksShuffled(playlist.trackIds);

  /// Creates a playlist; with [open], the Playlists page then shows it.
  String create(String name, {bool open = true}) {
    final id = app.services.manager.createPlaylist(name);
    if (open) selectedPlaylistId = id;
    app.touchLibrary();
    notifyListeners();
    return id;
  }

  void rename(String playlistId, String name) {
    _requireEditable(playlistId);
    app.services.manager.renamePlaylist(playlistId, name);
    app.touchLibrary();
  }

  void delete(String playlistId) {
    _requireEditable(playlistId);
    app.services.manager.deletePlaylist(playlistId);
    abandonImport(playlistId);
    selectedPlaylistId = null;
    app.touchLibrary();
    notifyListeners();
  }

  void addTrack(String playlistId, String trackId) {
    _requireEditable(playlistId);
    final added = app.services.manager.addToPlaylist(playlistId, trackId);
    app.touchLibrary();
    app.showMessage(added ? "Added to playlist." : "Already in this playlist.");
  }

  int addTracks(String playlistId, List<String> trackIds) {
    _requireEditable(playlistId);
    final added = app.services.manager.addTracksToPlaylist(
      playlistId,
      trackIds,
    );
    app.touchLibrary();
    return added;
  }

  void removeTrack(String playlistId, String trackId) {
    _requireEditable(playlistId);
    app.services.manager.removeFromPlaylist(playlistId, trackId);
    app.touchLibrary();
  }

  /// Moves a row; [newIndex] is the drop slot, as reorderable lists report.
  void reorder(String playlistId, int oldIndex, int newIndex) {
    final ordered = List.of(playlist(playlistId).trackIds);
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    final item = ordered.removeAt(oldIndex);
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    ordered.insert(target.clamp(0, ordered.length), item);
    try {
      if (isFavorites(playlistId)) {
        app.services.library.reorderFavorites(ordered);
      } else {
        app.services.manager.reorderPlaylist(playlistId, ordered);
      }
    } finally {
      // Rebuild from the durable order, also after a failure.
      app.touchLibrary();
    }
  }

  void moveTrack(String source, String target, String trackId) {
    _requireEditable(source);
    _requireEditable(target);
    app.services.manager.moveTrackBetweenPlaylists(source, target, trackId);
    app.touchLibrary();
  }

  // -- file import -----------------------------------------------------------

  /// Creates a playlist from the tracks an M3U or M3U8 file lists, named
  /// after the file unless it names itself. Linked tracks missing from the
  /// library are downloaded, and files missing from it imported.
  Future<void> importFromFile(
    List<int> bytes,
    String fileName, {
    String? directory,
  }) async {
    final library = app.services.library;
    final match = await library.importListedFiles(
      await library.matchPlaylistM3u(
        bytes,
        fallbackName: p.basenameWithoutExtension(fileName),
        baseDirectory: directory,
      ),
    );
    if (match.entries.any((entry) => entry.url != null)) {
      final order = <String>[];
      final tracks = <String, SearchResult>{};
      final resolved = <String, String>{};
      for (final entry in match.entries) {
        final String key;
        if (entry.trackId case final trackId?) {
          key = "track:$trackId";
          resolved[key] = trackId;
        } else if (entry.url case final url?) {
          key = sourceKey(url);
          tracks.putIfAbsent(key, () => _linkedSong(url, entry.title));
        } else {
          continue;
        }
        if (!order.contains(key)) order.add(key);
      }
      await _run(
        match.name,
        order,
        tracks,
        _generation,
        resolved: resolved,
        resolveMetadata: true,
        skipped: match.skipped,
      );
      return;
    }
    final result = library.createPlaylistFrom(match);
    selectedPlaylistId = result.playlistId;
    trackQuery = "";
    app.touchLibrary();
    app.navigate(3);
    notifyListeners();
    final skipped = result.skipped;
    app.showMessage(
      "Imported ${plural(result.added, "track")} into “${result.name}”."
      "${skipped > 0 ? " Skipped ${plural(skipped, "track")} it could not find." : ""}",
    );
  }

  /// A song known only by its link, until yt-dlp reports its details.
  static SearchResult _linkedSong(String url, String title) => SearchResult(
    id: "",
    title: title,
    uploader: "",
    duration: 0,
    thumbnail: "",
    url: url,
    source: youtubeMusicName,
  );

  // -- remote import ---------------------------------------------------------

  /// Creates a playlist from links to songs pasted as [text], reusing library
  /// tracks and downloading the rest. It starts in the background once the
  /// links are checked, which is what [FormatException]s are about.
  void importFromLinks(String name, String text) {
    final title = name.trim();
    if (title.isEmpty) {
      throw const FormatException("Playlist name cannot be empty");
    }
    if (importing) {
      throw const FormatException("A playlist import is already in progress.");
    }
    final links = extractDownloadUrls(text);
    final songs = [
      for (final url in links)
        if (MediaIdentity.fromUrl(url) != null) url,
    ];
    if (songs.isEmpty) {
      throw const FormatException("Paste at least one link to a song.");
    }
    final tracks = <String, SearchResult>{};
    for (final (index, url) in songs.indexed) {
      tracks.putIfAbsent(
        sourceKey(url),
        () => _linkedSong(url, "Song ${index + 1} of ${songs.length}"),
      );
    }
    app.navigate(3);
    unawaited(
      app.run(
        () => _run(
          title,
          tracks.keys.toList(),
          tracks,
          _generation,
          resolveMetadata: true,
          skipped: links.length - songs.length,
        ),
      ),
    );
  }

  /// Loads a remote playlist and imports it, reusing library tracks and
  /// downloading only missing ones.
  Future<void> importFromUrl(String url) async {
    if (importing) {
      app.showError("A playlist import is already in progress.");
      return;
    }
    final generation = _generation;
    importLoading = true;
    notifyListeners();
    try {
      final remote = await app.services.catalog.loadPlaylist(url);
      if (generation == _generation) {
        await _import(remote, youtubePlaylistUrl(url) ?? "", generation);
      }
    } catch (error) {
      app.reportFailure(error);
    } finally {
      importLoading = false;
      notifyListeners();
    }
  }

  /// Fills the playlist imported from [source], or a new one the first time.
  Future<void> _import(RemotePlaylist remote, String source, int generation) {
    final existing = source.isEmpty
        ? null
        : app.services.manager.findPlaylistBySource(source);
    final name =
        existing?.name ??
        (remote.title.trim().isNotEmpty
            ? remote.title.trim()
            : "Imported $youtubeMusicName playlist");
    final unique = <String, SearchResult>{
      for (final item in remote.tracks)
        if (item.url.isNotEmpty) sourceKey(item.url): item,
    };
    return _run(
      name,
      unique.keys.toList(),
      unique,
      generation,
      into: existing?.id,
      source: source,
    );
  }

  /// Fetches a playlist's link again: songs added there join it, and what
  /// failed or was interrupted last time gets another try. Tracks added here
  /// stay, after those of the link.
  Future<void> updateFromSource(Playlist playlist) =>
      importFromUrl(playlist.source);

  /// Fills the playlist [into], or a new one, with [order]: the [resolved]
  /// library tracks, and the [tracks] reused from the library or downloaded.
  Future<void> _run(
    String name,
    List<String> order,
    Map<String, SearchResult> tracks,
    int generation, {
    String? into,
    String source = "",
    Map<String, String> resolved = const {},
    bool resolveMetadata = false,
    int skipped = 0,
  }) async {
    if (_session != null) {
      app.showError("A playlist import is already in progress.");
      return;
    }
    final playlistId =
        into ?? app.services.manager.createPlaylist(name, source: source);
    if (resolved.isNotEmpty) {
      app.services.manager.mergeTracksIntoPlaylist(playlistId, [
        for (final key in order) ?resolved[key],
      ]);
    }
    app.touchLibrary();
    if (generation != _generation) return;
    final session = _ImportSession(
      playlistId,
      name,
      source,
      order,
      tracks,
      resolved: resolved,
      resolveMetadata: resolveMetadata,
      skipped: skipped,
    );
    _session = session;
    selectedPlaylistId = playlistId;
    notifyListeners();
    app.showMessage(
      into == null
          ? "Importing ${session.total} tracks into “$name”…"
          : "Updating “$name”…",
    );
    try {
      while ((session.pending.isNotEmpty ||
              session.activeDownloads.isNotEmpty) &&
          identical(_session, session)) {
        var changed = false;
        // Requests are non-blocking. Only a window of a long playlist's songs
        // waits in the downloader (and its history) at a time; terminal
        // notifications wake this loop to refill it.
        final window = app.settings.concurrentDownloads * 2;
        while (session.pending.isNotEmpty &&
            session.activeDownloads.length < window &&
            identical(_session, session)) {
          final key = session.pending.first;
          final DownloadRequest request;
          try {
            request = await app.services.downloads.request(
              session.tracks[key]!,
              resolveMetadata: session.resolveMetadata,
            );
          } catch (_) {
            session.failed++;
            session.pending.removeFirst();
            continue;
          }
          final task = request.task;
          if (!identical(_session, session)) {
            if (task != null && request.started) {
              app.services.downloads.cancel(task);
            }
            return;
          }
          if (task == null) {
            session.resolved[key] = request.track!.id;
            session.reused++;
            changed = true;
            session.pending.removeFirst();
            continue;
          }
          session.activeDownloads[key] = (task, request.started);
          session.pending.removeFirst();
        }
        if (!identical(_session, session)) return;
        // Reset before reading records so a completion is either visible in
        // this snapshot or wakes the next wait.
        _wakeup = Completer();
        var terminalSeen = false;
        for (final MapEntry(:key, value: (task, _))
            in session.activeDownloads.entries.toList()) {
          final record = app.services.downloads.get(task);
          if (record != null && !record.status.isFinished) continue;
          terminalSeen = true;
          session.activeDownloads.remove(key);
          // Active records are never dropped, so a missing one finished and
          // left the history (Clear finished) before this loop saw it; the
          // library still knows whether its track arrived.
          final trackId = record == null
              ? app.services.manager
                    .findTrackBySource(session.tracks[key]!.url)
                    ?.id
              : record.status == DownloadStatus.completed
              ? record.trackIds.firstOrNull
              : null;
          if (trackId != null) {
            session.resolved[key] = trackId;
            session.downloaded++;
            changed = true;
          } else {
            session.failed++;
          }
        }
        if (changed) {
          app.services.manager.mergeTracksIntoPlaylist(playlistId, [
            for (final key in session.order) ?session.resolved[key],
          ]);
          app.touchLibrary();
        }
        if (changed || terminalSeen) notifyListeners();
        if (session.pending.isEmpty && session.activeDownloads.isEmpty) break;
        if (terminalSeen) continue;
        if (session.activeDownloads.isNotEmpty) await _wakeup.future;
      }
      _finish(session);
    } finally {
      if (identical(_session, session)) _session = null;
      notifyListeners();
    }
  }

  /// Stops the running import of [playlistId], keeping what it has so far.
  void cancelImport(String playlistId) {
    final session = _session;
    if (!abandonImport(playlistId)) return;
    notifyListeners();
    app.showMessage(
      session != null && session.source.isNotEmpty
          ? "Import stopped. Update the playlist to carry on."
          : "Import stopped.",
    );
  }

  /// Whether the running import is waiting for [task]; its summary reports
  /// the download.
  bool ownsDownload(String task) =>
      _session?.activeDownloads.values.any((entry) => entry.$1 == task) ??
      false;

  /// Wakes the importer so it can inspect finished downloads.
  void notifyDownloadChanged() {
    if (!_wakeup.isCompleted) _wakeup.complete();
  }

  /// Stops an import (optionally only the one filling [playlistId]) and
  /// cancels the downloads it created.
  bool abandonImport([String? playlistId]) {
    final session = _session;
    if (playlistId != null &&
        (session == null || session.playlistId != playlistId)) {
      return false;
    }
    _generation++;
    _session = null;
    notifyDownloadChanged();
    if (session != null) {
      for (final (task, owned) in session.activeDownloads.values) {
        if (owned) app.services.downloads.cancel(task);
      }
    }
    return session != null;
  }

  void _finish(_ImportSession session) {
    if (!identical(_session, session)) return;
    _session = null;
    _generation++;
    notifyDownloadChanged();
    final imported = session.total - session.failed;
    final summary =
        "Imported $imported of ${session.total} tracks into “${session.name}”: "
        "reused ${session.reused}, downloaded ${session.downloaded}."
        "${session.skipped > 0 ? " Skipped ${plural(session.skipped, "track")} it could not find." : ""}";
    if (session.failed > 0) {
      app.showError(
        "$summary ${session.failed} could not be downloaded."
        "${session.source.isNotEmpty ? " Update the playlist to try again." : ""}",
      );
    } else {
      app.showMessage(summary);
    }
  }
}
