import "dart:math" as math;
import "dart:ui" as ui;

import "notification_artwork_web.dart"
    if (dart.library.io) "notification_artwork_io.dart"
    as artwork_io;

/// Keeps prepared media-session artwork in [path] (the app's cache folder,
/// bounded to the 64 most recently used images) instead of the system's
/// temporary folder. Call it before the media session starts.
void useNotificationArtworkDirectory(String path) =>
    artwork_io.useNotificationArtworkDirectory(path);

/// Prepares square media-session art in Flutter before the OS renders its panel.
class NotificationArtwork {
  final Map<String, Future<String>> _cache = {};

  Future<String> prepare(String source) async {
    if (source.isEmpty) return source;
    String? key;
    try {
      final uri = Uri.parse(source);
      final cacheKey = await artwork_io.artworkVersion(uri);
      key = cacheKey;
      if (!_cache.containsKey(cacheKey) && _cache.length >= 64) {
        _cache.remove(_cache.keys.first);
      }
      final prepared = await _cache.putIfAbsent(
        cacheKey,
        () => _prepare(uri, source, cacheKey),
      );
      if (prepared == source ||
          !await artwork_io.preparedArtworkExists(prepared)) {
        _cache.remove(cacheKey);
        return source;
      }
      return prepared;
    } catch (_) {
      // A transient image or network error should be retried on the next sync.
      if (key != null) _cache.remove(key);
      return source;
    }
  }

  Future<String> _prepare(Uri uri, String source, String key) async {
    // The key changes when local artwork content changes, so artwork prepared
    // before a restart can be reused without decoding.
    final name = _stableHash(key);
    final existing = await artwork_io.existingNotificationArtwork(name);
    if (existing != null) return existing;
    final bytes = await artwork_io.readNotificationArtwork(uri);
    if (bytes == null || bytes.isEmpty) return source;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? renderCodec;
    ui.Image? full;
    ui.Image? cropped;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 || descriptor.height < 1) return source;
      renderCodec = await _codec(descriptor, 512);
      full = (await renderCodec.getNextFrame()).image;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        full,
        centerSquare(full.width, full.height),
        const ui.Rect.fromLTWH(0, 0, 512, 512),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();
      try {
        cropped = await picture.toImage(512, 512);
      } finally {
        picture.dispose();
      }
      final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return source;
      return (await artwork_io.saveNotificationArtwork(
            png.buffer.asUint8List(),
            name,
          )) ??
          source;
    } finally {
      cropped?.dispose();
      full?.dispose();
      renderCodec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

/// The centered square of an image, the source of the media-session art.
ui.Rect centerSquare(int width, int height) {
  final side = math.min(width, height).toDouble();
  return ui.Rect.fromLTWH((width - side) / 2, (height - side) / 2, side, side);
}

/// Codec that decodes [descriptor] with its longer side at most [side].
Future<ui.Codec> _codec(ui.ImageDescriptor descriptor, int side) {
  final scale =
      side /
      (descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height);
  return descriptor.instantiateCodec(
    targetWidth: (descriptor.width * scale).round().clamp(1, side),
    targetHeight: (descriptor.height * scale).round().clamp(1, side),
  );
}

String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final code in value.codeUnits) {
    hash = ((hash ^ code) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}
