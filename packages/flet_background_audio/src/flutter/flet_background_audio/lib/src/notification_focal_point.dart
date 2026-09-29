import "dart:math" as math;
import "dart:typed_data";
import "dart:ui";

/// Normalized vertical point in [0, 1], with 0 at the top.
double clampFocalY(double value) =>
    value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.5;

/// Finds the vertical center of local color changes in a downsampled RGBA image.
double calculateFocalY(Uint8List rgba, int width, int height) {
  if (width < 1 || height < 2 || rgba.length < width * height * 4) {
    return 0.5;
  }
  var weightedRows = 0.0;
  var totalWeight = 0.0;
  for (var y = 0; y < height; y++) {
    var rowDifference = 0.0;
    var comparisons = 0;
    for (var x = 0; x < width; x++) {
      final pixel = (y * width + x) * 4;
      if (x + 1 < width) {
        rowDifference += _difference(rgba, pixel, pixel + 4);
        comparisons++;
      }
      if (y + 1 < height) {
        rowDifference += _difference(rgba, pixel, pixel + width * 4);
        comparisons++;
      }
    }
    final weight = comparisons == 0 ? 0.0 : rowDifference / comparisons;
    weightedRows += y * weight;
    totalWeight += weight;
  }
  // Ignore tiny codec noise and near-uniform artwork.
  if (!totalWeight.isFinite || totalWeight < height * 0.004) return 0.5;
  return clampFocalY(weightedRows / totalWeight / (height - 1));
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
  final top = (height - side) * clampFocalY(focalY);
  return Rect.fromLTWH(left, top, side, side);
}
