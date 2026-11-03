import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/artwork.dart" show maxArtworkBytes;
import "../core/storage.dart";

/// Cover art for library tracks, one file per track ID.
///
/// The authoritative artwork is embedded in each media file. This cache holds
/// a copy so the UI and the system media session can show it without opening
/// the file or using the network. An empty entry records that the file holds
/// none, so it is not read again. Everything here can be deleted.
class ThumbnailCache {
  /// A cache that discovers entries on first lookup. Prefer [open], which
  /// indexes the folder once off the UI isolate.
  ThumbnailCache(this.directory);

  /// Creates [directory] and lists its entries in a background isolate, so
  /// later lookups never touch the disk.
  static Future<ThumbnailCache> open(String directory) async {
    final cache = ThumbnailCache(directory);
    await Directory(directory).create(recursive: true);
    try {
      final entries = await Isolate.run(() => _scanEntries(directory));
      for (final MapEntry(:key, :value) in entries.entries) {
        // An answer recorded while the scan ran is newer.
        cache._entries.putIfAbsent(key, () => value);
      }
      cache._indexed = true;
    } on FileSystemException catch (error) {
      debugPrint("Could not index cached thumbnails: $error");
    }
    return cache;
  }

  final String directory;

  /// Each track with an entry, and whether the entry holds artwork. Only this
  /// object writes the directory, so an answer stays valid until it changes
  /// that entry. Once [_indexed], a track missing here has no entry; before
  /// that, a lookup asks the disk once and remembers the answer.
  final Map<String, bool?> _entries = {};
  bool _indexed = false;

  /// The directory as a file URI ending in a slash; entry names need no
  /// escaping, so every entry's URI is this plus its name.
  late final String _directoryUri = Uri.directory(
    File(directory).absolute.path,
  ).toString();

  String _entryPath(String trackId) => p.join(directory, "$trackId.thumb");

  bool? _entry(String trackId) => _indexed
      ? _entries[trackId]
      : _entries.containsKey(trackId)
      ? _entries[trackId]
      : _entries[trackId] = _readEntry(_entryPath(trackId));

  /// Whether the track's file has been read for artwork, with or without any.
  bool known(String trackId) => _entry(trackId) != null;

  /// The cached artwork of a track, without touching the network.
  String? cachedPath(String trackId) =>
      _entry(trackId) == true ? _entryPath(trackId) : null;

  /// The cached artwork of a track as a file URI, for system media controls.
  String? artworkUri(String trackId) =>
      _entry(trackId) == true ? "$_directoryUri$trackId.thumb" : null;

  /// Whether an entry holds artwork; null without an entry.
  static bool? _readEntry(String path) {
    try {
      final status = File(path).statSync();
      return status.type == FileSystemEntityType.file ? status.size > 0 : null;
    } on FileSystemException {
      return null;
    }
  }

  static Map<String, bool> _scanEntries(String directory) => {
    for (final entity in Directory(directory).listSync(followLinks: false))
      if (entity is File && _entryName.hasMatch(p.basename(entity.path)))
        p.basenameWithoutExtension(entity.path): ?_readEntry(entity.path),
  };

  void _forget(String trackId) {
    if (_indexed) {
      _entries.remove(trackId);
    } else {
      _entries[trackId] = null;
    }
  }

  /// Drops a track's entry. Failures only log.
  Future<void> remove(String trackId) async {
    try {
      await File(_entryPath(trackId)).delete();
    } on PathNotFoundException {
      // Already gone.
    } on FileSystemException catch (error) {
      debugPrint("Could not remove a cached thumbnail: $error");
    } finally {
      _forget(trackId);
    }
  }

  /// Deletes the entries of every track not in [trackIds], and those of earlier
  /// releases, which were named after a URL's hash. Other files in the folder
  /// are left alone. Returns how many entries were removed. Runs in a
  /// background isolate: it lists the folder.
  Future<int> retainOnly(Iterable<String> trackIds) async {
    final keep = {for (final id in trackIds) "$id.thumb"};
    final removed = await _pruneEntries(directory, keep);
    removed.forEach(_forget);
    return removed.length;
  }

  /// Top-level in effect: the closure must not capture the cache.
  static Future<List<String>> _pruneEntries(
    String directory,
    Set<String> keep,
  ) => Isolate.run(() {
    final removed = <String>[];
    try {
      for (final entity in Directory(directory).listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is! File ||
            !(_entryName.hasMatch(name) || _legacyEntryName.hasMatch(name)) ||
            keep.contains(name)) {
          continue;
        }
        try {
          entity.deleteSync();
          removed.add(p.basenameWithoutExtension(name));
        } on FileSystemException catch (error) {
          debugPrint("Could not remove a cached thumbnail: $error");
        }
      }
    } on FileSystemException catch (error) {
      debugPrint("Could not prune cached thumbnails: $error");
    }
    return removed;
  });

  static final _entryName = RegExp(r"^[0-9a-f-]{36}\.thumb$");
  static final _legacyEntryName = RegExp(r"^[0-9a-f]{64}\.thumb$");

  /// Atomically keeps a track's artwork, or records that it has none when
  /// [data] is empty or not an image Melody can show.
  Future<void> store(String trackId, Uint8List data) async {
    final usable = isSupportedImage(data);
    if (!usable && data.isNotEmpty) {
      debugPrint("Artwork of $trackId has an unsupported image format");
    }
    try {
      // Replace even a non-empty entry: an earlier write may be corrupt.
      await atomicWrite(_entryPath(trackId), usable ? data : const []);
      _entries[trackId] = usable;
    } on FileSystemException catch (error) {
      debugPrint("Could not cache thumbnail: $error");
    }
  }
}

bool _startsWith(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

/// JPEG, PNG, GIF, WebP, or BMP within the size limit.
bool isSupportedImage(Uint8List data) {
  if (data.isEmpty || data.length > maxArtworkBytes) return false;
  return _startsWith(data, const [0xff, 0xd8, 0xff]) ||
      _startsWith(data, const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]) ||
      _startsWith(data, ascii.encode("GIF87a")) ||
      _startsWith(data, ascii.encode("GIF89a")) ||
      (data.length >= 12 &&
          _startsWith(data, ascii.encode("RIFF")) &&
          ascii.decode(data.sublist(8, 12), allowInvalid: true) == "WEBP") ||
      _startsWith(data, ascii.encode("BM"));
}
