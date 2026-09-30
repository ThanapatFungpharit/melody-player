import "dart:ui" as ui;

import "notification_artwork_web.dart"
    if (dart.library.io) "notification_artwork_io.dart"
    as artwork_io;
import "notification_focal_point.dart";

/// Prepares square media-session art in Flutter before the OS renders its panel.
class NotificationArtwork {
  final Map<String, Future<String>> _cache = {};

  Future<String> prepare(String source, {required bool automatic}) async {
    if (source.isEmpty) return source;
    String? key;
    try {
      final uri = Uri.parse(source);
      final version = await artwork_io.artworkVersion(uri);
      final cacheKey = "$version:${automatic ? 'auto' : 'center'}";
      key = cacheKey;
      if (!_cache.containsKey(cacheKey) && _cache.length >= 64) {
        _cache.remove(_cache.keys.first);
      }
      final prepared = await _cache.putIfAbsent(
        cacheKey,
        () => _prepare(uri, source, cacheKey, automatic),
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

  Future<String> _prepare(
    Uri uri,
    String source,
    String key,
    bool automatic,
  ) async {
    final bytes = await artwork_io.readNotificationArtwork(uri);
    if (bytes == null || bytes.isEmpty) return source;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? sampleCodec;
    ui.Codec? renderCodec;
    ui.Image? sample;
    ui.Image? full;
    ui.Image? cropped;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 || descriptor.height < 1) return source;
      var focalY = 0.5;
      if (automatic) {
        final scale =
            128 /
            (descriptor.width > descriptor.height
                ? descriptor.width
                : descriptor.height);
        sampleCodec = await descriptor.instantiateCodec(
          targetWidth: (descriptor.width * scale).round().clamp(1, 128),
          targetHeight: (descriptor.height * scale).round().clamp(1, 128),
        );
        sample = (await sampleCodec.getNextFrame()).image;
        final pixels = await sample.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels != null) {
          focalY = calculateFocalY(
            pixels.buffer.asUint8List(),
            sample.width,
            sample.height,
          );
        }
      }
      final renderScale =
          512 /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      renderCodec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * renderScale).round().clamp(1, 512),
        targetHeight: (descriptor.height * renderScale).round().clamp(1, 512),
      );
      full = (await renderCodec.getNextFrame()).image;
      final rectangle = focalCropRect(full.width, full.height, focalY);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        full,
        rectangle,
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
      // The cache key changes when local artwork content or mode changes.
      final name = _stableHash(key);
      return (await artwork_io.saveNotificationArtwork(
            png.buffer.asUint8List(),
            name,
          )) ??
          source;
    } finally {
      cropped?.dispose();
      full?.dispose();
      sample?.dispose();
      renderCodec?.dispose();
      sampleCodec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final code in value.codeUnits) {
    hash = ((hash ^ code) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}
