/// Puts lyrics inside library audio files, so a track's lyrics travel with
/// it instead of living in a separate file.
library;

import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/artwork.dart" show readEmbeddedLyrics;
import "../core/id3_lyrics.dart";
import "../core/library/manager.dart";
import "../core/storage.dart" show deleteQuietly, temporarySibling;
import "lyrics.dart";

/// Copies [source] to [target] with every stream and tag kept and [tags]
/// set (FFmpeg, through the worker).
typedef TagCopier =
    Future<void> Function(
      String source,
      String target,
      Map<String, String> tags,
    );

enum _Outcome { embedded, unchanged, failed, busy }

/// What a pass did with the tracks it was given.
class LyricsEmbedReport {
  const LyricsEmbedReport(this.written, this.failed, this.playing);

  final int written;

  /// Files that could not take lyrics, or whose lyrics could not be fetched.
  final int failed;

  /// Files left alone because they were in use.
  final int playing;
}

/// Embeds lyrics in YouTube Music tracks whose audio has none, when asked.
///
/// Downloads embed lyrics while they are staged; this covers tracks
/// downloaded before that, and downloads whose lyrics were not ready in time.
/// One file is rewritten at a time under the library's mutation lock: the
/// lyrics go into a copy beside the file, the copy replaces it, and the
/// track's recorded hash follows. MP3s get a standard ID3 `USLT` frame;
/// other formats are copied by FFmpeg with a `lyrics` tag. A file that cannot
/// take lyrics, or is playing, is left as it is; its lyrics still show from
/// [LyricsLibrary]'s saved copy.
class LyricsEmbedder {
  LyricsEmbedder(this._manager, this._lyrics, this._copyWithTags);

  final MusicManager _manager;
  final LyricsLibrary _lyrics;
  final TagCopier _copyWithTags;

  /// Whether a track's file is in use by playback, so it is left alone.
  bool Function(String trackId) isPlaying = _never;

  bool _closed = false;

  static bool _never(String trackId) => false;

  void close() => _closed = true;

  Future<LyricsEmbedReport> embedLibrary() =>
      embed([for (final track in _manager.listTracks()) track.id]);

  /// Embeds lyrics in [trackIds], skipping ones that already carry them.
  Future<LyricsEmbedReport> embed(Iterable<String> trackIds) async {
    var written = 0;
    var failed = 0;
    var playing = 0;
    for (final trackId in trackIds) {
      if (_closed) break;
      try {
        switch (await _embed(trackId)) {
          case _Outcome.embedded:
            written++;
          case _Outcome.failed:
            failed++;
          case _Outcome.busy:
            playing++;
          case _Outcome.unchanged:
            break;
        }
      } on Object catch (error) {
        debugPrint("Lyrics were not embedded for track $trackId: $error");
        failed++;
      }
    }
    return LyricsEmbedReport(written, failed, playing);
  }

  Future<_Outcome> _embed(String trackId) async {
    if (!_manager.hasTrack(trackId)) return _Outcome.unchanged;
    final track = _manager.getTrack(trackId);
    if (!_lyrics.supports(track.source)) return _Outcome.unchanged;
    final path = _manager.trackPath(trackId);
    if (!await File(path).exists()) return _Outcome.unchanged;
    if ((await readEmbeddedLyrics(path)).isNotEmpty) {
      await LyricsLibrary.removeMelodySidecar(path);
      return _Outcome.unchanged;
    }
    final lyrics = await _lyrics.load(track.source);
    if (lyrics == null) return _Outcome.unchanged;
    if (isPlaying(trackId)) return _Outcome.busy;
    final outcome = await _manager.mutation.run(
      () => _rewrite(trackId, path, lyrics.toLrc()),
    );
    if (outcome == _Outcome.embedded) {
      await LyricsLibrary.removeMelodySidecar(path);
    }
    return outcome;
  }

  /// Runs under the library's mutation lock.
  Future<_Outcome> _rewrite(String trackId, String path, String text) async {
    // The track may have been removed, moved, or repaired meanwhile.
    if (!_manager.hasTrack(trackId) ||
        !p.equals(_manager.trackPath(trackId), path) ||
        await _manager.checkTrackFile(trackId) != null) {
      return _Outcome.unchanged;
    }
    final copy = temporarySibling(path);
    try {
      if (p.extension(path).toLowerCase() == ".mp3") {
        await File(path).copy(copy);
        if (!await writeId3Lyrics(copy, text)) return _Outcome.failed;
      } else {
        await _copyWithTags(path, copy, {"lyrics": text});
      }
      if ((await readEmbeddedLyrics(copy)).isEmpty) return _Outcome.failed;
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
}
