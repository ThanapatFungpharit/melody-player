import "dart:ui" as ui;

import "package:flutter/foundation.dart";

import "notification_artwork_web.dart"
    if (dart.library.io) "notification_artwork_io.dart"
    as artwork_io;
import "notification_focal_point.dart";
import "notification_saliency.dart";

/// Keeps prepared media-session artwork in [path] (the app's cache folder,
/// bounded to the 64 most recently used images) instead of the system's
/// temporary folder. Call it before the media session starts.
void useNotificationArtworkDirectory(String path) =>
    artwork_io.useNotificationArtworkDirectory(path);

// Names the automatic crop algorithm in cache keys. Change it whenever crops
// change so artwork prepared by an earlier version is not reused.
const _automaticMode = "auto-u2netp256-int8-composition-3";

/// Prepares square media-session art in Flutter before the OS renders its panel.
class NotificationArtwork {
  NotificationArtwork({SaliencyModel? saliencyModel})
    : _saliencyModel = saliencyModel ?? createSaliencyModel();

  final SaliencyModel _saliencyModel;
  final Map<String, Future<String>> _cache = {};

  Future<String> prepare(String source, {required bool automatic}) async {
    if (source.isEmpty) return source;
    String? key;
    try {
      final uri = Uri.parse(source);
      final version = await artwork_io.artworkVersion(uri);
      final cacheKey = "$version:${automatic ? _automaticMode : 'center'}";
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
    // The key changes when local artwork content, mode or algorithm changes,
    // so artwork prepared before a restart can be reused without decoding.
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
      final (focalPoint, content, reusable) = automatic
          ? await _focalPoint(descriptor, full)
          : (centerFocalPoint, null, true);
      final rectangle = focalCropRect(
        full.width,
        full.height,
        focalPoint,
        content: content,
      );
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
      return (await artwork_io.saveNotificationArtwork(
            png.buffer.asUint8List(),
            // A fallback crop is not reused after a restart, so the model gets
            // another chance once it can run.
            reusable ? name : _stableHash("$key:fallback"),
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

  /// Normalized focal point of the artwork decoded as [full], its picture
  /// without letterbox bars in [full]'s pixels (null for the whole image),
  /// and whether it is the final answer rather than a fallback worth retrying
  /// later.
  Future<(ui.Offset, ui.Rect?, bool)> _focalPoint(
    ui.ImageDescriptor descriptor,
    ui.Image full,
  ) async {
    ui.Codec? sampleCodec;
    ui.Image? sample;
    try {
      // A small sample locates letterbox bars and flat artwork cheaply.
      sampleCodec = await _codec(descriptor, 128);
      sample = (await sampleCodec.getNextFrame()).image;
      final pixels = await sample.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (pixels == null) return (centerFocalPoint, null, false);
      final rgba = pixels.buffer.asUint8List();
      final content = artworkContent(rgba, sample.width, sample.height);
      if (content == null) return (centerFocalPoint, null, true);
      final scaleX = full.width / sample.width;
      final scaleY = full.height / sample.height;
      final picture = ui.Rect.fromLTRB(
        content.$1 * scaleX,
        content.$2 * scaleY,
        content.$3 * scaleX,
        content.$4 * scaleY,
      );
      final saliency = await _modelSaliency(full, sample, content);
      if (saliency != null) {
        final focal = focalPointFromSaliency(
          saliency,
          saliencyModelSize,
          sample.width,
          sample.height,
          content,
        );
        return (focal, picture, true);
      }
      // Pure Dart analysis runs off the UI isolate so it cannot drop frames
      // on slow phones. On the web, compute runs it inline.
      final focal = await compute(_focalPointOf, (
        rgba,
        sample.width,
        sample.height,
      ));
      return (focal, picture, false);
    } finally {
      sample?.dispose();
      sampleCodec?.dispose();
    }
  }

  /// Model saliency for the [content] rectangle of [sample], measured on the
  /// sharper [full] image stretched to the model's square input.
  Future<Float32List?> _modelSaliency(
    ui.Image full,
    ui.Image sample,
    (int, int, int, int) content,
  ) async {
    final (left, top, right, bottom) = content;
    final scaleX = full.width / sample.width;
    final scaleY = full.height / sample.height;
    const side = saliencyModelSize;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      full,
      ui.Rect.fromLTRB(
        left * scaleX,
        top * scaleY,
        right * scaleX,
        bottom * scaleY,
      ),
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    ui.Image? input;
    try {
      input = await picture.toImage(side, side);
      final pixels = await input.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (pixels == null) return null;
      return await _saliencyModel.predict(pixels.buffer.asUint8List());
    } catch (_) {
      // Any model failure leaves the pure Dart detector in charge.
      return null;
    } finally {
      input?.dispose();
      picture.dispose();
    }
  }
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

ui.Offset _focalPointOf((Uint8List, int, int) sample) =>
    calculateFocalPoint(sample.$1, sample.$2, sample.$3);

String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final code in value.codeUnits) {
    hash = ((hash ^ code) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}
