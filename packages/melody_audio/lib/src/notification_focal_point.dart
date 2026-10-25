import "dart:math" as math;
import "dart:typed_data";
import "dart:ui";

/// Normalized focal point used when no content-based estimate is available.
const Offset centerFocalPoint = Offset(0.5, 0.5);

/// Normalized coordinate in [0, 1], with 0 at the top or left.
double clampFocal(double value) =>
    value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.5;

// Neighbor difference that counts as a visible edge rather than codec noise.
const _noiseFloor = 0.05;
// Fraction of neighbor pairs, and absolute minimum, that must be visible edges
// before artwork counts as having a subject. A count rather than a mean keeps a
// small subject on a plain background from being diluted away.
const _minimumEdgeFraction = 0.001;
const _minimumEdges = 4;
// A border line is letterboxing when every pixel stays this close to the
// outermost line's color.
const _borderTolerance = 0.06;
// Letterbox trimming never removes more than this fraction from one side.
const _maximumBorder = 0.3;
// Fraction of the first line past a uniform border that must differ from it
// for the border to count as a letterbox bar rather than plain backdrop.
const _barCoverage = 0.75;
// Fraction of a line that must match the outermost line's color for the line
// to belong to a letterbox bar.
const _barMatch = 0.7;
// Composition terms for the square crop along the long axis. Each term lies in
// [0, 1]; the weights set what one fault costs against another.
//
// Cutting into the main subject is the worst fault a crop can have.
const _subjectWeight = 3.0;
// Secondary content that fits stays, so the crop keeps its context.
const _contentWeight = 1.0;
// A new crop edge through content looks accidental rather than framed.
const _cutWeight = 1.5;
// The main subject sits on the center or a third line.
const _placementWeight = 1.0;
// Visual weight is spread evenly about the crop center.
const _balanceWeight = 1.0;
// The content has room to breathe instead of pressing against an edge.
const _crowdingWeight = 0.75;
// The original was framed around its center, so ambiguous art stays there.
const _centerWeight = 0.3;
// Lines above this fraction of the peak, contiguous with it, are the subject.
const _subjectThreshold = 0.35;
// Spread of each placement target, as a fraction of the crop side.
const _placementSpread = 0.08;
// A subject on a third line scores this fraction of a centered one. On its own
// it stays centered; balance or context must justify moving it to a third.
const _thirdsPreference = 0.85;
// Depth of the crowding margin along each crop edge, as a fraction of the side.
const _margin = 0.1;
// Saliency runs on cells of this many pixels per side once the shorter content
// side has at least _binningMinimum pixels. The model is region based, so one
// cell of a 128 pixel sample, about 8 pixels of the 512 pixel artwork, loses
// no useful precision and makes every later stage four times cheaper.
const _binning = 2;
const _binningMinimum = 32;
// Alternating raster scans of the minimum barrier distance transform. Three
// passes converge for practically all images (Zhang et al., ICCV 2015).
const _barrierPasses = 3;
// Depth of each border band sampled as background, as a fraction of the
// shorter content side.
const _borderBand = 0.05;
// Variance floor for border color statistics, in squared CIELAB units, so a
// perfectly flat backdrop does not turn codec noise into saliency.
const _varianceFloor = 1.0;

/// Estimates the normalized focal point of RGBA pixels for a square crop.
///
/// This is the pure Dart fallback for platforms without the saliency model
/// (see [focalPointFromSaliency]): a cheap, content-only estimate, not face
/// recognition. Uniform letterbox bars are ignored. The remaining
/// content is smoothed and converted to CIELAB, then scored with the MB+
/// salient object model (Zhang et al., "Minimum Barrier Salient Object
/// Detection at 80 FPS", ICCV 2015):
///
/// * the minimum barrier distance from each pixel to the image border, which
///   marks whole regions that are cut off from the backdrop, and
/// * the color distance from each border's statistics, which keeps a subject
///   that touches one edge salient.
///
/// Both run in a few linear passes. Unlike edge detail, they score the body of
/// a subject rather than its outline and ignore fine texture that reaches the
/// border. Squaring the score favors distinct subjects over diffuse content.
///
/// Saliency only finds what is in the picture. Along the long axis the result
/// is the center of the square crop with the best composition, not the one
/// holding the most salient content (see [_bestWindowCenter]). Along the axis
/// the square covers entirely it is the saliency centroid.
Offset calculateFocalPoint(Uint8List rgba, int width, int height) {
  final content = artworkContent(rgba, width, height);
  if (content == null) return centerFocalPoint;
  final (left, top, right, bottom) = content;
  final (weights, cells, factor) = _saliency(
    rgba,
    width,
    left,
    top,
    right,
    bottom,
  );
  final rows = List<double>.filled(height, 0);
  final columns = List<double>.filled(width, 0);
  var total = 0.0;
  for (var i = 0; i < weights.length; i++) {
    final x0 = left + i % cells * factor;
    final y0 = top + i ~/ cells * factor;
    final x1 = math.min(x0 + factor, right);
    final y1 = math.min(y0 + factor, bottom);
    // Every pixel of a cell carries the cell's weight.
    final weight = weights[i];
    for (var y = y0; y < y1; y++) {
      rows[y] += weight * (x1 - x0);
    }
    for (var x = x0; x < x1; x++) {
      columns[x] += weight * (y1 - y0);
    }
    total += weight * (x1 - x0) * (y1 - y0);
  }
  if (!total.isFinite || total <= 0) return centerFocalPoint;
  return _focalPointWithin(rows, columns, width, height, content);
}

/// Artwork content without letterbox bars as (left, top, right, bottom), or
/// null when there is no visible detail to focus on.
(int, int, int, int)? artworkContent(Uint8List rgba, int width, int height) {
  if (width < 2 || height < 2 || rgba.length < width * height * 4) {
    return null;
  }
  final content = _contentBounds(rgba, width, height);
  final (left, top, right, bottom) = content;
  // Judge detail inside the content only: letterbox edges are not a subject.
  return _hasDetail(rgba, width, left, top, right, bottom) ? content : null;
}

/// Focal point of a [width] by [height] image from a model saliency map.
///
/// The row-major [saliency] map has [size] by [size] values and covers the
/// [content] rectangle, stretched to a square. The crop is chosen exactly as
/// for [calculateFocalPoint].
Offset focalPointFromSaliency(
  Float32List saliency,
  int size,
  int width,
  int height,
  (int, int, int, int) content,
) {
  final (left, top, right, bottom) = content;
  if (size < 1 ||
      saliency.length < size * size ||
      left >= right ||
      top >= bottom ||
      right > width ||
      bottom > height) {
    return centerFocalPoint;
  }
  // Only relative saliency matters, so the weakest response is the baseline.
  var lowest = double.infinity;
  for (var i = 0; i < size * size; i++) {
    if (saliency[i] < lowest) lowest = saliency[i];
  }
  final mapColumns = Float64List(size);
  final mapRows = Float64List(size);
  var total = 0.0;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final value = saliency[y * size + x] - lowest;
      mapColumns[x] += value;
      mapRows[y] += value;
      total += value;
    }
  }
  if (!total.isFinite || total <= 0) return centerFocalPoint;
  final rows = List<double>.filled(height, 0);
  final columns = List<double>.filled(width, 0);
  for (var x = left; x < right; x++) {
    columns[x] = mapColumns[_mapIndex(x - left, right - left, size)];
  }
  for (var y = top; y < bottom; y++) {
    rows[y] = mapRows[_mapIndex(y - top, bottom - top, size)];
  }
  return _focalPointWithin(rows, columns, width, height, content);
}

/// Map cell under the center of pixel [i] of [length] stretched to [size].
int _mapIndex(int i, int length, int size) =>
    math.min(((i + 0.5) * size / length).floor(), size - 1);

/// Focal point of a [width] by [height] image whose crop stays inside the
/// [content] rectangle, so letterbox bars never fill part of the square.
Offset _focalPointWithin(
  List<double> rows,
  List<double> columns,
  int width,
  int height,
  (int, int, int, int) content,
) {
  final (left, top, right, bottom) = content;
  final w = right - left;
  final h = bottom - top;
  final local = _focalPoint(
    rows.sublist(top, bottom),
    columns.sublist(left, right),
    w,
    h,
  );
  return Offset(
    clampFocal((left + local.dx * w) / width),
    clampFocal((top + local.dy * h) / height),
  );
}

Offset _focalPoint(
  List<double> rows,
  List<double> columns,
  int width,
  int height,
) {
  if (width > height) {
    return Offset(_bestWindowCenter(columns, height), _centroid(rows));
  }
  if (height > width) {
    return Offset(_centroid(columns), _bestWindowCenter(rows, width));
  }
  return Offset(_centroid(columns), _centroid(rows));
}

bool _hasDetail(
  Uint8List rgba,
  int width,
  int left,
  int top,
  int right,
  int bottom,
) {
  var edges = 0;
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final pixel = (y * width + x) * 4;
      if (x + 1 < right && _difference(rgba, pixel, pixel + 4) > _noiseFloor) {
        edges++;
      }
      if (y + 1 < bottom &&
          _difference(rgba, pixel, pixel + width * 4) > _noiseFloor) {
        edges++;
      }
    }
  }
  final w = right - left;
  final h = bottom - top;
  final comparisons = (w - 1) * h + w * (h - 1);
  return edges >= math.max(_minimumEdges, comparisons * _minimumEdgeFraction);
}

/// Content rectangle as (left, top, right, bottom) without uniform bars.
(int, int, int, int) _contentBounds(Uint8List rgba, int width, int height) {
  final maxRows = (height * _maximumBorder).floor();
  final maxColumns = (width * _maximumBorder).floor();
  int trim(int limit, int length, int Function(int line, int i) pixelAt) {
    final reference = pixelAt(0, 0);
    int differing(int line) {
      var count = 0;
      for (var i = 0; i < length; i++) {
        if (_difference(rgba, reference, pixelAt(line, i)) > _borderTolerance) {
          count++;
        }
      }
      return count;
    }

    for (var line = 0; line < limit; line++) {
      final count = differing(line);
      // Channel logos often sit inside a bar without ending it.
      if (count <= length * (1 - _barMatch)) continue;
      // A bar ends where the picture begins across most of the line. A plain
      // backdrop ends where a subject begins, and trimming it would press the
      // subject against the content border. Downsampling can blend the bar
      // into the first picture line, so the next line also counts.
      final edge = math.max(count, differing(line + 1));
      return edge >= length * _barCoverage ? line : 0;
    }
    // Bars wider than the limit are rare; this is a plain backdrop.
    return 0;
  }

  final top = trim(maxRows, width, (y, x) => (y * width + x) * 4);
  final bottom =
      height -
      trim(maxRows, width, (y, x) => ((height - 1 - y) * width + x) * 4);
  final left = trim(maxColumns, height, (x, y) => (y * width + x) * 4);
  final right =
      width -
      trim(maxColumns, height, (x, y) => (y * width + width - 1 - x) * 4);
  return (left, top, right, bottom);
}

/// Saliency for the content rectangle on a grid of square cells.
///
/// Returns the row-major cell weights, the number of cells per row, and the
/// cell side in pixels.
(Float64List, int, int) _saliency(
  Uint8List rgba,
  int width,
  int left,
  int top,
  int right,
  int bottom,
) {
  final factor = math.min(right - left, bottom - top) >= _binningMinimum
      ? _binning
      : 1;
  final w = (right - left + factor - 1) ~/ factor;
  final h = (bottom - top + factor - 1) ~/ factor;
  final count = w * h;
  final lab = _smoothedLab(rgba, width, left, top, right, bottom, factor);
  final barrier = Float64List(count);
  for (final channel in lab) {
    final distance = _minimumBarrierDistance(channel, w, h);
    for (var i = 0; i < count; i++) {
      barrier[i] += distance[i];
    }
  }
  final background = _borderDissimilarity(lab, w, h);
  _normalize(barrier);
  _normalize(background);
  final weights = Float64List(count);
  for (var i = 0; i < count; i++) {
    final score = barrier[i] + background[i];
    weights[i] = score * score;
  }
  return (weights, w, factor);
}

/// sRGB byte to linear light.
final Float64List _linearSrgb = () {
  final table = Float64List(256);
  for (var i = 0; i < 256; i++) {
    final c = i / 255;
    table[i] = c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }
  return table;
}();

const _labCurveSteps = 4096;

/// CIELAB companding curve sampled on [0, 1]. Linear interpolation between
/// samples stays within 1e-5 of the exact cube root, far below one L* unit.
final Float64List _labCurveTable = () {
  final table = Float64List(_labCurveSteps + 1);
  for (var i = 0; i <= _labCurveSteps; i++) {
    final t = i / _labCurveSteps;
    table[i] = t > 216 / 24389
        ? math.pow(t, 1 / 3).toDouble()
        : (24389 / 27 * t + 16) / 116;
  }
  return table;
}();

double _labCurve(double t) {
  if (t <= 0) return _labCurveTable[0];
  if (t >= 1) return _labCurveTable[_labCurveSteps];
  final position = t * _labCurveSteps;
  final index = position.toInt();
  final fraction = position - index;
  return _labCurveTable[index] +
      (_labCurveTable[index + 1] - _labCurveTable[index]) * fraction;
}

/// CIELAB (D65) channels of the content rectangle on a grid of square cells.
///
/// Each cell averages its pixels in linear light, then a 3x3 box blur over
/// the cells suppresses codec noise and fine texture.
List<Float64List> _smoothedLab(
  Uint8List rgba,
  int width,
  int left,
  int top,
  int right,
  int bottom,
  int factor,
) {
  final w = (right - left + factor - 1) ~/ factor;
  final h = (bottom - top + factor - 1) ~/ factor;
  final count = w * h;
  final red = Float64List(count);
  final green = Float64List(count);
  final blue = Float64List(count);
  final samples = Int32List(count);
  for (var y = top; y < bottom; y++) {
    final row = (y - top) ~/ factor * w;
    var pixel = (y * width + left) * 4;
    for (var x = left; x < right; x++, pixel += 4) {
      final cell = row + (x - left) ~/ factor;
      red[cell] += _linearSrgb[rgba[pixel]];
      green[cell] += _linearSrgb[rgba[pixel + 1]];
      blue[cell] += _linearSrgb[rgba[pixel + 2]];
      samples[cell]++;
    }
  }
  final lightness = Float64List(count);
  final greenRed = Float64List(count);
  final blueYellow = Float64List(count);
  for (var i = 0; i < count; i++) {
    final scale = 1 / samples[i];
    final r = red[i] * scale;
    final g = green[i] * scale;
    final b = blue[i] * scale;
    final fx = _labCurve(
      (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047,
    );
    final fy = _labCurve(0.2126729 * r + 0.7151522 * g + 0.0721750 * b);
    final fz = _labCurve(
      (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883,
    );
    lightness[i] = 116 * fy - 16;
    greenRed[i] = 500 * (fx - fy);
    blueYellow[i] = 200 * (fy - fz);
  }
  return [
    for (final channel in [lightness, greenRed, blueYellow])
      _boxBlur(channel, w, h),
  ];
}

/// Separable 3x3 mean that averages only the neighbors inside the image.
Float64List _boxBlur(Float64List source, int w, int h) {
  final horizontal = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var sum = source[row + x];
      var samples = 1;
      if (x > 0) {
        sum += source[row + x - 1];
        samples++;
      }
      if (x + 1 < w) {
        sum += source[row + x + 1];
        samples++;
      }
      horizontal[row + x] = sum / samples;
    }
  }
  final result = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      var sum = horizontal[i];
      var samples = 1;
      if (y > 0) {
        sum += horizontal[i - w];
        samples++;
      }
      if (y + 1 < h) {
        sum += horizontal[i + w];
        samples++;
      }
      result[i] = sum / samples;
    }
  }
  return result;
}

/// Minimum barrier distance from each pixel to the image border.
///
/// The barrier of a path is the highest minus the lowest value along it, so a
/// region reachable from the border without crossing a strong change stays
/// near zero however large or textured it is. This is the FastMBD raster scan
/// approximation, linear in the pixel count.
Float64List _minimumBarrierDistance(Float64List image, int w, int h) {
  final count = w * h;
  final distance = Float64List(count)..fillRange(0, count, double.infinity);
  final highest = Float64List.fromList(image);
  final lowest = Float64List.fromList(image);
  for (var x = 0; x < w; x++) {
    distance[x] = 0;
    distance[count - w + x] = 0;
  }
  for (var y = 0; y < h; y++) {
    distance[y * w] = 0;
    distance[y * w + w - 1] = 0;
  }
  // Border pixels are seeds and never change, so the scans cover the interior.
  // Forward passes look up and left, backward passes down and right.
  for (var pass = 0; pass < _barrierPasses; pass++) {
    final forward = pass.isEven;
    final vertical = forward ? -w : w;
    final horizontal = forward ? -1 : 1;
    for (var row = 1; row < h - 1; row++) {
      final y = forward ? row : h - 1 - row;
      for (var column = 1; column < w - 1; column++) {
        final i = y * w + (forward ? column : w - 1 - column);
        final value = image[i];
        var best = distance[i];
        var j = i + vertical;
        var high = highest[j] > value ? highest[j] : value;
        var low = lowest[j] < value ? lowest[j] : value;
        if (high - low < best) {
          best = high - low;
          highest[i] = high;
          lowest[i] = low;
        }
        j = i + horizontal;
        high = highest[j] > value ? highest[j] : value;
        low = lowest[j] < value ? lowest[j] : value;
        if (high - low < best) {
          best = high - low;
          highest[i] = high;
          lowest[i] = low;
        }
        distance[i] = best;
      }
    }
  }
  return distance;
}

/// Color distance from the backdrop seen along the four content borders.
///
/// Each border band is summarized by its per-channel mean and variance. The
/// most dissimilar border is dropped for every pixel, so a subject touching
/// one edge still differs from the other three.
Float64List _borderDissimilarity(List<Float64List> lab, int w, int h) {
  final count = w * h;
  final band = math.max(1, (math.min(w, h) * _borderBand).round());
  final sum = Float64List(count);
  final highest = Float64List(count);
  final side = Float64List(count);
  final mean = Float64List(3);
  final inverseVariance = Float64List(3);
  for (final (x0, y0, x1, y1) in [
    (0, 0, w, band),
    (0, h - band, w, h),
    (0, 0, band, h),
    (w - band, 0, w, h),
  ]) {
    final samples = (x1 - x0) * (y1 - y0);
    for (var c = 0; c < 3; c++) {
      final channel = lab[c];
      var total = 0.0, squares = 0.0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final value = channel[y * w + x];
          total += value;
          squares += value * value;
        }
      }
      mean[c] = total / samples;
      final variance = squares / samples - mean[c] * mean[c];
      inverseVariance[c] = 1 / (math.max(variance, 0.0) + _varianceFloor);
    }
    final (l, a, b) = (lab[0], lab[1], lab[2]);
    final (meanL, meanA, meanB) = (mean[0], mean[1], mean[2]);
    final (weightL, weightA, weightB) = (
      inverseVariance[0],
      inverseVariance[1],
      inverseVariance[2],
    );
    var maximum = 0.0;
    for (var i = 0; i < count; i++) {
      final dl = l[i] - meanL, da = a[i] - meanA, db = b[i] - meanB;
      final distance = math.sqrt(
        dl * dl * weightL + da * da * weightA + db * db * weightB,
      );
      side[i] = distance;
      if (distance > maximum) maximum = distance;
    }
    if (maximum <= 0) continue;
    for (var i = 0; i < count; i++) {
      final value = side[i] / maximum;
      sum[i] += value;
      if (value > highest[i]) highest[i] = value;
    }
  }
  for (var i = 0; i < count; i++) {
    sum[i] -= highest[i];
  }
  return sum;
}

/// Scales values in place so the largest is 1.
void _normalize(Float64List values) {
  var maximum = 0.0;
  for (final value in values) {
    if (value > maximum) maximum = value;
  }
  if (!maximum.isFinite || maximum <= 0) return;
  for (var i = 0; i < values.length; i++) {
    values[i] /= maximum;
  }
}

/// Normalized center of the best composed square window along one axis.
///
/// The main subject is the contiguous run of the saliency [profile] around
/// its peak. Every window position is scored as a photographer would judge
/// the framing:
///
/// * the main subject is kept whole, along with any secondary content that
///   fits;
/// * new crop edges fall between objects, not through them, while an edge
///   that matches the original frame cuts nothing new;
/// * the subject sits on the center or a third line, the visual weight is
///   balanced about the crop center, and nothing presses against an edge;
/// * with nothing else to choose between windows, the original center wins.
double _bestWindowCenter(List<double> profile, int side) {
  final length = profile.length;
  final maxStart = length - side;
  var peak = 0.0;
  var peakIndex = 0;
  for (var i = 0; i < length; i++) {
    if (profile[i] > peak) {
      peak = profile[i];
      peakIndex = i;
    }
  }
  if (!(peak > 0) || maxStart <= 0) return 0.5;

  final floor = peak * _subjectThreshold;
  var subjectStart = peakIndex;
  var subjectEnd = peakIndex + 1;
  while (subjectStart > 0 && profile[subjectStart - 1] >= floor) {
    subjectStart--;
  }
  while (subjectEnd < length && profile[subjectEnd] >= floor) {
    subjectEnd++;
  }
  final subject = Float64List(length);
  for (var i = subjectStart; i < subjectEnd; i++) {
    subject[i] = profile[i];
  }
  final (mass, moment) = _prefixSums(profile);
  final (subjectMass, subjectMoment) = _prefixSums(subject);
  final total = mass[length];
  final subjectTotal = subjectMass[length];
  final margin = math.max(1, (side * _margin).round());
  final middle = maxStart / 2;

  double placement(double position) {
    double near(double target) {
      final distance = (position - target) / _placementSpread;
      return math.exp(-distance * distance / 2);
    }

    return math.max(
      near(0.5),
      _thirdsPreference * math.max(near(1 / 3), near(2 / 3)),
    );
  }

  // Content on both sides of a new edge is sliced; an edge along an object's
  // outline is not.
  double cut(int edge) => edge <= 0 || edge >= length
      ? 0
      : math.min(profile[edge - 1], profile[edge]) / peak;

  var bestStart = 0;
  var bestScore = double.negativeInfinity;
  for (var start = 0; start <= maxStart; start++) {
    final end = start + side;
    final inside = mass[end] - mass[start];
    final subjectInside = subjectMass[end] - subjectMass[start];
    var score =
        _subjectWeight * subjectInside / subjectTotal +
        _contentWeight * inside / total -
        _cutWeight * math.max(cut(start), cut(end));
    if (subjectInside > 0) {
      final center =
          (subjectMoment[end] - subjectMoment[start]) / subjectInside;
      score += _placementWeight * placement((center - start) / side);
    }
    if (inside > 0) {
      final center = (moment[end] - moment[start]) / inside;
      final balance = 1 - 2 * ((center - start) / side - 0.5).abs();
      final edges =
          mass[start + margin] - mass[start] + mass[end] - mass[end - margin];
      score += _balanceWeight * balance - _crowdingWeight * edges / inside;
    }
    final offset = (start - middle).abs() / middle;
    score += _centerWeight * (1 - offset * offset);
    if (score > bestScore ||
        (score == bestScore &&
            (start - middle).abs() < (bestStart - middle).abs())) {
      bestScore = score;
      bestStart = start;
    }
  }
  return clampFocal((bestStart + side / 2) / length);
}

/// Prefix sums of [values] and of their first moments about each line center.
(Float64List, Float64List) _prefixSums(List<double> values) {
  final sums = Float64List(values.length + 1);
  final moments = Float64List(values.length + 1);
  for (var i = 0; i < values.length; i++) {
    sums[i + 1] = sums[i] + values[i];
    moments[i + 1] = moments[i] + (i + 0.5) * values[i];
  }
  return (sums, moments);
}

double _centroid(List<double> profile) {
  var weighted = 0.0, total = 0.0;
  for (var i = 0; i < profile.length; i++) {
    weighted += (i + 0.5) * profile[i];
    total += profile[i];
  }
  if (!(total > 0)) return 0.5;
  return clampFocal(weighted / total / profile.length);
}

double _difference(Uint8List rgba, int first, int second) {
  return ((rgba[first] - rgba[second]).abs() +
          (rgba[first + 1] - rgba[second + 1]).abs() +
          (rgba[first + 2] - rgba[second + 2]).abs()) /
      765.0;
}

/// Source rectangle for an aspect-preserving square cover crop.
///
/// The square stays inside [content], the picture without letterbox bars in
/// image pixels, or inside the whole image when it is null.
Rect focalCropRect(int width, int height, Offset focalPoint, {Rect? content}) {
  if (width <= 0 || height <= 0) return Rect.zero;
  final image = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final bounds = content == null || content.isEmpty
      ? image
      : content.intersect(image);
  final side = math.min(bounds.width, bounds.height);
  // The focal point identifies a point in the original image. Keep it at the
  // center of the crop whenever the bounds allow it.
  final left = (clampFocal(focalPoint.dx) * width - side / 2)
      .clamp(bounds.left, bounds.right - side)
      .toDouble();
  final top = (clampFocal(focalPoint.dy) * height - side / 2)
      .clamp(bounds.top, bounds.bottom - side)
      .toDouble();
  return Rect.fromLTWH(left, top, side, side);
}
