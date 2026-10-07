import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/artwork.dart" show maxArtworkBytes;
import "../core/storage.dart";

/// Durable, offline-first thumbnail storage keyed by remote URL.
///
/// The authoritative artwork is embedded in each downloaded media file. This
/// cache holds a copy derived from those verified bytes so the UI and the
/// system media session can show artwork without the network.
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
      final keys = await Isolate.run(() => _scanEntries(directory));
      for (final key in keys) {
        // An answer recorded while the scan ran is newer.
        cache._present.putIfAbsent(key, () => true);
      }
      cache._indexed = true;
    } on FileSystemException catch (error) {
      debugPrint("Could not index cached thumbnails: $error");
    }
    return cache;
  }

  final String directory;

  /// Whether each entry exists. Only this object writes the directory, so an
  /// answer stays valid until it changes that entry. Once [_indexed], a key
  /// missing here has no entry; before that, a lookup asks the disk once and
  /// remembers the answer.
  final Map<String, bool> _present = {};
  bool _indexed = false;

  /// Entry keys by URL. Artwork widgets ask on every build and queue
  /// activation asks for every item, so the hash is remembered. Bounded
  /// because search results add URLs.
  final Map<String, String?> _keys = {};
  static const _maxKeys = 1024;

  static String? _key(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase();
    if ((scheme != "http" && scheme != "https") || (uri?.host ?? "").isEmpty) {
      return null;
    }
    return sha256.convert(utf8.encode(trimmed)).toString();
  }

  String? _keyFor(String url) {
    if (_keys.containsKey(url)) return _keys[url];
    if (_keys.length >= _maxKeys) _keys.clear();
    return _keys[url] = _key(url);
  }

  String _entryPath(String key) => p.join(directory, "$key.thumb");

  /// The durable entry for a remote URL, without touching the network.
  String? cachedPath(String url) {
    final key = _keyFor(url);
    if (key == null) return null;
    final present = _indexed
        ? _present[key] ?? false
        : _present[key] ??= _entryExists(_entryPath(key));
    return present ? _entryPath(key) : null;
  }

  static bool _entryExists(String path) {
    try {
      final status = File(path).statSync();
      return status.type == FileSystemEntityType.file && status.size > 0;
    } on FileSystemException {
      return false;
    }
  }

  static List<String> _scanEntries(String directory) => [
    for (final entity in Directory(directory).listSync(followLinks: false))
      if (entity is File && _entryName.hasMatch(p.basename(entity.path)))
        if (_entryExists(entity.path)) p.basenameWithoutExtension(entity.path),
  ];

  void _forget(String key) {
    if (_indexed) {
      _present.remove(key);
    } else {
      _present[key] = false;
    }
  }

  /// Artwork for an operating-system media session, as a file URI when a
  /// cached or local copy exists.
  String artworkUri(String source) {
    var path = cachedPath(source);
    if (path == null && source.isNotEmpty && _key(source) == null) {
      // Reattached native sessions report local paths.
      if (p.isAbsolute(source) && File(source).existsSync()) path = source;
    }
    return path != null
        ? Uri.file(File(path).absolute.path).toString()
        : source;
  }

  /// Drops the entry for a remote URL. Failures only log.
  Future<void> remove(String url) async {
    final key = _key(url);
    if (key == null) return;
    try {
      await File(_entryPath(key)).delete();
    } on PathNotFoundException {
      // Already gone.
    } on FileSystemException catch (error) {
      debugPrint("Could not remove a cached thumbnail: $error");
    } finally {
      _forget(key);
    }
  }

  /// Deletes cached entries for every URL not in [urls], such as artwork of
  /// a download whose registration reused an existing track. Other files in
  /// the folder are left alone. Returns how many entries were removed.
  Future<int> retainOnly(Iterable<String> urls) async {
    final keep = {
      for (final url in urls)
        if (_key(url) case final key?) "$key.thumb",
    };
    var removed = 0;
    try {
      await for (final entity in Directory(directory).list()) {
        final name = p.basename(entity.path);
        if (entity is! File ||
            !_entryName.hasMatch(name) ||
            keep.contains(name)) {
          continue;
        }
        try {
          await entity.delete();
          removed++;
          _forget(p.basenameWithoutExtension(name));
        } on FileSystemException catch (error) {
          debugPrint("Could not remove a cached thumbnail: $error");
        }
      }
    } on FileSystemException catch (error) {
      debugPrint("Could not prune cached thumbnails: $error");
    }
    return removed;
  }

  static final _entryName = RegExp(r"^[0-9a-f]{64}\.thumb$");

  /// Atomically retains image bytes already downloaded with the media.
  Future<bool> storeBytes(String url, Uint8List data) async {
    final key = _key(url);
    if (key == null || data.isEmpty) return false;
    if (!isSupportedImage(data)) {
      debugPrint("Downloaded thumbnail has an unsupported image format");
      return false;
    }
    try {
      // Replace even a non-empty entry: an earlier write may be corrupt.
      await atomicWrite(_entryPath(key), data);
      _present[key] = true;
      return true;
    } on FileSystemException catch (error) {
      debugPrint("Could not cache thumbnail: $error");
      return false;
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
