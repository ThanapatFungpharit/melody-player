/// Puts lyrics inside library audio files, so a track's lyrics travel with
/// it instead of living in a separate file.
library;

import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/artwork.dart" show readEmbeddedLyrics;
import "../core/errors.dart" show WorkerFailure;
import "../core/id3_lyrics.dart";
import "../core/library/manager.dart";
import "../core/storage.dart" show deleteQuietly, temporarySibling;
import "lyrics.dart";
import "store.dart";

/// Copies [source] to [target] with every stream and tag kept and [tags]
/// set (FFmpeg, through the worker).
typedef TagCopier =
    Future<void> Function(
      String source,
      String target,
      Map<String, String> tags,
    );

enum _Outcome { embedded, unchanged, unsupported, busy }

/// Embeds lyrics in YouTube Music tracks whose audio has none.
///
/// Downloads embed lyrics while they are staged; this covers tracks
/// downloaded before that, and downloads whose lyrics were not ready in time.
/// One file is rewritten at a time under the library's mutation lock: the
/// lyrics go into a copy beside the file, the copy replaces it, and the
/// track's recorded hash follows. MP3s get a standard ID3 `USLT` frame;
/// other formats are copied by FFmpeg with a `lyrics` tag.
///
/// A playing track is rewritten once playback moves on. A file that cannot
/// take lyrics (an ID3 layout the writer leaves alone, or one FFmpeg cannot
/// copy, such as Opus with cover art) is left as it is and not tried again
/// until its content changes; its lyrics still show from [LyricsLibrary]'s
/// saved copy.
class LyricsEmbedder {
  LyricsEmbedder(this._manager, this._lyrics, this._store, this._copyWithTags);

  final MusicManager _manager;
  final LyricsLibrary _lyrics;
  final ApplicationStore _store;
  final TagCopier _copyWithTags;

  /// Whether a track's file is in use by playback, so it is left until
  /// playback moves on.
  bool Function(String trackId) isPlaying = _never;

  final Set<String> _pending = {};
  final Set<String> _deferred = {};
  final Map<String, int> _attempts = {};
  Completer<void>? _draining;
  bool _closed = false;

  /// Rewrites of one file per session; a file that stays locked waits for
  /// the next launch.
  static const _maxAttempts = 3;

  /// State key: the content hash of each track's file that cannot take
  /// lyrics, by track ID.
  static const _unsupportedKey = "lyrics_not_embedded";

  static bool _never(String trackId) => false;

  /// Queues tracks; ones that already carry lyrics are skipped quickly.
  void embed(Iterable<String> trackIds) {
    if (_closed) return;
    _pending.addAll(trackIds);
    if (_pending.isNotEmpty && _draining == null) unawaited(_drain());
  }

  /// Forgets removed tracks' records and queues every track in the
  /// library. (Copies an interrupted rewrite left are removed with the
  /// other temporary files at launch.)
  void embedLibrary() {
    final unsupported = _unsupported();
    final stale = unsupported.keys.where((id) => !_manager.hasTrack(id));
    if (stale.isNotEmpty) {
      try {
        _store.set(
          _unsupportedKey,
          unsupported..removeWhere((id, _) => !_manager.hasTrack(id)),
        );
      } on Object catch (error) {
        debugPrint("Could not update files without lyrics: $error");
      }
    }
    embed([for (final track in _manager.listTracks()) track.id]);
  }

  /// Retries tracks that were playing when their turn came.
  void retryDeferred() {
    if (_deferred.isEmpty) return;
    final trackIds = [..._deferred];
    _deferred.clear();
    embed(trackIds);
  }

  /// Completes once the queue is empty.
  Future<void> get idle => _draining?.future ?? Future.value();

  void close() => _closed = true;

  Future<void> _drain() async {
    final draining = _draining = Completer<void>();
    try {
      while (_pending.isNotEmpty && !_closed) {
        final trackId = _pending.first;
        _pending.remove(trackId);
        try {
          await _embed(trackId);
        } on Object catch (error) {
          // Offline or a disk error: tried again next launch.
          debugPrint("Lyrics were not embedded for track $trackId: $error");
        }
      }
    } finally {
      _draining = null;
      draining.complete();
    }
  }

  Future<void> _embed(String trackId) async {
    if (!_manager.hasTrack(trackId)) return;
    final track = _manager.getTrack(trackId);
    if (!_lyrics.supports(track.source)) return;
    if (_unsupported()[trackId] == track.contentHash) return;
    final path = _manager.trackPath(trackId);
    if (!await File(path).exists()) return;
    if ((await readEmbeddedLyrics(path)).isNotEmpty) {
      await LyricsLibrary.removeMelodySidecar(path);
      return;
    }
    final lyrics = await _lyrics.load(track.source);
    if (lyrics == null) return;
    if (isPlaying(trackId)) {
      _deferred.add(trackId);
      return;
    }
    final attempts = _attempts[trackId] = (_attempts[trackId] ?? 0) + 1;
    final outcome = await _manager.mutation.run(
      () => _rewrite(trackId, path, lyrics.toLrc()),
    );
    switch (outcome) {
      case _Outcome.embedded:
        await LyricsLibrary.removeMelodySidecar(path);
      case _Outcome.unsupported:
        _saveUnsupported(trackId, track.contentHash);
      case _Outcome.busy when attempts < _maxAttempts:
        _deferred.add(trackId);
      case _Outcome.busy || _Outcome.unchanged:
        break;
    }
  }

  /// Runs under the library's mutation lock.
  Future<_Outcome> _rewrite(String trackId, String path, String text) async {
    // The track may have been removed, moved, or repaired meanwhile.
    if (!_manager.hasTrack(trackId) ||
        !p.equals(_manager.trackPath(trackId), path) ||
        await _manager.checkTrackIntegrity(trackId) != null) {
      return _Outcome.unchanged;
    }
    final copy = temporarySibling(path);
    try {
      try {
        if (p.extension(path).toLowerCase() == ".mp3") {
          await File(path).copy(copy);
          if (!await writeId3Lyrics(copy, text)) return _Outcome.unsupported;
        } else {
          await _copyWithTags(path, copy, {"lyrics": text});
        }
      } on FileSystemException {
        rethrow;
      } on Object catch (error) {
        // The worker could not run FFmpeg (stopped, or yt-dlp unavailable):
        // nothing is known about the file, so it is tried again.
        if (error is WorkerFailure && !_ffmpegRefused(error)) rethrow;
        debugPrint("Lyrics cannot be embedded in $path: $error");
        return _Outcome.unsupported;
      }
      if ((await readEmbeddedLyrics(copy)).isEmpty) return _Outcome.unsupported;
      if (isPlaying(trackId)) return _Outcome.busy;
      try {
        await File(copy).rename(path);
      } on FileSystemException catch (error) {
        // Usually the player still has the file open (Windows).
        debugPrint("Could not replace $path: $error");
        return _Outcome.busy;
      }
      await _manager.replaceTrackFile(trackId, path);
      return _Outcome.embedded;
    } finally {
      await deleteQuietly(copy);
    }
  }

  /// FFmpeg ran and failed: yt-dlp reports that as a postprocessing error.
  static bool _ffmpegRefused(WorkerFailure error) =>
      error.types.any((type) => type.contains("PostProcess"));

  Map<String, String> _unsupported() => {
    if (_store.get(_unsupportedKey) case final Map entries)
      for (final MapEntry(:key, :value) in entries.entries)
        if (key is String && value is String) key: value,
  };

  /// Records that [trackId]'s file with [contentHash] cannot take lyrics,
  /// dropping tracks the library no longer has.
  void _saveUnsupported(String trackId, String contentHash) {
    final entries = _unsupported()
      ..[trackId] = contentHash
      ..removeWhere((id, _) => !_manager.hasTrack(id));
    try {
      _store.set(_unsupportedKey, entries);
    } on Object catch (error) {
      // The file is simply tried again next launch.
      debugPrint("Could not record a file without lyrics: $error");
    }
  }
}
