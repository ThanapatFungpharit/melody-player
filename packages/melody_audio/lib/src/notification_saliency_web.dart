import "dart:typed_data";

import "notification_saliency.dart";

/// TensorFlow Lite has no web runtime; callers fall back to the Dart detector.
SaliencyModel createSaliencyModel() => const _UnavailableSaliencyModel();

class _UnavailableSaliencyModel implements SaliencyModel {
  const _UnavailableSaliencyModel();

  @override
  Future<Float32List?> predict(Uint8List rgba) async => null;
}
