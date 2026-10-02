import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/storage.dart";

const _maxThumbnailBytes = 8 * 1024 * 1024;

/// Durable, offline-first thumbnail storage keyed by remote URL.
///
/// The authoritative artwork is embedded in each downloaded media file. This
/// cache holds a copy derived from those verified bytes so the UI and the
/// system media session can show artwork without the network.
class ThumbnailCache {
  ThumbnailCache(this.directory) {
    Directory(directory).createSync(recursive: true);
  }

  final String directory;

  static String? _key(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase();
    if ((scheme != "http" && scheme != "https") || (uri?.host ?? "").isEmpty) {
      return null;
    }
    return sha256.convert(utf8.encode(trimmed)).toString();
  }

  /// The durable entry for a remote URL, without touching the network.
  String? cachedPath(String url) {
    final key = _key(url);
    if (key == null) return null;
    final file = File(p.join(directory, "$key.thumb"));
    try {
      final status = file.statSync();
      return status.type == FileSystemEntityType.file && status.size > 0
          ? file.path
          : null;
    } on FileSystemException {
      return null;
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
    return path != null ? Uri.file(File(path).absolute.path).toString() : source;
  }

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
      await atomicWrite(p.join(directory, "$key.thumb"), data);
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
  if (data.isEmpty || data.length > _maxThumbnailBytes) return false;
  return _startsWith(data, const [0xff, 0xd8, 0xff]) ||
      _startsWith(data, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ||
      _startsWith(data, ascii.encode("GIF87a")) ||
      _startsWith(data, ascii.encode("GIF89a")) ||
      (data.length >= 12 &&
          _startsWith(data, ascii.encode("RIFF")) &&
          ascii.decode(data.sublist(8, 12), allowInvalid: true) == "WEBP") ||
      _startsWith(data, ascii.encode("BM"));
}
