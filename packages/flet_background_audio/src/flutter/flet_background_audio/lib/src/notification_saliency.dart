import "dart:typed_data";

import "notification_saliency_web.dart"
    if (dart.library.io) "notification_saliency_io.dart"
    as platform;

/// Side of the square model input and output, in pixels.
const saliencyModelSize = 256;

/// Salient object detector for notification artwork.
abstract interface class SaliencyModel {
  /// Saliency in [0, 1] for square RGBA pixels of side [saliencyModelSize],
  /// row-major, or null when no model runs on this platform.
  Future<Float32List?> predict(Uint8List rgba);
}

/// U²-Netp (Qin et al., "U²-Net: Going Deeper with Nested U-Structure for
/// Salient Object Detection", Pattern Recognition 2020) through TensorFlow
/// Lite where the native runtime is available.
SaliencyModel createSaliencyModel() => platform.createSaliencyModel();

// ImageNet statistics the model was trained with.
const _mean = [0.485, 0.456, 0.406];
const _deviation = [0.229, 0.224, 0.225];

/// Model input for RGBA pixels: RGB scaled by the brightest channel value,
/// then normalized per channel, in NHWC order.
Float32List saliencyInput(Uint8List rgba) {
  final count = rgba.length ~/ 4;
  var maximum = 0;
  for (var i = 0; i < count * 4; i += 4) {
    for (var c = 0; c < 3; c++) {
      if (rgba[i + c] > maximum) maximum = rgba[i + c];
    }
  }
  final scale = maximum > 0 ? 1 / maximum : 0.0;
  final input = Float32List(count * 3);
  for (var i = 0; i < count; i++) {
    for (var c = 0; c < 3; c++) {
      input[i * 3 + c] = (rgba[i * 4 + c] * scale - _mean[c]) / _deviation[c];
    }
  }
  return input;
}
