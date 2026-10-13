import "dart:async";

import "package:flutter/foundation.dart";
import "package:melody_audio/melody_audio.dart"
    show AudioEngineSnapshot, AudioQueueItem;
import "package:path/path.dart" as p;

import "../audio/audio_backend.dart";
import "../core/library/manager.dart";
import "library_service.dart";
import "models.dart";
import "queue.dart";
import "store.dart";

/// Coalesced playback writes: session snapshots, volume, and play counts are
/// merged and committed once per event-loop turn.
class PlaybackPersistence {
  PlaybackPersistence(this.store, this.onError);

  final ApplicationStore store;
  final void Function(String message) onError;
  final Map<String, Object?> _pending = {};
  final Map<String, int> _plays = {};
  bool _scheduled = false;
  bool _closed = false;

  void save({Map<String, Object?>? playback, Map<String, Object?>? volume}) {
    if (_closed) return;
    if (playback != null) _pending["playback"] = playback;
    if (volume != null) _pending["volume"] = volume;
    _schedule();
  }

  void recordPlay(String trackId) {
    if (_closed) return;
    // Reinserting moves the key to the newest position while keeping the
    // exact coalesced count; the store reverses this order for recents.
    final count = _plays.remove(trackId) ?? 0;
    _plays[trackId] = count + 1;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(flush);
  }

  /// Writes everything pending now.
  void flush() {
    _scheduled = false;
    if (_pending.isEmpty && _plays.isEmpty) return;
    final changes = Map.of(_pending);
    final plays = Map.of(_plays);
    _pending.clear();
    _plays.clear();
    try {
      store.savePlaybackUpdates(changes, plays);
    } catch (error) {
      debugPrint("Playback state write failed: $error");
      // No retry storm: the next transport change saves a fresh snapshot.
      onError("Playback continues, but its session could not be saved.");
    }
  }

  void close() {
    flush();
    _closed = true;
  }
}

/// What a [PlaybackController.changes] event invalidates, so widgets rebuild
/// only for what they show.
enum PlaybackChange {
  /// Transport state: playing, paused, stopped, or an error.
  state,

  /// The current track or stream changed.
  track,
  queue,

  /// Position or duration.
  progress,
  volume,

  /// The decoder finished preparing.
  loading,
}

/// Coordinates persistent queue semantics with the native audio engine.
class PlaybackController {
  PlaybackController(
    this.manager,
    this.library,
    this.store,
    this.backend, {
    this.persistence,
    Set<String>? availableTrackIds,
    String Function(String source)? artworkUri,
    this.onError,
  }) : _artworkUri = artworkUri ?? ((source) => source) {
    final settings = store.settings;
    final restored = settings.resumeSession
        ? store.get("playback", const {})
        : const {};
    final persisted = restored is Map
        ? restored.cast<String, Object?>()
        : <String, Object?>{};
    queue = PlaybackQueue.fromJson(persisted);
    final originalItems = List.of(queue.items);
    final originalIndex = queue.currentIndex;
    final available = <String>[];
    var before = 0;
    var currentAvailable = false;
    for (final (index, item) in originalItems.indexed) {
      final ok = availableTrackIds?.contains(item) ?? manager.hasTrack(item);
      if (ok) {
        available.add(item);
        if (index < originalIndex) before++;
      }
      if (index == originalIndex) currentAvailable = ok;
    }
    queue.items = available;
    if (queue.items.isEmpty) {
      queue.currentIndex = -1;
    } else {
      queue.currentIndex = currentAvailable
          ? before
          : before.clamp(0, queue.items.length - 1);
    }
    if (currentAvailable) {
      // The saved length shows a restored track's progress before the
      // engine loads it, even when the library does not know the length.
      final duration = persisted["duration_ms"];
      if (duration is num && duration.isFinite) {
        durationMs = duration.toInt().clamp(0, 1 << 52);
      }
      final position = persisted["position_ms"];
      if (position is num && position.isFinite) {
        positionMs = _clampPosition(position.toInt().clamp(0, 1 << 52));
      }
    }
    volume = settings.volume;
    muted = settings.muted;
    previousVolume = settings.previousVolume;
    backend.setVolume(muted ? 0 : volume / 100);
    if (!listEquals(queue.items, originalItems)) _persist();
  }

  final MusicManager manager;
  final LibraryService library;
  final ApplicationStore store;
  final TrackPlayerBackend backend;
  final PlaybackPersistence? persistence;
  final String Function(String source) _artworkUri;
  void Function(String message)? onError;

  final StreamController<PlaybackChange> _changes = StreamController.broadcast(
    sync: true,
  );
  Stream<PlaybackChange> get changes => _changes.stream;

  late PlaybackQueue queue;
  int positionMs = 0;
  int durationMs = 0;
  late int volume;
  late bool muted;
  late int previousVolume;
  String externalTitle = "";
  String externalUploader = "";
  String externalThumbnail = "";
  bool _playing = false;
  bool _sourceLoaded = false;
  int _loadGeneration = 0;
  bool _closed = false;
  bool _playerLoading = false;
  bool _loading = false;
  bool _loadAutoplay = false;
  DateTime _lastPersistedPosition = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastBackendErrorAt;
  String? _pendingPlayRecordId;
  bool _mediaSessionActive = false;

  bool get playing => _playing;
  bool get loading => _loading || _playerLoading;
  String? get currentTrackId => queue.current;
  bool get mediaSessionActive => _mediaSessionActive;

  /// Mirrors a decoder that outlived the previous widget tree.
  void onNativeReattach(AudioEngineSnapshot state) {
    final trackId = state.trackId;
    if (trackId != null && queue.items.contains(trackId)) {
      final row = state.queueIndex;
      queue.select(
        row >= 0 && row < queue.items.length && queue.items[row] == trackId
            ? row
            : queue.items.indexOf(trackId),
      );
      _clearExternal();
    } else {
      final source = state.source ?? "";
      externalTitle = state.title.isNotEmpty
          ? state.title
          : p.basenameWithoutExtension(source);
      externalUploader = state.artist;
      externalThumbnail = _artworkPath(state.artworkUri);
    }
    _sourceLoaded = true;
    _playerLoading = false;
    _loading = false;
    _playing = state.playing;
    _mediaSessionActive = true;
    positionMs = (state.position?.inMilliseconds ?? 0).clamp(0, 1 << 52);
    durationMs = (state.duration?.inMilliseconds ?? 0).clamp(0, 1 << 52);
    _persist();
    _notify(PlaybackChange.track);
  }

  void playTracks(List<String> trackIds, {int startIndex = 0}) =>
      _playTracks(trackIds, startIndex: startIndex, shuffleOnce: false);

  /// Starts a collection in a random order without enabling a mode.
  void playTracksShuffled(List<String> trackIds) =>
      _playTracks(trackIds, startIndex: 0, shuffleOnce: true);

  void _playTracks(
    List<String> trackIds, {
    required int startIndex,
    required bool shuffleOnce,
  }) {
    final selectedIndex = trackIds.isEmpty
        ? -1
        : startIndex.clamp(0, trackIds.length - 1);
    final seen = <String>{};
    final available = <String>[];
    // The selection, or else the first available track after it: an
    // unavailable selection starts with what would have played next.
    int? availableIndex;
    for (final (index, item) in trackIds.indexed) {
      if (index == selectedIndex && seen.contains(item)) {
        availableIndex = available.indexOf(item);
      }
      if (seen.contains(item) || !manager.hasTrack(item)) continue;
      seen.add(item);
      if (index >= selectedIndex) availableIndex ??= available.length;
      available.add(item);
    }
    if (available.isEmpty) {
      _error("There are no available tracks to play.");
      return;
    }
    // Nothing after the selection is available; start with the last before.
    availableIndex ??= available.length - 1;
    queue.replace(
      available,
      startIndex: availableIndex,
      shuffleOnce: shuffleOnce,
    );
    _loadCurrent(autoplay: true);
  }

  /// Plays an ephemeral stream without adding it to the library.
  void playStream(
    String source, {
    required String title,
    String uploader = "",
    String thumbnail = "",
  }) {
    _cancelPendingLoad();
    externalTitle = title;
    externalUploader = uploader;
    externalThumbnail = thumbnail;
    _sourceLoaded = true;
    _playerLoading = true;
    positionMs = 0;
    durationMs = 0;
    _playing = true;
    _mediaSessionActive = true;
    try {
      backend.load(source, autoplay: true);
    } catch (error) {
      onBackendError("$error");
    }
    _notify();
  }

  void playTrack(String trackId) {
    // Ignore a repeated tap only while this library track is already
    // preparing to play. A pending remote selection (`_loading`) leaves the
    // queue's row stale, so tapping that row must still switch to it.
    if (trackId == currentTrackId &&
        _playerLoading &&
        _playing &&
        externalTitle.isEmpty) {
      return;
    }
    final index = queue.items.indexOf(trackId);
    if (index >= 0) {
      queue.select(index);
    } else if (manager.hasTrack(trackId)) {
      queue.replace([trackId]);
    } else {
      // A stale row (deleted meanwhile) must not discard the queue.
      _error("This track is no longer in your library.");
      return;
    }
    _loadCurrent(autoplay: true);
  }

  /// Plays an existing queue row without rebuilding or reshuffling it.
  void playQueueIndex(int index) {
    if (index < 0 || index >= queue.items.length) return;
    queue.select(index);
    _loadCurrent(autoplay: true);
  }

  void toggle() {
    if (currentTrackId == null && externalTitle.isEmpty) {
      final tracks = manager.listTracks();
      if (tracks.isNotEmpty) {
        queue.replace([for (final track in tracks) track.id]);
        _loadCurrent(autoplay: true);
      } else {
        _error("Your library is empty. Download a track first.");
      }
      return;
    }
    if (_loading) {
      // A selection is still resolving or downloading; keep the desired
      // state until its source is available.
      _loadAutoplay = !_playing;
      _playing = _loadAutoplay;
      if (_sourceLoaded) _playing ? backend.resume() : backend.pause();
      if (_playing) _mediaSessionActive = true;
      _persist();
      _notify();
      return;
    }
    if (_playerLoading) {
      _playing = !_playing;
      if (_playing) {
        _mediaSessionActive = true;
        backend.resume();
      } else {
        backend.pause();
      }
      _notify();
      return;
    }
    if (_playing) {
      backend.pause();
      _playing = false;
    } else {
      if (!_sourceLoaded) {
        if (!_loadCurrent(autoplay: true, positionMs: positionMs)) return;
        if (_loading) return;
      } else {
        backend.resume();
      }
      _playing = true;
      _mediaSessionActive = true;
    }
    _persist();
    _notify();
  }

  void next() {
    // A pending remote selection has no queue row to rewind to either.
    final wasExternal = externalTitle.isNotEmpty || _loading;
    final sourceWasLoaded = _sourceLoaded;
    final wasPlaying = _playing;
    // _loadCurrent and _release supersede pending work themselves. At the
    // end of a library queue the current row stays selected, so a load still
    // preparing it must survive: cancelling would keep the previous track's
    // decoder, and the pause and rewind below would reach that track instead.
    if (queue.next() != null) {
      _loadCurrent(autoplay: true);
      return;
    }
    if (wasExternal) {
      // A stream has no queue selection to resume after Next.
      _release();
      _persist();
      _notify(PlaybackChange.track);
      return;
    }
    if (sourceWasLoaded) {
      if (wasPlaying) backend.pause();
      backend.seek(0);
    }
    _playing = false;
    positionMs = 0;
    _persist();
    _notify(PlaybackChange.track);
  }

  void previous() {
    if (externalTitle.isNotEmpty) {
      seek(0);
    } else if (positionMs > 5000) {
      seek(0);
    } else if (queue.previous() != null) {
      _loadCurrent(autoplay: true);
    }
  }

  /// Unloads the music: releases the source and system controls and empties
  /// the queue, so the player shows nothing until the next selection. Pause
  /// keeps everything loaded.
  void stop() {
    _release();
    _unload();
  }

  /// Releases the decoder and system controls while keeping the queue.
  void _release() {
    _cancelPendingLoad(discardSource: true);
    _sourceLoaded = false;
    _playing = false;
    _mediaSessionActive = false;
    positionMs = 0;
    durationMs = 0;
    externalTitle = "";
    externalUploader = "";
    externalThumbnail = "";
  }

  void _unload() {
    queue.clear();
    _persist();
    _notify(PlaybackChange.queue);
    _notify(PlaybackChange.track);
  }

  void seek(int position) {
    positionMs = _clampPosition(position);
    if (_loading) {
      _persist();
      _notify();
      return;
    }
    if (!_sourceLoaded) {
      // A restored queue keeps its resume position until the source loads.
      _persist();
      _notify(PlaybackChange.progress);
      return;
    }
    backend.seek(positionMs);
    _persist();
    _notify(PlaybackChange.progress);
  }

  /// Seeks and starts playback, so a tapped lyric line plays even when the
  /// track is paused, finished, or stopped.
  void playFrom(int position) {
    if (_playing) {
      seek(position);
      return;
    }
    if (currentTrackId == null && externalTitle.isEmpty) return;
    if (_loading || _playerLoading || !_sourceLoaded) {
      // Toggle carries the new position into the pending or reloaded source.
      seek(position);
      toggle();
      return;
    }
    positionMs = _clampPosition(position);
    if (positionMs > 0) {
      // The engine seeks before starting and restarts a completed source.
      backend.play(positionMs);
    } else {
      // play(0) keeps the current position, so rewind explicitly.
      backend.seek(0);
      backend.resume();
    }
    _playing = true;
    _mediaSessionActive = true;
    _persist();
    _notify();
  }

  /// A `file:` artwork URI as a path; a malformed one is dropped rather
  /// than failing the reattach.
  static String _artworkPath(String artwork) {
    if (!artwork.toLowerCase().startsWith("file:")) return artwork;
    try {
      return Uri.parse(artwork).toFilePath();
    } on Object {
      return "";
    }
  }

  int _clampPosition(int position) => position.clamp(
    0,
    durationMs > 0 ? durationMs : (position < 0 ? 0 : position),
  );

  void addNext(String trackId) {
    if (addNextMany([trackId]) == 0) {
      _error("This track is no longer in your library.");
    }
  }

  void addLast(String trackId) {
    if (addLastMany([trackId]) == 0) {
      _error("This track is no longer in your library.");
    }
  }

  /// Inserts several tracks next with one update cycle. Returns how many
  /// were queued: tracks that left the library (a stale row) are skipped.
  int addNextMany(Iterable<String> trackIds) {
    final items = _inLibrary(trackIds);
    queue.addNextAll(items);
    if (items.isNotEmpty) _queueChanged();
    return items.length;
  }

  /// Appends several tracks with one update cycle. Returns how many were
  /// queued: tracks that left the library (a stale row) are skipped.
  int addLastMany(Iterable<String> trackIds) {
    final items = _inLibrary(trackIds);
    for (final id in items) {
      queue.addLast(id);
    }
    if (items.isNotEmpty) _queueChanged();
    return items.length;
  }

  /// An unknown id would make every later queue sync fail, leaving the
  /// engine on a stale queue, so only library tracks are queued.
  List<String> _inLibrary(Iterable<String> trackIds) =>
      trackIds.where(manager.hasTrack).toList();

  void _queueChanged() {
    _syncQueue();
    _persist();
    _notify(PlaybackChange.queue);
  }

  void removeQueueItem(int index) {
    // A row tapped as the list changed underneath it may be gone.
    if (index < 0 || index >= queue.items.length) return;
    _removeQueueRows([index]);
  }

  /// Removes every row of [trackId], reloading at most once, so a track
  /// queued several times leaves the queue in one step.
  void removeTrack(String trackId) => _removeQueueRows([
    for (final (index, item) in queue.items.indexed)
      if (item == trackId) index,
  ]);

  /// Removes ascending [rows].
  void _removeQueueRows(List<int> rows) {
    if (rows.isEmpty) return;
    final wasCurrent = rows.contains(queue.currentIndex);
    for (final index in rows.reversed) {
      queue.removeAt(index);
    }
    if (wasCurrent && externalTitle.isEmpty) {
      if (queue.current != null) {
        _loadCurrent(autoplay: _playing);
      } else {
        // An empty native queue keeps its decoder; release it explicitly.
        _release();
        _persist();
        _notify(PlaybackChange.queue);
        return;
      }
    } else {
      _syncQueue();
    }
    _persist();
    _notify(PlaybackChange.queue);
  }

  /// Applies a drag-and-drop reorder. [newIndex] is the drop slot.
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= queue.items.length) return;
    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    target = target.clamp(0, queue.items.length - 1);
    queue.move(oldIndex, target);
    _queueChanged();
  }

  void clearQueue() {
    queue.clear(keepCurrent: true);
    _queueChanged();
  }

  /// Drops queued library tracks and stops a loaded library source.
  void clearLibraryState() {
    final libraryActive =
        externalTitle.isEmpty && (currentTrackId != null || _sourceLoaded);
    queue.clear();
    if (libraryActive) {
      _release();
    } else {
      _syncQueue();
    }
    _persist();
    _notify(PlaybackChange.queue);
  }

  /// Closes a loaded library file so it can be moved, keeping the queue and
  /// position; the next play loads the track from its new path.
  void releaseLibrarySource() {
    if (externalTitle.isNotEmpty ||
        (currentTrackId == null && !_sourceLoaded)) {
      return;
    }
    final (position, duration) = (positionMs, durationMs);
    _release();
    positionMs = position;
    durationMs = duration;
    _persist();
    _notify(PlaybackChange.track);
  }

  bool shuffleUpcoming() {
    if (!queue.shuffleUpcoming()) return false;
    _queueChanged();
    return true;
  }

  RepeatMode cycleRepeat() {
    final mode = queue.cycleRepeat();
    _queueChanged();
    return mode;
  }

  /// Applies volume immediately; slider previews pass `persist: false`.
  void setVolume(int value, {bool persist = true}) {
    volume = value.clamp(0, 100);
    if (volume > 0) {
      previousVolume = volume;
      muted = false;
    } else {
      muted = true;
    }
    backend.setVolume(muted ? 0 : volume / 100);
    if (persist) _saveVolume();
    _notify(PlaybackChange.volume);
  }

  void toggleMute() {
    if (muted) {
      muted = false;
      volume = previousVolume < 1 ? 1 : previousVolume;
    } else {
      if (volume > 0) previousVolume = volume;
      muted = true;
    }
    backend.setVolume(muted ? 0 : volume / 100);
    _saveVolume();
    _notify(PlaybackChange.volume);
  }

  /// Applies live playback settings without touching the queue or session.
  void applySettings(AppSettings settings) {
    volume = settings.volume;
    previousVolume = settings.previousVolume;
    muted = settings.muted;
    backend.setVolume(muted ? 0 : volume / 100);
    _notify(PlaybackChange.volume);
  }

  // -- decoder callbacks ---------------------------------------------------

  void onPosition(int position) {
    if (_loading || _playerLoading) return;
    final clamped = position < 0 ? 0 : position;
    positionMs = durationMs > 0 && clamped > durationMs ? durationMs : clamped;
    final now = DateTime.now();
    if (now.difference(_lastPersistedPosition) >= const Duration(seconds: 5)) {
      _persist();
      _lastPersistedPosition = now;
    }
    _notify(PlaybackChange.progress);
  }

  void onDuration(int duration) {
    if (_loading || _playerLoading) return;
    durationMs = duration < 0 ? 0 : duration;
    if (durationMs > 0 && positionMs > durationMs) {
      positionMs = durationMs;
      _persist();
    }
    _notify(PlaybackChange.progress);
  }

  void onPlaying(bool playing) {
    if (_loading || !_sourceLoaded) return;
    if (_playerLoading) {
      if (!playing) return;
      // A playing event also confirms preparation finished.
      _playerLoading = false;
    }
    _playing = playing;
    if (playing) _mediaSessionActive = true;
    final trackId = currentTrackId;
    if (playing && trackId != null && trackId == _pendingPlayRecordId) {
      _pendingPlayRecordId = null;
      final persistence = this.persistence;
      if (persistence != null) {
        persistence.recordPlay(trackId);
      } else {
        library.recordPlay(
          trackId,
          playback: queue.toJson(
            positionMs: positionMs,
            durationMs: durationMs,
          ),
        );
      }
    }
    _notify();
  }

  void onCompleted() {
    if (_loading || _playerLoading || !_sourceLoaded) return;
    // The native engine already applied repeat and queue policy; completion
    // arrives only when it found no next item.
    _playing = false;
    positionMs = durationMs;
    _persist();
    _notify();
  }

  /// Mirrors a transition selected by the native queue engine.
  void onTrackChanged(String trackId, int index) {
    if (_closed) return;
    // The row may have moved, or the queue shrunk, since the engine chose
    // it; fall back to the track's first row.
    final selected =
        index >= 0 &&
            index < queue.items.length &&
            queue.items[index] == trackId
        ? index
        : queue.items.indexOf(trackId);
    if (selected < 0) return;
    queue.select(selected);
    externalTitle = "";
    externalUploader = "";
    externalThumbnail = "";
    _sourceLoaded = true;
    _playerLoading = true;
    _loading = false;
    _playing = true;
    _mediaSessionActive = true;
    positionMs = 0;
    durationMs = 0;
    _pendingPlayRecordId = trackId;
    _persist();
    _notify(PlaybackChange.track);
  }

  /// Adopts Stop after the native player handled a system action; it unloads
  /// like the in-app Stop button.
  void onStopped() {
    if (_closed) return;
    // The engine already released its decoders; only supersede pending work.
    _loadGeneration++;
    _loading = false;
    _playerLoading = false;
    _pendingPlayRecordId = null;
    _sourceLoaded = false;
    _playing = false;
    _mediaSessionActive = false;
    positionMs = 0;
    durationMs = 0;
    externalTitle = "";
    externalUploader = "";
    externalThumbnail = "";
    _unload();
  }

  /// Reconciles optimistic state after a decoder failure.
  void onBackendError(String message) {
    // Supersede pending generations first so a late callback cannot
    // resurrect a rejected track.
    _cancelPendingLoad(discardSource: true);
    _playing = false;
    _sourceLoaded = false;
    _loading = false;
    _playerLoading = false;
    _mediaSessionActive = false;
    _pendingPlayRecordId = null;
    if (externalTitle.isNotEmpty) {
      externalTitle = "";
      externalUploader = "";
      externalThumbnail = "";
      positionMs = 0;
      durationMs = 0;
    }
    _persist();
    _notify();
    final now = DateTime.now();
    final last = _lastBackendErrorAt;
    if (last == null || now.difference(last) >= const Duration(seconds: 5)) {
      _lastBackendErrorAt = now;
      _error(message);
    }
  }

  void onLoaded() {
    _playerLoading = false;
    _notify(PlaybackChange.loading);
  }

  // -- internals -----------------------------------------------------------

  bool _loadCurrent({required bool autoplay, int positionMs = 0}) {
    final selected = currentTrackId;
    _pruneUnavailable();
    final trackId = currentTrackId;
    if (trackId == null) {
      if (selected != null) {
        // Every queued track left the library.
        _release();
        _error("This track is no longer in your library.");
        _persist();
        _notify(PlaybackChange.queue);
        _notify(PlaybackChange.track);
      }
      return false;
    }
    // A pruned selection's successor starts from the beginning.
    if (trackId != selected) positionMs = 0;
    _clearExternal();
    if (autoplay) _mediaSessionActive = true;
    try {
      _activateQueue(
        trackId,
        autoplay: autoplay,
        positionMs: positionMs < 0 ? 0 : positionMs,
      );
    } catch (error) {
      // Nothing reached the engine: silence the previous track rather than
      // leave it playing under a stopped player.
      _cancelPendingLoad(discardSource: true);
      _playing = false;
      _sourceLoaded = false;
      _mediaSessionActive = false;
      _error(
        "This track is unavailable: ${error is ArgumentError ? error.message : error}",
      );
      _persist();
      _notify(PlaybackChange.track);
      return false;
    }
    _notify(PlaybackChange.track);
    return true;
  }

  List<AudioQueueItem> _queueItems() {
    final details = library.detailsMany(queue.items);
    return [
      for (final trackId in queue.items)
        AudioQueueItem(
          trackId: trackId,
          // A native path; the decoder validates existence and format.
          source: manager.trackPath(trackId),
          title: manager.getTrack(trackId).displayTitle,
          artist: details[trackId]?.uploader ?? "",
          album: details[trackId]?.sourceName ?? "",
          artworkUri: details[trackId] == null
              ? ""
              : _artworkUri(details[trackId]!.thumbnail),
        ),
    ];
  }

  void _activateQueue(
    String trackId, {
    required bool autoplay,
    required int positionMs,
  }) {
    final items = _queueItems();
    // The selected row, not the first copy: the queue may repeat a track.
    final index = queue.currentIndex;
    _sourceLoaded = true;
    _playerLoading = true;
    this.positionMs = positionMs;
    durationMs = 0;
    _playing = autoplay;
    _pendingPlayRecordId = autoplay ? trackId : null;
    backend.setQueue(
      items,
      index,
      repeat: queue.repeat,
      autoplay: autoplay,
      positionMs: positionMs,
    );
    _persist();
  }

  /// Drops rows whose track left the library, so one stale row cannot keep
  /// the whole queue from reaching the engine.
  void _pruneUnavailable() {
    for (var index = queue.items.length - 1; index >= 0; index--) {
      if (!manager.hasTrack(queue.items[index])) queue.removeAt(index);
    }
  }

  /// Sends every queue mutation to the authoritative native player.
  void _syncQueue() {
    if (externalTitle.isNotEmpty || _closed) return;
    final List<AudioQueueItem> items;
    try {
      items = _queueItems();
    } on Object {
      return;
    }
    backend.updateQueue(items, queue.currentIndex, repeat: queue.repeat);
  }

  void _saveVolume() {
    final values = {
      "volume": volume,
      "previous_volume": previousVolume,
      "muted": muted,
    };
    final persistence = this.persistence;
    if (persistence != null) {
      persistence.save(volume: values);
      return;
    }
    final settings = store.settings
      ..volume = volume
      ..previousVolume = previousVolume
      ..muted = muted;
    store.saveSettings(settings);
  }

  void _clearExternal() {
    _cancelPendingLoad();
    externalTitle = "";
    externalUploader = "";
    externalThumbnail = "";
  }

  void _cancelPendingLoad({bool discardSource = false}) {
    _loadGeneration++;
    final playerWasLoading = _playerLoading;
    _loading = false;
    _playerLoading = false;
    _pendingPlayRecordId = null;
    if (_closed) return;
    if (discardSource) {
      backend.discardSource();
    } else if (playerWasLoading) {
      backend.cancelLoad();
    }
  }

  void _persist() {
    final state = queue.toJson(positionMs: positionMs, durationMs: durationMs);
    final persistence = this.persistence;
    if (persistence != null) {
      persistence.save(playback: state);
    } else {
      store.set("playback", state);
    }
  }

  void close() {
    _persist();
    _closed = true;
    _cancelPendingLoad();
  }

  /// Reserves playback intent before resolving or downloading a selection.
  int beginPendingTrack(String title) {
    _cancelPendingLoad();
    backend.pause();
    _sourceLoaded = false;
    externalTitle = title;
    externalUploader = "";
    externalThumbnail = "";
    _loading = true;
    _playing = _loadAutoplay = true;
    _mediaSessionActive = true;
    positionMs = durationMs = 0;
    _notify();
    return _loadGeneration;
  }

  bool isCurrentRequest(int generation) =>
      !_closed && generation == _loadGeneration;

  void _notify([PlaybackChange change = PlaybackChange.state]) {
    if (!_changes.isClosed) _changes.add(change);
  }

  void _error(String message) => onError?.call(message);
}
