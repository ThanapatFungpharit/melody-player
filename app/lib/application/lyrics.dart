/// Song lyrics: from the audio file itself, a `.lrc` file beside it, or
/// YouTube Music, saved on disk so they show offline.
library;

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/artwork.dart" show readEmbeddedLyrics;
import "../core/errors.dart";
import "../core/media.dart";
import "../core/storage.dart" show atomicWrite, deleteQuietly, unixSeconds;

/// One line of lyrics. Timed lines carry their start and end in milliseconds.
@immutable
class LyricLine {
  const LyricLine(this.text, {this.startMs = -1, this.endMs = -1});

  final String text;
  final int startMs;
  final int endMs;

  bool get timed => startMs >= 0;
}

final _lrcTimestamps = RegExp(r"^((?:\[\d+:\d{1,2}(?:[.:]\d{1,3})?\])+)(.*)$");
final _lrcTimestamp = RegExp(r"\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]");
final _lrcTag = RegExp(r"^\[([A-Za-z]+):(.*)\]$");

/// Enhanced LRC word timings (`<01:02.34>`) inside a line's words.
final _lrcWordTimestamp = RegExp(r"\s*<\d+:\d{1,2}(?:[.:]\d{1,3})?>\s*");

/// Any line break: `\r\n`, `\n`, or a lone `\r`.
final _lineBreak = RegExp(r"\r\n?|\n");

/// [text] without a leading byte order mark, split into lines.
List<String> _lines(String text) =>
    (text.startsWith("﻿") ? text.substring(1) : text).split(_lineBreak);

/// [items] sorted by [compare], with items that compare equal kept in their
/// order (List.sort is not stable).
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = items.indexed.toList()
    ..sort((a, b) {
      final order = compare(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  return [for (final (_, item) in indexed) item];
}

/// A timestamp from a YouTube Music reply or a saved file; -1 when missing
/// or not a usable number.
int _milliseconds(Object? value) => switch (value) {
  final num number when number.isFinite && number >= 0 => number.toInt(),
  final String text => int.tryParse(text.trim()) ?? -1,
  _ => -1,
};

@immutable
class Lyrics {
  const Lyrics(this.lines, {this.source = ""});

  /// Plain text, one line per line break.
  factory Lyrics.plain(String text, {String source = ""}) => Lyrics([
    for (final line in _lines(text)) LyricLine(line.trimRight()),
  ], source: source);

  /// LRC (`[01:02.34]words`, with optional `[offset:ms]` and other tags) or
  /// plain text, as found in tags and `.lrc` files.
  factory Lyrics.parse(String text, {String source = ""}) {
    final timed = <(int, String)>[];
    final plain = <String>[];
    var offset = 0;
    for (final raw in _lines(text)) {
      final line = raw.trimRight();
      final stamps = _lrcTimestamps.firstMatch(line);
      if (stamps != null) {
        final words = stamps
            .group(2)!
            .replaceAll(_lrcWordTimestamp, " ")
            .trim();
        for (final stamp in _lrcTimestamp.allMatches(stamps.group(1)!)) {
          final fraction = (stamp.group(3) ?? "0").padRight(3, "0");
          // A runaway minute count must not overflow or throw.
          final minutes = int.tryParse(stamp.group(1)!) ?? -1;
          if (minutes < 0 || minutes > 99999) continue;
          timed.add((
            minutes * 60000 +
                int.parse(stamp.group(2)!) * 1000 +
                int.parse(fraction),
            words,
          ));
        }
        continue;
      }
      final tag = _lrcTag.firstMatch(line.trim());
      if (tag != null) {
        if (tag.group(1)!.toLowerCase() == "offset") {
          offset = (int.tryParse(tag.group(2)!.trim()) ?? 0).clamp(
            -86400000,
            86400000,
          );
        }
        continue;
      }
      plain.add(line);
    }
    if (timed.isEmpty) {
      while (plain.isNotEmpty && plain.first.trim().isEmpty) {
        plain.removeAt(0);
      }
      return Lyrics([
        for (final line in plain) LyricLine(line),
      ], source: source);
    }
    // Lines sharing a timestamp (such as a line and its translation) keep
    // their file order.
    final ordered = _stableSorted(timed, (a, b) => a.$1.compareTo(b.$1));
    // A positive offset shows lyrics sooner.
    return Lyrics([
      for (final (index, (start, words)) in ordered.indexed)
        LyricLine(
          words,
          startMs: (start - offset).clamp(0, 1 << 31),
          endMs: index + 1 < ordered.length
              ? (ordered[index + 1].$1 - offset).clamp(0, 1 << 31)
              : -1,
        ),
    ], source: source);
  }

  /// A ytmusicapi `get_lyrics(timestamps=True)` reply, or null when empty.
  static Lyrics? fromYtMusic(Map<String, Object?> data) {
    final source = "${data["source"] ?? ""}".trim();
    final body = data["lyrics"];
    final Lyrics lyrics;
    if (body is List) {
      final lines = [
        for (final value in body)
          if (value is Map)
            LyricLine(
              "${value["text"] ?? ""}",
              startMs: _milliseconds(value["start_time"]),
              endMs: _milliseconds(value["end_time"]),
            ),
      ];
      // lineAt searches by start time, so timed lines must be in order;
      // equal starts keep their reply order.
      lyrics = Lyrics(
        lines.every((line) => line.timed)
            ? _stableSorted(lines, (a, b) => a.startMs.compareTo(b.startMs))
            : lines,
        source: source,
      );
    } else if (body is String) {
      lyrics = Lyrics.plain(body, source: source);
    } else {
      return null;
    }
    return lyrics.hasText ? lyrics : null;
  }

  factory Lyrics.fromJson(Map<String, Object?> data) => Lyrics([
    if (data["lines"] case final List<Object?> lines)
      for (final line in lines)
        if (line is Map)
          LyricLine(
            "${line["text"] ?? ""}",
            startMs: _milliseconds(line["start"]),
            endMs: _milliseconds(line["end"]),
          ),
  ], source: "${data["source"] ?? ""}");

  final List<LyricLine> lines;

  /// Where the lyrics came from, such as "Source: LyricFind".
  final String source;

  bool get hasText => lines.any((line) => line.text.trim().isNotEmpty);

  /// Whether every line has a start time, so the view can follow playback.
  bool get synced => lines.isNotEmpty && lines.every((line) => line.timed);

  /// The line being sung at [positionMs], or -1 before the first one.
  int lineAt(int positionMs) {
    if (!synced) return -1;
    var low = 0;
    var high = lines.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (lines[middle].startMs <= positionMs) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  /// LRC lines when synced, plain text otherwise: what tags and `.lrc`
  /// files hold.
  String toLrc() => [
    for (final line in lines)
      line.timed ? "${_lrcTime(line.startMs)}${line.text}" : line.text,
  ].join("\n");

  static String _lrcTime(int milliseconds) {
    final minutes = milliseconds ~/ 60000;
    final seconds = (milliseconds ~/ 1000) % 60;
    final hundredths = (milliseconds % 1000) ~/ 10;
    String two(int value) => value.toString().padLeft(2, "0");
    return "[${two(minutes)}:${two(seconds)}.${two(hundredths)}]";
  }

  Map<String, Object?> toJson() => {
    "source": source,
    "lines": [
      for (final line in lines)
        {
          "text": line.text,
          if (line.timed) "start": line.startMs,
          if (line.timed) "end": line.endMs,
        },
    ],
  };
}

/// Lyrics could not be shown for a track.
class LyricsUnavailable implements Exception {
  const LyricsUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What is saved for a track: lyrics, or a record that it has none.
@immutable
class SavedLyrics {
  const SavedLyrics(this.lyrics, this.checkedAt);

  /// Null when YouTube Music had no lyrics at [checkedAt].
  final Lyrics? lyrics;

  /// Seconds since the Unix epoch.
  final double checkedAt;
}

/// A library track as lyrics see it: where it came from and its audio file.
typedef LyricsTrack = ({String source, String path});

/// Where a track's lyrics live, and how they are found and saved.
///
/// Lookup order: a `.lrc` file beside the audio, lyrics embedded in the
/// audio's tags, lyrics saved in [directory] (one JSON file per YouTube
/// Music track), then YouTube Music. Downloads embed lyrics in the audio
/// file, and LyricsEmbedder adds them to tracks downloaded without; the
/// saved copy keeps them showing offline until then, and records tracks
/// without lyrics so they are checked again only after [recheckAfter].
///
/// Melody no longer writes `.lrc` files. Ones it wrote earlier are marked
/// `[re:Melody]` and removed once the audio carries the lyrics; a user's own
/// `.lrc` is always read and never changed.
class LyricsLibrary {
  LyricsLibrary(
    this.directory,
    this._fetch, {
    this.recheckAfter = const Duration(days: 7),
  });

  final String directory;

  /// Fetches lyrics for a YouTube video ID; null when it has none.
  final Future<Lyrics?> Function(String videoId) _fetch;
  final Duration recheckAfter;
  final Map<String, Future<Lyrics?>> _loading = {};
  Future<void> _prefetchQueue = Future.value();

  static const _version = 1;
  static const _sidecarMarker = "[re:Melody]";
  static final _unsafe = RegExp(r"[^A-Za-z0-9_-]");

  /// The `.lrc` file that belongs to [audioPath].
  static String sidecarPath(String audioPath) =>
      p.setExtension(audioPath, ".lrc");

  /// Removes a `.lrc` Melody wrote beside [audioPath]; a user's own is
  /// kept. Failures are ignored.
  static Future<void> removeMelodySidecar(String audioPath) async {
    final file = File(sidecarPath(audioPath));
    try {
      if (!await file.exists()) return;
      if ((await file.readAsString()).contains(_sidecarMarker)) {
        await file.delete();
      }
    } on Object catch (error) {
      debugPrint("Could not remove ${file.path}: $error");
    }
  }

  /// Removes the `.lrc` beside a deleted audio file. Failures only log.
  static Future<void> deleteSidecar(String audioPath) =>
      deleteQuietly(sidecarPath(audioPath));

  /// Removes what is saved for [source] unless one of [keepFor] is the same
  /// YouTube Music track. Failures only log.
  Future<void> forget(
    String source, {
    Iterable<String> keepFor = const [],
  }) async {
    final identity = _identity(source);
    if (identity == null) return;
    if (keepFor.any((other) => _identity(other)?.key == identity.key)) return;
    await deleteQuietly(_path(identity));
  }

  /// Deletes the saved lyrics of every song not among [sources] (the
  /// library's tracks): those saved for a preview, a download that failed,
  /// or a track since removed. Call it before downloads start. Other files
  /// in the folder are left alone. Returns how many were removed.
  Future<int> retainOnly(Iterable<String> sources) async {
    final keep = {
      for (final source in sources)
        if (_identity(source) case final identity?) p.basename(_path(identity)),
    };
    var removed = 0;
    try {
      if (!await Directory(directory).exists()) return 0;
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is File &&
            _savedName.hasMatch(name) &&
            !keep.contains(name) &&
            await deleteQuietly(entity.path)) {
          removed++;
        }
      }
    } on FileSystemException catch (error) {
      debugPrint("Could not prune saved lyrics: $error");
    }
    return removed;
  }

  static final _savedName = RegExp(r"^[a-z]+_[A-Za-z0-9_-]+\.json$");

  /// Whether lyrics can be saved for [source]: YouTube Music tracks.
  bool supports(String source) => _identity(source) != null;

  MediaIdentity? _identity(String source) {
    final identity = MediaIdentity.fromUrl(source);
    return identity?.provider == youtubeProviderId ? identity : null;
  }

  String _path(MediaIdentity identity) => p.join(
    directory,
    "${identity.provider}_${identity.mediaId.replaceAll(_unsafe, "_")}.json",
  );

  /// Lyrics for a library track, from its files first and then, for
  /// YouTube Music tracks, saved or fetched lyrics. [refresh] asks YouTube
  /// Music again (and re-reads the files of other tracks).
  ///
  /// Returns null when there are none. Throws [ProviderError] when nothing
  /// is saved and YouTube Music cannot be reached.
  Future<Lyrics?> forTrack(LyricsTrack track, {bool refresh = false}) async {
    final identity = _identity(track.source);
    if (identity == null || !refresh) {
      final local = await fromFiles(track.path);
      if (local != null || identity == null) return local;
    }
    return load(track.source, refresh: refresh);
  }

  /// Lyrics from a `.lrc` beside [audioPath], or embedded in its tags.
  Future<Lyrics?> fromFiles(String audioPath) async {
    if (audioPath.isEmpty) return null;
    final sidecar = File(sidecarPath(audioPath));
    try {
      if (await sidecar.exists()) {
        final lyrics = Lyrics.parse(_decodeText(await sidecar.readAsBytes()));
        if (lyrics.hasText) return lyrics;
      }
    } on FileSystemException catch (error) {
      debugPrint("Could not read ${sidecar.path}: $error");
    }
    if (!await File(audioPath).exists()) return null;
    final embedded = await readEmbeddedLyrics(audioPath);
    if (embedded.isEmpty) return null;
    final lyrics = Lyrics.parse(embedded);
    return lyrics.hasText ? lyrics : null;
  }

  /// `.lrc` text: UTF-8 (with or without a byte order mark), UTF-16 with a
  /// byte order mark, or else Latin-1, which older tools write and which
  /// decodes any bytes.
  static String _decodeText(List<int> bytes) {
    if (bytes.length >= 2) {
      final bigEndian = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (bigEndian || (bytes[0] == 0xFF && bytes[1] == 0xFE)) {
        return String.fromCharCodes([
          for (var i = 2; i + 1 < bytes.length; i += 2)
            bigEndian
                ? bytes[i] << 8 | bytes[i + 1]
                : bytes[i + 1] << 8 | bytes[i],
        ]);
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// What is saved for [source], without using the network.
  Future<SavedLyrics?> saved(String source) async {
    final identity = _identity(source);
    if (identity == null) return null;
    try {
      final data = jsonDecode(await File(_path(identity)).readAsString());
      if (data is! Map || data["version"] != _version) return null;
      if (data["media"] != identity.key) return null;
      final lyrics = data["lyrics"];
      return SavedLyrics(
        lyrics is Map ? Lyrics.fromJson(lyrics.cast<String, Object?>()) : null,
        (data["checked_at"] as num?)?.toDouble() ?? 0,
      );
    } on PathNotFoundException {
      return null;
    } on Object catch (error) {
      debugPrint("Saved lyrics could not be read: $error");
      return null;
    }
  }

  /// Saved lyrics for a YouTube Music [source], fetched and saved first
  /// when needed.
  ///
  /// Returns null when the track has no lyrics. Throws [LyricsUnavailable]
  /// for other sources, and [ProviderError] when nothing is saved and
  /// YouTube Music cannot be reached.
  Future<Lyrics?> load(String source, {bool refresh = false}) async {
    final identity = _identity(source);
    if (identity == null) {
      throw const LyricsUnavailable(
        "Lyrics are available for $youtubeMusicName tracks.",
      );
    }
    final existing = await saved(source);
    if (!refresh && existing != null && !_shouldRecheck(existing)) {
      return existing.lyrics;
    }
    try {
      return await _download(identity);
    } on ProviderError {
      // Offline, or YouTube Music failed: keep showing what was saved.
      if (existing != null) return existing.lyrics;
      rethrow;
    }
  }

  /// Saves lyrics for [tracks] in the background, one at a time. Tracks
  /// with anything saved are not fetched again; failures are ignored and
  /// retried the next time the lyrics are needed.
  void prefetch(Iterable<LyricsTrack> tracks) {
    for (final track in tracks) {
      final identity = _identity(track.source);
      if (identity == null) continue;
      _prefetchQueue = _prefetchQueue.then((_) async {
        try {
          if (await saved(track.source) == null) await _download(identity);
        } on Object catch (error) {
          debugPrint("Lyrics were not saved for ${identity.key}: $error");
        }
      });
    }
  }

  /// Completes once every queued prefetch has finished.
  @visibleForTesting
  Future<void> get idle => _prefetchQueue;

  bool _shouldRecheck(SavedLyrics saved) =>
      saved.lyrics == null &&
      unixSeconds() - saved.checkedAt > recheckAfter.inSeconds;

  /// Joins a fetch already running for [identity]. Once it settles, later
  /// requests fetch again (or read what was just saved).
  Future<Lyrics?> _download(MediaIdentity identity) {
    final key = identity.key;
    // Removed only after it was stored, so a fetch that fails before it
    // returns cannot leave its failure here for good. A block body: an
    // arrow would hand whenComplete this very future to wait for.
    return _loading[key] ??= _fetchAndSave(identity).whenComplete(() {
      _loading.remove(key);
    });
  }

  Future<Lyrics?> _fetchAndSave(MediaIdentity identity) async {
    final lyrics = await _fetch(identity.mediaId);
    await _write(identity, lyrics);
    return lyrics;
  }

  Future<void> _write(MediaIdentity identity, Lyrics? lyrics) async {
    try {
      await atomicWrite(
        _path(identity),
        utf8.encode(
          jsonEncode({
            "version": _version,
            "media": identity.key,
            "checked_at": unixSeconds(),
            "lyrics": lyrics?.toJson(),
          }),
        ),
      );
    } on FileSystemException catch (error) {
      // Lyrics still show this time; they are just not kept.
      debugPrint("Lyrics could not be saved: $error");
    }
  }
}
