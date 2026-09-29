import "dart:math" as math;
import "dart:typed_data";
import "dart:ui";

/// Normalized vertical point in [0, 1], with 0 at the top.
double clampFocalY(double value) =>
    value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.5;

/// Finds the center of the most visually detailed square crop in RGBA pixels.
///
/// This is a cheap, content-only saliency estimate for notification artwork,
/// not face recognition. It scores edge and color detail by row, then selects
/// the square crop that retains the most detail. Center wins ties so ordinary
/// covers remain stable.
double calculateFocalY(Uint8List rgba, int width, int height) {
  if (width < 1 || height < 2 || rgba.length < width * height * 4) {
    return 0.5;
  }
  final rowWeights = List<double>.filled(height, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pixel = (y * width + x) * 4;
      if (x + 1 < width) {
        rowWeights[y] += _difference(rgba, pixel, pixel + 4);
      }
      if (y + 1 < height) {
        rowWeights[y] += _difference(rgba, pixel, pixel + width * 4);
      }
    }
  }
  final totalWeight = rowWeights.fold<double>(0, (sum, value) => sum + value);
  // Ignore codec noise and near-uniform artwork.
  if (!totalWeight.isFinite || totalWeight < height * 0.004) return 0.5;
  var weightedRows = 0.0;
  for (var y = 0; y < height; y++) {
    weightedRows += y * rowWeights[y];
  }

  // The source will be cropped to a square. Find the vertical window that
  // captures the most detail rather than aiming at a centroid that may still
  // leave the important region near the edge of the crop.
  final cropHeight = math.min(width, height);
  if (cropHeight >= height) {
    return clampFocalY(weightedRows / totalWeight / (height - 1));
  }
  final prefix = List<double>.filled(height + 1, 0);
  for (var y = 0; y < height; y++) {
    prefix[y + 1] = prefix[y] + rowWeights[y];
  }
  final maxTop = height - cropHeight;
  var bestTop = 0;
  var bestWeight = -1.0;
  for (var top = 0; top <= maxTop; top++) {
    final weight = prefix[top + cropHeight] - prefix[top];
    final centerDistance = (top + cropHeight / 2 - height / 2).abs();
    final bestCenterDistance = (bestTop + cropHeight / 2 - height / 2).abs();
    if (weight > bestWeight ||
        (weight == bestWeight && centerDistance < bestCenterDistance)) {
      bestWeight = weight;
      bestTop = top;
    }
  }
  return clampFocalY((bestTop + cropHeight / 2) / height);
}

double _difference(Uint8List rgba, int first, int second) {
  return ((rgba[first] - rgba[second]).abs() +
          (rgba[first + 1] - rgba[second + 1]).abs() +
          (rgba[first + 2] - rgba[second + 2]).abs()) /
      765.0;
}

/// Source rectangle for an aspect-preserving square cover crop.
Rect focalCropRect(int width, int height, double focalY) {
  if (width <= 0 || height <= 0) return Rect.zero;
  final side = math.min(width, height).toDouble();
  final left = (width - side) / 2;
  // The focal value identifies a point in the original image. Keep that point
  // at the center of the crop whenever the image bounds allow it.
  final top = (clampFocalY(focalY) * height - side / 2)
      .clamp(0.0, height - side)
      .toDouble();
  return Rect.fromLTWH(left, top, side, side);
}
