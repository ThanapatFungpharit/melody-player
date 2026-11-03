import "dart:async";
import "dart:collection";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:melody_audio/melody_audio.dart"
    show AudioEngineSnapshot, AudioQueueItem;

import "../audio/audio_backend.dart";
import "../core/library/manager.dart";
import "library_service.dart";
import "loudness.dart";
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

  /// Records how far playback has reached, without the queue. A session
  /// snapshot written together with it carries the position instead.
  void savePosition(int positionMs, int durationMs) {
    if (_closed) return;
    final position = {
      "position_ms": max(0, positionMs),
      "duration_ms": max(0, durationMs),
    };
    if (_pending["playback"] case final Map<String, Object?> snapshot) {
      _pending["playback"] = {...snapshot, ...position};
    } else {
      _pending["position"] = position;
    }
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

/// Engine rows built on first read and then kept. A row whose track cannot
/// be played any more reads as unplayable, so the engine skips it instead of
/// one stale row failing the whole queue.
class _LazyQueueItems extends ListBase<AudioQueueItem> {
  _LazyQueueItems(this._trackIds, this._build)
    : _built = List.filled(_trackIds.length, null);

  final List<String> _trackIds;
  final AudioQueueItem Function(int row, String trackId) _build;
  final List<AudioQueueItem?> _built;

  @override
  int get length => _trackIds.length;

  @override
  set length(int value) => throw UnsupportedError("The queue is read-only");

  @override
  AudioQueueItem operator [](int index) => _built[index] ??= () {
    final trackId = _trackIds[index];
    try {
      return _build(index, trackId);
    } on Object catch (error) {
      debugPrint("Queue row $index cannot be played: $error");
      return AudioQueueItem(trackId: trackId, source: "");
    }
  }();

  @override
  void operator []=(int index, AudioQueueItem value) =>
      throw UnsupportedError("The queue is read-only");
}

/// A copy of the queue's rows and selected row.
typedef QueueSnapshot = ({List<String> items, int currentIndex});

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
    required this.persistence,
    this.loudness,
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
    _applyVolume();
    if (!listEquals(queue.items, originalItems)) _persist();
    _loudnessSubscription = loudness?.changes.listen(_loudnessChanged);
  }

  final MusicManager manager;
  final LibraryService library;
  final ApplicationStore store;
  final TrackPlayerBackend backend;
  final PlaybackPersistence persistence;

  /// Per-track loudness gains; without it every track plays unscaled.
  final LoudnessNormalizer? loudness;
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
  bool _playing = false;
  bool _sourceLoaded = false;

  /// Moves with every selection and transport command, so a Play request that
  /// is still downloading can tell the listener has moved on.
  int _requestGeneration = 0;
  bool _closed = false;
  bool _playerLoading = false;
  DateTime _lastPersistedPosition = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastBackendErrorAt;
  String? _pendingPlayRecordId;
  bool _mediaSessionActive = false;
  StreamSubscription<LoudnessChange>? _loudnessSubscription;

  /// The rows last given to the engine, whose gains it is applying.
  List<AudioQueueItem> _engineItems = const [];

  /// The gain the playing track started with. A measurement that arrives
  /// while it plays applies from its next play, so the level never moves
  /// mid-song by itself; only a settings change does (with a fade).
  ({String trackId, double gain})? _heldGain;

  bool get playing => _playing;
  bool get loading => _playerLoading;
  String? get currentTrackId => queue.current;
  bool get mediaSessionActive => _mediaSessionActive;

  /// Whether a queue row is selected.
  bool get hasMedia => currentTrackId != null;

  /// Mirrors a decoder that outlived the previous widget tree.
  void onNativeReattach(AudioEngineSnapshot state) {
    final trackId = state.trackId;
    if (trackId == null || !manager.hasTrack(trackId)) {
      // Nothing here can show or control what it is playing.
      _release();
      _persist();
      _notify(PlaybackChange.track);
      return;
    }
    // Without a resumed session, the queue is empty and the decoder is not.
    if (!queue.items.contains(trackId)) queue.replace([trackId]);
    queue.select(_rowOf(trackId, state.queueIndex));
    _sourceLoaded = true;
    _playerLoading = false;
    _playing = state.playing;
    _mediaSessionActive = true;
    positionMs = (state.position?.inMilliseconds ?? 0).clamp(0, 1 << 52);
    durationMs = (state.duration?.inMilliseconds ?? 0).clamp(0, 1 << 52);
    _persist();
    _notify(PlaybackChange.track);
  }

  /// Replaces the queue with a list of tracks and plays from the one at
  /// [startIndex], as a tap on any row of a list does.
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
    // A repeated tap on a row that is already preparing to play changes nothing.
    if (!shuffleOnce &&
        _playerLoading &&
        _playing &&
        availableIndex == queue.currentIndex &&
        listEquals(available, queue.items)) {
      return;
    }
    queue.replace(
      available,
      startIndex: availableIndex,
      shuffleOnce: shuffleOnce,
    );
    _loadCurrent(autoplay: true);
  }

  /// Plays [trackIds] right away and then returns to the queue, which they
  /// join after the current row.
  void playNow(Iterable<String> trackIds) {
    final items = _inLibrary(trackIds);
    if (items.isEmpty) {
      _error("This track is no longer in your library.");
      return;
    }
    // Already the current track: start it again rather than queue it twice.
    if (items.length > 1 || items.single != currentTrackId) {
      final selected = queue.current == null ? 0 : queue.currentIndex + 1;
      queue
        ..addNextAll(items)
        ..select(selected);
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
    _requestGeneration++;
    if (!hasMedia) {
      final tracks = manager.listTracks();
      if (tracks.isNotEmpty) {
        queue.replace([for (final track in tracks) track.id]);
        _loadCurrent(autoplay: true);
      } else {
        _error("Your library is empty. Download a track first.");
      }
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
    if (sourceWasLoaded) {
      if (wasPlaying) backend.pause();
      backend.seek(0);
    }
    _playing = false;
    positionMs = 0;
    _persist();
    _notify(PlaybackChange.track);
  }

  /// Goes to the previous row, starting it unless [resume] is false and
  /// playback is paused (system controls keep a paused player paused).
  void previous({bool resume = true}) {
    if (positionMs > 5000) {
      seek(0);
    } else if (queue.previous() != null) {
      _loadCurrent(autoplay: resume || _playing);
    }
  }

  /// Stops the music: releases the source and system controls and rewinds,
  /// keeping the queue, so Play starts its current track again. Pause keeps
  /// everything loaded.
  void stop() {
    _release();
    _persist();
    _notify(PlaybackChange.track);
  }

  /// Releases the decoder and system controls while keeping the queue.
  void _release() {
    _cancelPendingLoad(discardSource: true);
    _resetSource();
  }

  /// Forgets the loaded source and its position.
  void _resetSource() {
    _sourceLoaded = false;
    _playing = false;
    _mediaSessionActive = false;
    positionMs = 0;
    durationMs = 0;
  }

  void seek(int position) {
    positionMs = _clampPosition(position);
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
    if (!hasMedia) return;
    if (_playerLoading || !_sourceLoaded) {
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

  /// [row] while it still holds [trackId], else the track's first row; -1
  /// when it is not queued.
  int _rowOf(String trackId, int row) =>
      row >= 0 && row < queue.items.length && queue.items[row] == trackId
      ? row
      : queue.items.indexOf(trackId);

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
    if (wasCurrent) {
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

  /// The queue's rows and selection, so an edit can be undone.
  QueueSnapshot snapshotQueue() =>
      (items: List.of(queue.items), currentIndex: queue.currentIndex);

  /// Puts back the rows of [snapshot] when the track it had selected is
  /// still the current one, so undoing an edit never interrupts playback.
  /// Rows whose track left the library meanwhile are dropped.
  bool restoreQueue(QueueSnapshot snapshot) {
    final selected = snapshot.currentIndex;
    if (selected < 0 ||
        selected >= snapshot.items.length ||
        snapshot.items[selected] != currentTrackId) {
      return false;
    }
    final items = <String>[];
    var index = -1;
    for (final (row, trackId) in snapshot.items.indexed) {
      if (!manager.hasTrack(trackId)) continue;
      if (row == selected) index = items.length;
      items.add(trackId);
    }
    if (index < 0) return false;
    queue
      ..items = items
      ..currentIndex = index;
    _queueChanged();
    return true;
  }

  /// Drops queued library tracks and stops a loaded library source.
  void clearLibraryState() {
    final active = currentTrackId != null || _sourceLoaded;
    queue.clear();
    if (active) {
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
    if (currentTrackId == null && !_sourceLoaded) return;
    final (position, duration) = (positionMs, durationMs);
    _release();
    positionMs = position;
    durationMs = duration;
    _persist();
    _notify(PlaybackChange.track);
  }

  bool shuffle() {
    if (!queue.shuffle()) return false;
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
    _applyVolume();
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
    _applyVolume();
    _saveVolume();
    _notify(PlaybackChange.volume);
  }

  /// Applies live playback settings without touching the queue or session.
  void applySettings(AppSettings settings) {
    volume = settings.volume;
    previousVolume = settings.previousVolume;
    muted = settings.muted;
    _applyVolume();
    _notify(PlaybackChange.volume);
  }

  // -- decoder callbacks ---------------------------------------------------

  void onPosition(int position) {
    if (_playerLoading) return;
    final clamped = position < 0 ? 0 : position;
    positionMs = durationMs > 0 && clamped > durationMs ? durationMs : clamped;
    final now = DateTime.now();
    if (now.difference(_lastPersistedPosition) >= const Duration(seconds: 5)) {
      persistence.savePosition(positionMs, durationMs);
      _lastPersistedPosition = now;
    }
    _notify(PlaybackChange.progress);
  }

  void onDuration(int duration) {
    if (_playerLoading) return;
    durationMs = duration < 0 ? 0 : duration;
    if (durationMs > 0 && positionMs > durationMs) {
      positionMs = durationMs;
      _persist();
    }
    _notify(PlaybackChange.progress);
  }

  void onPlaying(bool playing) {
    if (!_sourceLoaded) return;
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
      persistence.recordPlay(trackId);
    }
    _notify();
  }

  void onCompleted() {
    if (_playerLoading || !_sourceLoaded) return;
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
    final selected = _rowOf(trackId, index);
    if (selected < 0) return;
    queue.select(selected);
    // The engine already applied the gain it was given for this row.
    final sent =
        index >= 0 &&
            index < _engineItems.length &&
            _engineItems[index].trackId == trackId
        ? _engineItems[index]
        : _engineItems.where((item) => item.trackId == trackId).firstOrNull;
    _heldGain = sent == null ? null : (trackId: trackId, gain: sent.gain);
    _sourceLoaded = true;
    _playerLoading = true;
    _playing = true;
    _mediaSessionActive = true;
    positionMs = 0;
    durationMs = 0;
    _pendingPlayRecordId = trackId;
    _persist();
    _notify(PlaybackChange.track);
  }

  /// Adopts Stop after the native player handled a system action; it keeps the
  /// queue like the in-app Stop button.
  void onStopped() {
    if (_closed) return;
    // The engine already released its decoders; only supersede pending work.
    _requestGeneration++;
    _playerLoading = false;
    _pendingPlayRecordId = null;
    _resetSource();
    _persist();
    _notify(PlaybackChange.track);
  }

  /// Reconciles optimistic state after a decoder failure.
  void onBackendError(String message) {
    // Supersede pending generations first so a late callback cannot
    // resurrect a rejected track.
    _cancelPendingLoad(discardSource: true);
    _playing = false;
    _sourceLoaded = false;
    _playerLoading = false;
    _mediaSessionActive = false;
    _pendingPlayRecordId = null;
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
    _cancelPendingLoad();
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

  /// The queue as the engine sees it. Rows are built when the engine reads
  /// them, which is only those in or near its decoder's playlist.
  List<AudioQueueItem> _queueItems() {
    final held = _heldGain;
    return _LazyQueueItems(List.of(queue.items), (row, trackId) {
      final details = library.details(trackId);
      return AudioQueueItem(
        trackId: trackId,
        // A native path; the decoder validates existence and format.
        source: manager.trackPath(trackId),
        title: manager.getTrack(trackId).displayTitle,
        artist: details.uploader,
        album: details.sourceName,
        artworkUri: _artworkUri(details.thumbnail),
        gain: _gainFor(trackId, row, held),
      );
    });
  }

  double _gainFor(
    String trackId,
    int row,
    ({String trackId, double gain})? held,
  ) {
    if (held != null && row == queue.currentIndex && held.trackId == trackId) {
      return held.gain;
    }
    return loudness?.gainFor(trackId) ?? 1;
  }

  /// New measurements reach upcoming rows; a settings change also reaches
  /// the playing track, which the engine fades to its new level.
  void _loudnessChanged(LoudnessChange change) {
    if (_closed) return;
    final trackId = currentTrackId;
    if (change == LoudnessChange.settings && trackId != null) {
      _heldGain = (trackId: trackId, gain: loudness?.gainFor(trackId) ?? 1);
    }
    _syncQueue();
  }

  void _activateQueue(
    String trackId, {
    required bool autoplay,
    required int positionMs,
  }) {
    // Fails here, with its reason, when the selected track cannot be played.
    manager.trackPath(trackId);
    _heldGain = null;
    final items = _queueItems();
    // The selected row, not the first copy: the queue may repeat a track.
    final index = queue.currentIndex;
    _heldGain = (trackId: trackId, gain: items[index].gain);
    _engineItems = items;
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
    if (_closed) return;
    final items = _queueItems();
    _engineItems = items;
    backend.updateQueue(items, queue.currentIndex, repeat: queue.repeat);
  }

  void _applyVolume() => backend.setVolume(muted ? 0 : volume / 100);

  void _saveVolume() => persistence.save(
    volume: {
      "volume": volume,
      "previous_volume": previousVolume,
      "muted": muted,
    },
  );

  void _cancelPendingLoad({bool discardSource = false}) {
    _requestGeneration++;
    final playerWasLoading = _playerLoading;
    _playerLoading = false;
    _pendingPlayRecordId = null;
    if (_closed) return;
    if (discardSource) {
      backend.discardSource();
    } else if (playerWasLoading) {
      backend.cancelLoad();
    }
  }

  void _persist() => persistence.save(
    playback: queue.toJson(positionMs: positionMs, durationMs: durationMs),
  );

  void close() {
    _persist();
    _closed = true;
    unawaited(_loudnessSubscription?.cancel());
    _cancelPendingLoad();
  }

  /// Registers a wish to play something once it is ready; the listener's
  /// next selection or transport command supersedes it. Meanwhile the current
  /// music plays on.
  int beginPlayRequest() => ++_requestGeneration;

  bool isCurrentRequest(int generation) =>
      !_closed && generation == _requestGeneration;

  void _notify([PlaybackChange change = PlaybackChange.state]) {
    if (!_changes.isClosed) _changes.add(change);
  }

  void _error(String message) => onError?.call(message);
}
