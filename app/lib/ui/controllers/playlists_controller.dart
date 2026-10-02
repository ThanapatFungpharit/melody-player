import "dart:async";
import "dart:collection";

import "package:flutter/foundation.dart";

import "../../app/app_state.dart";
import "../../application/models.dart";
import "../../application/providers.dart";
import "../../core/downloader/downloader.dart";
import "../../core/library/models.dart";
import "../../core/media.dart";
import "library_controller.dart";

class _ImportSession {
  _ImportSession(this.playlistId, this.name, this.pending, this.order);

  final String playlistId;
  final String name;
  final Queue<(String, SearchResult)> pending;
  final List<String> order;
  final Map<String, String> resolved = {};

  /// Source key → (task, whether this session created the task).
  final Map<String, (String, bool)> activeDownloads = {};
  int reused = 0;
  int downloaded = 0;
  int failed = 0;

  int get total => order.length;
}

/// Playlist view state, management workflows, and remote playlist import.
class PlaylistsController extends ChangeNotifier {
  PlaylistsController(this.app);

  final MelodyApp app;
  String? selectedPlaylistId;
  int pageOffset = 0;
  _ImportSession? _session;
  bool importLoading = false;
  int _generation = 0;
  Completer<void> _wakeup = Completer();

  bool get importing => importLoading || _session != null;

  void openPlaylist(String playlistId) {
    selectedPlaylistId = playlistId;
    pageOffset = 0;
    app.navigate(3);
    notifyListeners();
  }

  void closePlaylist() {
    selectedPlaylistId = null;
    pageOffset = 0;
    notifyListeners();
  }

  (int, int) visibleRange(int total) {
    final start = pageOffset.clamp(0, total <= 0 ? 0 : (total - 1) ~/ libraryPageSize * libraryPageSize);
    pageOffset = start;
    return (start, (start + libraryPageSize).clamp(0, total));
  }

  void changePage(int direction) {
    pageOffset = (pageOffset + direction * libraryPageSize).clamp(0, 1 << 30);
    notifyListeners();
  }

  void play(Playlist playlist) => app.playback.playTracks(playlist.trackIds);

  void shuffle(Playlist playlist) => app.playback.playTracksShuffled(playlist.trackIds);

  String create(String name) {
    final id = app.services.manager.createPlaylist(name);
    selectedPlaylistId = id;
    app.touchLibrary();
    notifyListeners();
    return id;
  }

  void rename(String playlistId, String name) {
    app.services.manager.renamePlaylist(playlistId, name);
    app.touchLibrary();
  }

  void delete(String playlistId) {
    app.services.manager.deletePlaylist(playlistId);
    abandonImport(playlistId);
    selectedPlaylistId = null;
    app.touchLibrary();
    notifyListeners();
  }

  void addTrack(String playlistId, String trackId) {
    app.services.manager.addToPlaylist(playlistId, trackId);
    app.touchLibrary();
    app.showMessage("Added to playlist.");
  }

  int addTracks(String playlistId, List<String> trackIds) {
    final added = app.services.manager.addTracksToPlaylist(playlistId, trackIds);
    app.touchLibrary();
    return added;
  }

  void removeTrack(String playlistId, String trackId) {
    app.services.manager.removeFromPlaylist(playlistId, trackId);
    app.touchLibrary();
  }

  /// Moves a row; [newIndex] is the drop slot, as reorderable lists report.
  void reorder(String playlistId, int oldIndex, int newIndex) {
    final ordered = List.of(app.services.manager.getPlaylist(playlistId).trackIds);
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    final item = ordered.removeAt(oldIndex);
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    ordered.insert(target.clamp(0, ordered.length), item);
    try {
      app.services.manager.reorderPlaylist(playlistId, ordered);
    } finally {
      // Rebuild from the durable order, also after a failure.
      app.touchLibrary();
    }
  }

  void transferTrack(String source, String target, String trackId, {required bool move}) {
    if (move) {
      app.services.manager.moveTrackBetweenPlaylists(source, target, trackId);
    } else {
      app.services.manager.copyPlaylistTrack(source, target, trackId);
    }
    app.touchLibrary();
  }

  // -- remote import ---------------------------------------------------------

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
      final remote = await app.services.providers.loadPlaylist(url);
      if (generation == _generation) await _import(remote, generation);
    } catch (error) {
      app.reportFailure(error);
    } finally {
      importLoading = false;
      notifyListeners();
    }
  }

  Future<void> _import(RemotePlaylist remote, int generation) async {
    if (_session != null) {
      app.showError("A playlist import is already in progress.");
      return;
    }
    final name = remote.title.trim().isNotEmpty
        ? remote.title.trim()
        : "Imported $youtubeMusicName playlist";
    final unique = <String, SearchResult>{
      for (final item in remote.tracks)
        if (item.url.isNotEmpty) sourceKey(item.url): item,
    };
    final playlistId = app.services.manager.createPlaylist(name);
    app.touchLibrary();
    if (generation != _generation) return;
    final session = _ImportSession(
      playlistId,
      name,
      Queue.of([for (final entry in unique.entries) (entry.key, entry.value)]),
      unique.keys.toList(),
    );
    _session = session;
    selectedPlaylistId = playlistId;
    notifyListeners();
    app.showMessage("Importing ${session.total} tracks into “$name”…");
    try {
      while ((session.pending.isNotEmpty || session.activeDownloads.isNotEmpty) &&
          identical(_session, session)) {
        var changed = false;
        var queueFull = false;
        // Requests are non-blocking; submit until the downloader reports
        // backpressure, then refill after terminal notifications wake us.
        while (session.pending.isNotEmpty && identical(_session, session)) {
          final (key, result) = session.pending.first;
          final String? task;
          final bool owned;
          try {
            (task, owned) = await app.services.downloads.requestWithOwnership(result);
          } on WorkerQueueFull {
            queueFull = true;
            break;
          } catch (_) {
            session.failed++;
            session.pending.removeFirst();
            continue;
          }
          if (!identical(_session, session)) {
            if (task != null && owned) app.services.downloads.cancel(task);
            return;
          }
          if (task == null) {
            final existing = await app.services.downloads.availableTrack(result.url);
            if (existing != null) {
              session.resolved[key] = existing.id;
              session.reused++;
              changed = true;
            } else {
              // It resolved locally but vanished before the follow-up read.
              session.failed++;
            }
            session.pending.removeFirst();
            continue;
          }
          session.activeDownloads[key] = (task, owned);
          session.pending.removeFirst();
        }
        if (!identical(_session, session)) return;
        // Reset before reading records so a completion is either visible in
        // this snapshot or wakes the next wait.
        _wakeup = Completer();
        var terminalSeen = false;
        for (final entry in session.activeDownloads.entries.toList()) {
          final record = app.services.downloads.get(entry.value.$1);
          if (record == null || !const {"completed", "failed", "cancelled"}.contains(record.status)) {
            continue;
          }
          terminalSeen = true;
          session.activeDownloads.remove(entry.key);
          if (record.status == "completed" && record.trackIds.isNotEmpty) {
            session.resolved[entry.key] = record.trackIds.first;
            session.downloaded++;
            changed = true;
          } else {
            session.failed++;
          }
        }
        if (changed) {
          app.services.manager.mergeTracksIntoPlaylist(playlistId, [
            for (final key in session.order)
              ?session.resolved[key],
          ]);
          app.touchLibrary();
        }
        if (session.pending.isEmpty && session.activeDownloads.isEmpty) break;
        if (terminalSeen) continue;
        if (session.activeDownloads.isNotEmpty) {
          await _wakeup.future;
        } else if (queueFull) {
          // The downloader may be busy with unrelated work.
          await _wakeup.future.timeout(const Duration(milliseconds: 200), onTimeout: () {});
        }
      }
      _finish(session);
    } finally {
      if (identical(_session, session)) _session = null;
      notifyListeners();
    }
  }

  /// Wakes the importer so it can inspect finished downloads.
  void notifyDownloadChanged() {
    if (!_wakeup.isCompleted) _wakeup.complete();
  }

  /// Stops an import (optionally only the one filling [playlistId]) and
  /// cancels the downloads it created.
  bool abandonImport([String? playlistId]) {
    final session = _session;
    if (playlistId != null && (session == null || session.playlistId != playlistId)) {
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
        "reused ${session.reused}, downloaded ${session.downloaded}.";
    if (session.failed > 0) {
      app.showError("$summary ${session.failed} could not be downloaded.");
    } else {
      app.showMessage(summary);
    }
  }
}
