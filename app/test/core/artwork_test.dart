import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody/core/artwork.dart";
import "package:path/path.dart" as p;

void main() {
  final fixtures = p.join("test", "fixtures", "artwork");
  // Recorded from the previous mutagen-based reader for the same files.
  final expected = (jsonDecode(
    File(p.join(fixtures, "expected.json")).readAsStringSync(),
  ) as Map<String, Object?>).cast<String, String>();

  for (final MapEntry(key: name, value: digest) in expected.entries) {
    test("reads the same cover as mutagen from $name", () async {
      final artwork = await readEmbeddedArtwork(p.join(fixtures, name));
      expect(
        artwork.isEmpty ? "" : sha256.convert(artwork).toString(),
        digest,
      );
    });
  }

  test("prefers the front cover over a larger back cover", () {
    // cover.mp3 also carries a larger "back cover" APIC frame.
    final artwork = readEmbeddedArtworkSync(p.join(fixtures, "cover.mp3"));
    expect(sha256.convert(artwork).toString(), expected["cover.mp3"]);
  });

  test("damaged and unknown files have no artwork", () async {
    final directory = await Directory.systemTemp.createTemp("melody-artwork");
    addTearDown(() => directory.delete(recursive: true));
    final damaged = File(p.join(directory.path, "damaged.m4a"))
      ..writeAsBytesSync([0, 0, 0, 3, 1, 2]);
    final unknown = File(p.join(directory.path, "song.wav"))
      ..writeAsBytesSync([1, 2, 3]);
    expect(await readEmbeddedArtwork(damaged.path), isEmpty);
    expect(await readEmbeddedArtwork(unknown.path), isEmpty);
  });
}
