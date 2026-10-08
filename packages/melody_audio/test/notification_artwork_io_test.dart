import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/src/notification_artwork_io.dart";

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-artwork");
    useNotificationArtworkDirectory(root.path);
  });

  tearDown(() => root.delete(recursive: true));

  test("artwork is kept in the folder the app chose, and bounded", () async {
    final png = Uint8List.fromList([137, 80, 78, 71]);
    // A write that ended with its process.
    final leftover = File("${root.path}/old.png.tmp")..writeAsBytesSync([1]);
    leftover.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    for (var index = 0; index < 70; index++) {
      final uri = await saveNotificationArtwork(png, "key$index");
      expect(uri, startsWith(Uri.directory(root.path).toString()));
    }
    final names = [
      for (final file in root.listSync()) file.uri.pathSegments.last,
    ];
    expect(names.where((name) => name.endsWith(".png")), hasLength(64));
    expect(names.where((name) => !name.endsWith(".png")), isEmpty);
    expect(await existingNotificationArtwork("key69"), isNotNull);
  });
}
