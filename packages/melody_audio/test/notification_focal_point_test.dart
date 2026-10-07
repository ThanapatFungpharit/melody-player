import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/src/notification_artwork.dart";
import "package:melody_audio/src/notification_focal_point.dart";
import "package:melody_audio/src/notification_saliency.dart";

Uint8List pixelsWhere(int width, int height, int Function(int x, int y) gray) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      final color = gray(x, y);
      pixels[index] = color;
      pixels[index + 1] = color;
      pixels[index + 2] = color;
      pixels[index + 3] = 255;
    }
  }
  return pixels;
}

Uint8List salientRow(int width, int height, int row) =>
    pixelsWhere(width, height, (x, y) => y == row && x.isEven ? 255 : 0);

Uint8List salientColumn(int width, int height, int column) =>
    pixelsWhere(width, height, (x, y) => x == column && y.isEven ? 255 : 0);

Future<Uint8List> sourceArt() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  for (var x = 0; x < 20; x++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(x.toDouble(), 0, 1, 16),
      ui.Paint()
        ..color = x.isEven
            ? const ui.Color(0xffff0000)
            : const ui.Color(0xff00ff00),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(20, 60);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

/// Landscape art whose striped red left side draws the Dart detector, while
/// a plain blue block fills the right third.
Future<Uint8List> landscapeArt() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  for (var x = 0; x < 40; x += 2) {
    canvas.drawRect(
      ui.Rect.fromLTWH(x.toDouble(), 0, 1, 20),
      ui.Paint()..color = const ui.Color(0xffff0000),
    );
  }
  canvas.drawRect(
    const ui.Rect.fromLTWH(40, 0, 20, 20),
    ui.Paint()..color = const ui.Color(0xff0000ff),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(60, 20);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

Future<List<int>> centerColor(String uri) async {
  final bytes = await File.fromUri(Uri.parse(uri)).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final index = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  final color = [for (var c = 0; c < 3; c++) pixels!.getUint8(index + c)];
  image.dispose();
  codec.dispose();
  return color;
}

Future<int> centerRed(String uri) async => (await centerColor(uri))[0];

/// Saliency map that is 1 where [salient] holds for a map column, else 0.
Float32List columnMap(bool Function(int x) salient) {
  const size = saliencyModelSize;
  return Float32List.fromList([
    for (var y = 0; y < size; y++)
      for (var x = 0; x < size; x++) salient(x) ? 1.0 : 0.0,
  ]);
}

class FakeModel implements SaliencyModel {
  FakeModel({this.map, this.error});

  final Float32List? map;
  final Object? error;
  final inputs = <Uint8List>[];

  @override
  Future<Float32List?> predict(Uint8List rgba) async {
    inputs.add(rgba);
    if (error != null) throw error!;
    return map;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("portrait detail moves the focal row", () {
    expect(
      calculateFocalPoint(salientRow(20, 60, 5), 20, 60).dy,
      lessThan(0.3),
    );
    expect(
      calculateFocalPoint(salientRow(20, 60, 30), 20, 60).dy,
      inInclusiveRange(0.4, 0.6),
    );
    expect(
      calculateFocalPoint(salientRow(20, 60, 54), 20, 60).dy,
      greaterThan(0.7),
    );
  });

  test("landscape detail moves the focal column", () {
    final left = calculateFocalPoint(salientColumn(60, 20, 5), 60, 20);
    expect(left.dx, lessThan(0.3));
    expect(
      calculateFocalPoint(salientColumn(60, 20, 30), 60, 20).dx,
      inInclusiveRange(0.4, 0.6),
    );
    expect(
      calculateFocalPoint(salientColumn(60, 20, 54), 60, 20).dx,
      greaterThan(0.7),
    );
    final crop = focalCropRect(60, 20, left);
    expect(crop.left <= 5 && crop.right > 5, isTrue);
  });

  test("letterbox bars do not pull the crop toward their edges", () {
    // A black pillarbox bar on the left beside a gray scene whose subject
    // sits right of center. The bar's hard edge is not the subject.
    final art = pixelsWhere(60, 20, (x, y) {
      if (x < 16) return 0;
      if ((x - 42).abs() <= 2 && (y - 10).abs() <= 3) return 250;
      return 120;
    });
    final focal = calculateFocalPoint(art, 60, 20);
    final crop = focalCropRect(60, 20, focal);
    expect(crop.left, greaterThan(16));
    expect(crop.left, lessThanOrEqualTo(40));
    expect(crop.right, greaterThanOrEqualTo(45));
  });

  test("a distinct subject outweighs low-contrast texture", () {
    final art = pixelsWhere(20, 60, (x, y) {
      if (y < 20) return (x + y).isEven ? 110 : 140;
      if (y >= 44 && y < 50 && x >= 7 && x < 13) return 255;
      return 125;
    });
    expect(calculateFocalPoint(art, 20, 60).dy, greaterThan(0.6));
  });

  test("a small subject on a plain background is kept in the crop", () {
    final art = pixelsWhere(128, 72, (x, y) {
      if (x >= 110 && x < 120 && y >= 30 && y < 40) return 250;
      return 40;
    });
    final crop = focalCropRect(128, 72, calculateFocalPoint(art, 128, 72));
    expect(crop.left, lessThanOrEqualTo(110));
    expect(crop.right, greaterThanOrEqualTo(120));
  });

  test("a small subject is centered in the crop when the frame allows", () {
    final art = pixelsWhere(128, 72, (x, y) {
      if (x >= 80 && x < 90 && y >= 30 && y < 40) return 250;
      return 40;
    });
    final crop = focalCropRect(128, 72, calculateFocalPoint(art, 128, 72));
    expect(crop.center.dx, closeTo(85, 2));
  });

  test("a flat subject stands out from busy high-contrast texture", () {
    // Salt-and-pepper texture covers the whole frame; the subject is a plain
    // bright block whose only edges are its outline.
    final art = pixelsWhere(128, 72, (x, y) {
      if (x >= 12 && x < 36 && y >= 24 && y < 48) return 255;
      return ((x * 73856093) ^ (y * 19349663)) % 7 < 3 ? 60 : 180;
    });
    final crop = focalCropRect(128, 72, calculateFocalPoint(art, 128, 72));
    expect(crop.left, lessThanOrEqualTo(12));
    expect(crop.center.dx, lessThan(40));
  });

  test("a subject touching the frame edge stays salient", () {
    // A bust cut off by the bottom edge connects to the border through itself.
    final art = pixelsWhere(128, 72, (x, y) {
      if (x >= 92 && x < 112 && y >= 30) return 230;
      return 120;
    });
    final crop = focalCropRect(128, 72, calculateFocalPoint(art, 128, 72));
    expect(crop.left, lessThanOrEqualTo(92));
    expect(crop.right, greaterThanOrEqualTo(112));
  });

  test("a plain backdrop margin is not trimmed as a letterbox bar", () {
    // The uniform strip right of the subject is backdrop, not a bar. Trimming
    // it would leave the subject on the content border, where it looks like
    // background, and the textured panel on the left would win.
    final art = pixelsWhere(128, 72, (x, y) {
      if (x < 40) return (x + y).isEven ? 90 : 170;
      if (x >= 92 && x < 108 && y >= 28 && y < 44) return 240;
      return 130;
    });
    final crop = focalCropRect(128, 72, calculateFocalPoint(art, 128, 72));
    expect(crop.left, greaterThanOrEqualTo(40));
    expect(crop.right, greaterThanOrEqualTo(108));
  });

  test("model saliency chooses the crop", () {
    final right = focalPointFromSaliency(
      columnMap((x) => x >= 171),
      saliencyModelSize,
      128,
      72,
      (0, 0, 128, 72),
    );
    expect(focalCropRect(128, 72, right).right, 128);
    final left = focalPointFromSaliency(
      columnMap((x) => x < 40),
      saliencyModelSize,
      128,
      72,
      (0, 0, 128, 72),
    );
    expect(focalCropRect(128, 72, left).left, 0);
  });

  test("the crop frames the main subject instead of slicing it", () {
    // Pixel columns 10..40 hold the main subject and 75..95 a slightly weaker
    // one. The most salient window keeps the second whole but cuts the main
    // subject in half; a composed crop keeps the main subject whole and ends
    // before the second one starts.
    final focal = focalPointFromSaliency(
      Float32List.fromList([
        for (var y = 0; y < saliencyModelSize; y++)
          for (var x = 0; x < saliencyModelSize; x++)
            x >= 20 && x < 80
                ? 1.0
                : x >= 150 && x < 190
                ? 0.9
                : 0.0,
      ]),
      saliencyModelSize,
      128,
      72,
      (0, 0, 128, 72),
    );
    final crop = focalCropRect(128, 72, focal);
    expect(crop.left, lessThanOrEqualTo(10));
    expect(crop.right, greaterThanOrEqualTo(40));
    expect(crop.right, lessThanOrEqualTo(75));
  });

  test("model saliency maps back through letterbox content", () {
    // The map covers only x 40..128; its salient first quarter is x 40..62,
    // so the crop centers on x 51.
    final focal = focalPointFromSaliency(
      columnMap((x) => x < saliencyModelSize ~/ 4),
      saliencyModelSize,
      128,
      72,
      (40, 0, 128, 72),
    );
    expect(focalCropRect(128, 72, focal).center.dx, closeTo(51, 2));
  });

  test("flat or malformed model saliency uses center", () {
    final flat = Float32List(saliencyModelSize * saliencyModelSize)
      ..fillRange(0, saliencyModelSize * saliencyModelSize, 0.7);
    expect(
      focalPointFromSaliency(flat, saliencyModelSize, 128, 72, (0, 0, 128, 72)),
      centerFocalPoint,
    );
    expect(
      focalPointFromSaliency(Float32List(3), saliencyModelSize, 128, 72, (
        0,
        0,
        128,
        72,
      )),
      centerFocalPoint,
    );
    expect(
      focalPointFromSaliency(
        columnMap((x) => x < 10),
        saliencyModelSize,
        128,
        72,
        (0, 0, 200, 72),
      ),
      centerFocalPoint,
    );
  });

  test("model input is scaled by the brightest value and normalized", () {
    final input = saliencyInput(
      Uint8List.fromList([100, 50, 0, 255, 0, 0, 0, 255]),
    );
    expect(input.length, 6);
    expect(input[0], closeTo((1 - 0.485) / 0.229, 1e-5));
    expect(input[1], closeTo((0.5 - 0.456) / 0.224, 1e-5));
    expect(input[2], closeTo(-0.406 / 0.225, 1e-5));
    expect(input[3], closeTo(-0.485 / 0.229, 1e-5));
    // Black input stays finite.
    expect(saliencyInput(Uint8List(8)).every((v) => v.isFinite), isTrue);
  });

  test("pillarbox bars are trimmed even when they carry a logo", () {
    final art = pixelsWhere(128, 72, (x, y) {
      // A small channel logo inside the left bar.
      if (x >= 3 && x < 8 && y >= 55 && y < 65) return 255;
      if (x < 10 || x >= 118) return 0;
      return (x * 3 + y * 5) % 200 + 30;
    });
    expect(artworkContent(art, 128, 72), (10, 0, 118, 72));
  });

  test("a wide plain backdrop around a small subject is not trimmed", () {
    final art = pixelsWhere(128, 72, (x, y) {
      if (x >= 60 && x < 68 && y >= 30 && y < 40) return 250;
      return 40;
    });
    expect(artworkContent(art, 128, 72), (0, 0, 128, 72));
  });

  test("letterbox edges alone do not count as detail", () {
    // Flat content between black bars, with faint codec-like noise.
    final art = pixelsWhere(128, 96, (x, y) {
      if (y < 12 || y >= 84) return 0;
      return 120 + (x * 7 + y * 13) % 3;
    });
    expect(calculateFocalPoint(art, 128, 96), centerFocalPoint);
  });

  test("uniform, invalid and tiny-difference images use center", () {
    expect(
      calculateFocalPoint(Uint8List(16 * 16 * 4), 16, 16),
      centerFocalPoint,
    );
    expect(calculateFocalPoint(Uint8List(0), 0, 0), centerFocalPoint);
    expect(calculateFocalPoint(Uint8List(2), 16, 16), centerFocalPoint);
    final almostUniform = salientRow(20, 20, 1);
    for (var i = 0; i < almostUniform.length; i += 4) {
      almostUniform[i] = almostUniform[i] == 0 ? 0 : 1;
      almostUniform[i + 1] = almostUniform[i];
      almostUniform[i + 2] = almostUniform[i];
    }
    expect(calculateFocalPoint(almostUniform, 20, 20), centerFocalPoint);
  });

  test("evenly spread detail keeps the crop centered", () {
    final art = pixelsWhere(20, 60, (x, y) => (x + y).isEven ? 255 : 0);
    expect(calculateFocalPoint(art, 20, 60).dy, closeTo(0.5, 0.02));
  });

  test("aspect ratios, normalization and clamping", () {
    expect(
      calculateFocalPoint(salientRow(8, 40, 35), 8, 40).dy,
      greaterThan(0.7),
    );
    expect(
      calculateFocalPoint(salientColumn(40, 8, 1), 40, 8).dx,
      lessThan(0.4),
    );
    expect(clampFocal(double.nan), 0.5);
    expect(clampFocal(-3), 0);
    expect(clampFocal(4), 1);
    expect(
      focalCropRect(20, 60, const ui.Offset(0.5, -1)),
      const ui.Rect.fromLTWH(0, 0, 20, 20),
    );
    expect(
      focalCropRect(20, 60, const ui.Offset(0.5, 1)),
      const ui.Rect.fromLTWH(0, 40, 20, 20),
    );
    expect(focalCropRect(20, 60, const ui.Offset(0.5, 0.25)).top, 5);
    expect(focalCropRect(20, 60, centerFocalPoint).top, 20);
    expect(focalCropRect(20, 60, const ui.Offset(0.5, 0.75)).top, 35);
    expect(
      focalCropRect(60, 20, centerFocalPoint),
      const ui.Rect.fromLTWH(20, 0, 20, 20),
    );
    expect(
      focalCropRect(60, 20, const ui.Offset(0, 0.5)),
      const ui.Rect.fromLTWH(0, 0, 20, 20),
    );
    expect(focalCropRect(60, 20, const ui.Offset(0.75, 0)).left, 35);
  });

  test(
    "prepared artwork uses the detected focal point, center mode, and cached results",
    () async {
      final directory = await Directory.systemTemp.createTemp(
        "melody-focal-test-",
      );
      try {
        final source = File("${directory.path}/art.png");
        await source.writeAsBytes(await sourceArt());
        final processor = NotificationArtwork(saliencyModel: FakeModel());
        final automatic = await processor.prepare(
          source.uri.toString(),
          automatic: true,
        );
        final centered = await processor.prepare(
          source.uri.toString(),
          automatic: false,
        );
        expect(automatic, isNot(centered));
        expect(await centerRed(automatic), greaterThan(50));
        expect(await centerRed(centered), 0);
        expect(
          await processor.prepare(source.uri.toString(), automatic: true),
          automatic,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test("prepared artwork follows the saliency model", () async {
    final directory = await Directory.systemTemp.createTemp("melody-model-");
    try {
      final source = File("${directory.path}/art.png");
      await source.writeAsBytes(await landscapeArt());
      final model = FakeModel(map: columnMap((x) => x >= 171));
      final processor = NotificationArtwork(saliencyModel: model);
      final prepared = await processor.prepare(
        source.uri.toString(),
        automatic: true,
      );
      final color = await centerColor(prepared);
      expect(color[2], greaterThan(200));
      expect(color[0], lessThan(50));
      expect(
        model.inputs.single.length,
        saliencyModelSize * saliencyModelSize * 4,
      );

      final centered = FakeModel(map: columnMap((x) => x >= 171));
      await NotificationArtwork(
        saliencyModel: centered,
      ).prepare(source.uri.toString(), automatic: false);
      expect(centered.inputs, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test("model crops survive a restart and fallback crops do not", () async {
    final directory = await Directory.systemTemp.createTemp("melody-model-");
    try {
      final source = File("${directory.path}/art.png");
      await source.writeAsBytes(await landscapeArt());
      final uri = source.uri.toString();
      final map = columnMap((x) => x >= 171);

      // A fallback crop is redone by the next process once the model runs.
      await NotificationArtwork(
        saliencyModel: FakeModel(),
      ).prepare(uri, automatic: true);
      final retry = FakeModel(map: map);
      final prepared = await NotificationArtwork(
        saliencyModel: retry,
      ).prepare(uri, automatic: true);
      expect(retry.inputs, hasLength(1));

      // A model crop is reused without decoding or running the model again.
      final restarted = FakeModel(map: map);
      final reused = await NotificationArtwork(
        saliencyModel: restarted,
      ).prepare(uri, automatic: true);
      expect(reused, prepared);
      expect(restarted.inputs, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test("a failing saliency model falls back to the Dart detector", () async {
    final directory = await Directory.systemTemp.createTemp("melody-model-");
    try {
      final source = File("${directory.path}/art.png");
      await source.writeAsBytes(await landscapeArt());
      final model = FakeModel(error: StateError("no runtime"));
      final prepared = await NotificationArtwork(
        saliencyModel: model,
      ).prepare(source.uri.toString(), automatic: true);
      expect(model.inputs, hasLength(1));
      expect(prepared, isNot(source.uri.toString()));
      expect(File.fromUri(Uri.parse(prepared)).existsSync(), isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test("invalid and empty artwork falls back without throwing", () async {
    final directory = await Directory.systemTemp.createTemp(
      "melody-invalid-art-",
    );
    try {
      final invalid = File("${directory.path}/invalid.png");
      await invalid.writeAsBytes([0, 1, 2]);
      final processor = NotificationArtwork(saliencyModel: FakeModel());
      expect(await processor.prepare("", automatic: true), "");
      expect(
        await processor.prepare(invalid.uri.toString(), automatic: true),
        invalid.uri.toString(),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
