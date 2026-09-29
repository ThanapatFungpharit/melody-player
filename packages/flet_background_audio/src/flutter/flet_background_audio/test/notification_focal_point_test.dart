import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter_test/flutter_test.dart";
import "package:flet_background_audio/src/notification_artwork.dart";
import "package:flet_background_audio/src/notification_focal_point.dart";

Uint8List salientRow(int width, int height, int row) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      final color = y == row && x.isEven ? 255 : 0;
      pixels[index] = color;
      pixels[index + 1] = color;
      pixels[index + 2] = color;
      pixels[index + 3] = 255;
    }
  }
  return pixels;
}

Future<Uint8List> sourceArt() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  for (var x = 0; x < 20; x++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(x.toDouble(), 0, 1, 16),
      ui.Paint()..color = x.isEven
          ? const ui.Color(0xffff0000) : const ui.Color(0xff00ff00),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(20, 60);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

Future<int> centerRed(String uri) async {
  final bytes = await File.fromUri(Uri.parse(uri)).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final index = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  final red = pixels!.getUint8(index);
  image.dispose();
  codec.dispose();
  return red;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("top, middle and bottom visual detail move the normalized focal row", () {
    expect(calculateFocalY(salientRow(32, 30, 2), 32, 30), lessThan(0.3));
    expect(calculateFocalY(salientRow(32, 30, 15), 32, 30),
        inInclusiveRange(0.4, 0.6));
    expect(calculateFocalY(salientRow(32, 30, 27), 32, 30), greaterThan(0.7));
  });

  test("uniform, invalid and tiny-difference images use center", () {
    expect(calculateFocalY(Uint8List(16 * 16 * 4), 16, 16), 0.5);
    expect(calculateFocalY(Uint8List(0), 0, 0), 0.5);
    expect(calculateFocalY(Uint8List(2), 16, 16), 0.5);
    final almostUniform = salientRow(20, 20, 1);
    for (var i = 0; i < almostUniform.length; i += 4) {
      almostUniform[i] = almostUniform[i] == 0 ? 0 : 1;
      almostUniform[i + 1] = almostUniform[i];
      almostUniform[i + 2] = almostUniform[i];
    }
    expect(calculateFocalY(almostUniform, 20, 20), 0.5);
  });

  test("aspect ratios, normalization and clamping", () {
    expect(calculateFocalY(salientRow(8, 40, 35), 8, 40), greaterThan(0.7));
    expect(calculateFocalY(salientRow(40, 8, 1), 40, 8), lessThan(0.4));
    expect(clampFocalY(double.nan), 0.5);
    expect(clampFocalY(-3), 0);
    expect(clampFocalY(4), 1);
    expect(focalCropRect(20, 60, -1), const ui.Rect.fromLTWH(0, 0, 20, 20));
    expect(focalCropRect(20, 60, 1), const ui.Rect.fromLTWH(0, 40, 20, 20));
    expect(focalCropRect(20, 60, 0.25).top, 5);
    expect(focalCropRect(20, 60, 0.5).top, 20);
    expect(focalCropRect(20, 60, 0.75).top, 35);
    expect(focalCropRect(60, 20, 0), const ui.Rect.fromLTWH(20, 0, 20, 20));
  });

  test("prepared artwork uses detected Y, center mode, and cached results", () async {
    final directory = await Directory.systemTemp.createTemp("melody-focal-test-");
    try {
      final source = File("${directory.path}/art.png");
      await source.writeAsBytes(await sourceArt());
      final processor = NotificationArtwork();
      final automatic = await processor.prepare(source.uri.toString(), automatic: true);
      final centered = await processor.prepare(source.uri.toString(), automatic: false);
      expect(automatic, isNot(centered));
      expect(await centerRed(automatic), greaterThan(50));
      expect(await centerRed(centered), 0);
      expect(await processor.prepare(source.uri.toString(), automatic: true), automatic);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test("invalid and empty artwork falls back without throwing", () async {
    final directory = await Directory.systemTemp.createTemp("melody-invalid-art-");
    try {
      final invalid = File("${directory.path}/invalid.png");
      await invalid.writeAsBytes([0, 1, 2]);
      final processor = NotificationArtwork();
      expect(await processor.prepare("", automatic: true), "");
      expect(await processor.prepare(invalid.uri.toString(), automatic: true),
          invalid.uri.toString());
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
