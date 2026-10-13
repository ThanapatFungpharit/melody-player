import "dart:convert";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/id3.dart";

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group("syncsafe integers", () {
    test("round-trip across the valid range", () {
      for (final value in [0, 1, 127, 128, 0x3fff, 1234567, (1 << 28) - 1]) {
        expect(readSyncsafe(encodeSyncsafe(value), 0), value, reason: "$value");
      }
      expect(encodeSyncsafe(128), [0, 0, 1, 0]);
    });

    test("ignore the high bit of each byte and honor the offset", () {
      expect(
        readSyncsafe(_bytes([9, 0x80, 0x80, 0x81, 0xff]), 1),
        0x7f | 1 << 7,
      );
    });

    test("reject values that do not fit in 28 bits", () {
      expect(() => encodeSyncsafe(-1), throwsFormatException);
      expect(() => encodeSyncsafe(1 << 28), throwsFormatException);
    });
  });

  test("removeUnsynchronisation drops the zero after every FF", () {
    expect(
      removeUnsynchronisation(
        _bytes([0xff, 0x00, 0xe0, 0xff, 0x00, 0x00, 0xff]),
      ),
      [0xff, 0xe0, 0xff, 0x00, 0xff],
    );
    expect(removeUnsynchronisation(_bytes([])), isEmpty);
  });

  group("decodeId3Text", () {
    test("decodes ISO-8859-1 and UTF-8", () {
      expect(decodeId3Text(_bytes(latin1.encode("café")), 0), "café");
      expect(decodeId3Text(_bytes(utf8.encode("café ♪")), 3), "café ♪");
      expect(decodeId3Text(_bytes([0x61, 0xff]), 3), "a�");
    });

    test("decodes UTF-16 with either byte order mark", () {
      expect(decodeId3Text(_bytes([0xff, 0xfe, 0x61, 0, 0x6a, 0x26]), 1), "a♪");
      expect(decodeId3Text(_bytes([0xfe, 0xff, 0, 0x61, 0x26, 0x6a]), 1), "a♪");
      // Without a BOM, encoding 1 defaults to little-endian.
      expect(decodeId3Text(_bytes([0x61, 0]), 1), "a");
    });

    test("decodes UTF-16BE and ignores a trailing odd byte", () {
      expect(decodeId3Text(_bytes([0, 0x61, 0, 0x62, 0x63]), 2), "ab");
    });
  });

  group("skipId3Text", () {
    test("finds single-byte terminators", () {
      expect(skipId3Text(_bytes([0x61, 0x62, 0, 0x63]), 0, 3), 3);
      expect(skipId3Text(_bytes([0x61, 0x62, 0, 0x63]), 1, 0), 3);
    });

    test("finds aligned UTF-16 terminators only", () {
      // The 00 00 straddling the first two characters is not a terminator.
      final data = _bytes([0x61, 0, 0, 0x62, 0, 0, 0x63, 0]);
      expect(skipId3Text(data, 0, 2), 6);
    });

    test("throws on unterminated text", () {
      expect(
        () => skipId3Text(_bytes([0x61, 0x62]), 0, 0),
        throwsFormatException,
      );
      expect(
        () => skipId3Text(_bytes([0x61, 0, 0x62]), 0, 1),
        throwsFormatException,
      );
    });
  });

  group("parseTxxx", () {
    test("splits a UTF-8 frame into description and value", () {
      final frame = _bytes([
        3,
        ...utf8.encode("LYRICS"),
        0,
        ...utf8.encode("la la"),
      ]);
      expect(parseTxxx(frame), ("LYRICS", "la la"));
    });

    test("splits a UTF-16 frame with byte order marks", () {
      final frame = _bytes([
        1,
        0xff, 0xfe, 0x4c, 0, 0, 0, // "L" + terminator
        0xff, 0xfe, 0x68, 0, 0x69, 0, // "hi"
      ]);
      expect(parseTxxx(frame), ("L", "hi"));
    });

    test("returns empty fields for short or unterminated frames", () {
      expect(parseTxxx(_bytes([])), ("", ""));
      expect(parseTxxx(_bytes([3])), ("", ""));
      expect(parseTxxx(_bytes([3, 0x61, 0x62])), ("", ""));
    });
  });

  test("lyrics descriptions are lowercase", () {
    for (final description in id3LyricsDescriptions) {
      expect(description, description.toLowerCase());
    }
  });
}
