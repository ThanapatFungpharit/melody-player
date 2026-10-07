import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/artwork.dart";
import "package:melody/core/id3_lyrics.dart";
import "package:path/path.dart" as p;

const _lrc = "[00:01.00]Line one\n[00:02.50]Line two";

/// The bytes after an ID3v2 tag: the audio itself.
List<int> _audio(List<int> bytes) {
  if (latin1.decode(bytes.sublist(0, 3)) != "ID3") return bytes;
  final size =
      (bytes[6] & 0x7f) << 21 |
      (bytes[7] & 0x7f) << 14 |
      (bytes[8] & 0x7f) << 7 |
      (bytes[9] & 0x7f);
  return bytes.sublist(10 + size);
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-lyrics-tags");
  });

  tearDown(() => root.delete(recursive: true));

  Future<String> copy(String fixture) async {
    final path = p.join(root.path, p.basename(fixture));
    await File(fixture).copy(path);
    return path;
  }

  group("reading embedded lyrics", () {
    for (final extension in ["m4a", "flac", "opus", "ogg"]) {
      test(extension, () {
        expect(
          readEmbeddedLyricsSync("test/fixtures/lyrics/lyrics.$extension"),
          _lrc,
        );
      });
    }

    test("FFmpeg's TXXX lyrics in MP3", () {
      expect(
        readEmbeddedLyricsSync("test/fixtures/lyrics/txxx.mp3"),
        "Old FFmpeg text",
      );
    });

    test("a malformed TXXX frame does not hide later lyrics", () async {
      List<int> frame(String id, List<int> content) => [
        ...latin1.encode(id),
        ...(ByteData(4)..setUint32(0, content.length)).buffer.asUint8List(),
        0,
        0,
        ...content,
      ];
      final frames = [
        // A description with no terminator.
        ...frame("TXXX", [0, ...latin1.encode("broken")]),
        ...frame("TXXX", [
          0,
          ...latin1.encode("LYRICS"),
          0,
          ...latin1.encode("Words"),
        ]),
      ];
      final path = p.join(root.path, "malformed.mp3");
      await File(path).writeAsBytes([
        ...latin1.encode("ID3"),
        3,
        0,
        0,
        0,
        0,
        frames.length >> 7,
        frames.length & 0x7f,
        ...frames,
        0xff,
        0xfb,
        0x90,
        0x00,
      ]);

      expect(readEmbeddedLyricsSync(path), "Words");
      // The writer keeps the unrelated frame and replaces the lyrics.
      expect(writeId3LyricsSync(path, "New words"), isTrue);
      expect(readEmbeddedLyricsSync(path), "New words");
      expect(latin1.decode(await File(path).readAsBytes()), contains("broken"));
    });

    test("files without lyrics read as empty", () {
      expect(readEmbeddedLyricsSync("test/fixtures/artwork/cover.mp3"), "");
      expect(readEmbeddedLyricsSync("test/fixtures/artwork/cover.flac"), "");
      expect(readEmbeddedLyricsSync(p.join("missing", "file.mp3")), "");
    });
  });

  group("writing MP3 lyrics", () {
    for (final fixture in ["cover.mp3", "cover_v24.mp3"]) {
      test("$fixture keeps its artwork and audio", () async {
        final path = await copy("test/fixtures/artwork/$fixture");
        final before = await File(path).readAsBytes();
        final artwork = readEmbeddedArtworkSync(path);

        expect(writeId3LyricsSync(path, "$_lrc\nÜnïcode ✓"), isTrue);

        expect(readEmbeddedLyricsSync(path), "$_lrc\nÜnïcode ✓");
        expect(readEmbeddedArtworkSync(path), artwork);
        expect(_audio(await File(path).readAsBytes()), _audio(before));
        expect(await File(path).readAsBytes(), isNot(before));
      });
    }

    test("replacing lyrics leaves a single lyrics frame", () async {
      final path = await copy("test/fixtures/artwork/cover_v24.mp3");
      writeId3LyricsSync(path, "First");
      writeId3LyricsSync(path, "Second");
      expect(readEmbeddedLyricsSync(path), "Second");
      final tag = latin1.decode(await File(path).readAsBytes());
      expect("USLT".allMatches(tag), hasLength(1));
    });

    test("FFmpeg's TXXX frame is replaced by USLT", () async {
      final path = await copy("test/fixtures/lyrics/txxx.mp3");
      writeId3LyricsSync(path, "New words");
      expect(readEmbeddedLyricsSync(path), "New words");
      final tag = latin1.decode(await File(path).readAsBytes());
      expect(tag, isNot(contains("Old FFmpeg text")));
    });

    test("a file without a tag gets one", () async {
      final path = p.join(root.path, "bare.mp3");
      final audio = _audio(
        await File("test/fixtures/artwork/no_cover.mp3").readAsBytes(),
      );
      await File(path).writeAsBytes(audio);
      expect(writeId3LyricsSync(path, "Hello"), isTrue);
      expect(readEmbeddedLyricsSync(path), "Hello");
      expect(_audio(await File(path).readAsBytes()), audio);
    });
  });
}
