import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/src/notification_artwork.dart";

/// Portrait art with red and green stripes along the top only.
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

  test("the crop is the centered square of any aspect ratio", () {
    expect(centerSquare(20, 60), const ui.Rect.fromLTWH(0, 20, 20, 20));
    expect(centerSquare(60, 20), const ui.Rect.fromLTWH(20, 0, 20, 20));
    expect(centerSquare(30, 30), const ui.Rect.fromLTWH(0, 0, 30, 30));
  });

  test("prepared artwork is the center of the image, reused later", () async {
    final directory = await Directory.systemTemp.createTemp("melody-art-");
    try {
      final source = File("${directory.path}/art.png");
      await source.writeAsBytes(await sourceArt());
      final uri = source.uri.toString();
      final processor = NotificationArtwork();
      final prepared = await processor.prepare(uri);
      expect(prepared, isNot(uri));
      // The stripes along the top are cropped away.
      expect(await centerRed(prepared), 0);
      expect(await processor.prepare(uri), prepared);
      // A new process finds the same copy on disk.
      expect(await NotificationArtwork().prepare(uri), prepared);
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
      final processor = NotificationArtwork();
      expect(await processor.prepare(""), "");
      expect(
        await processor.prepare(invalid.uri.toString()),
        invalid.uri.toString(),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
