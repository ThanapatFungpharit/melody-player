/// ID3v2 primitives shared by the tag reader (`artwork.dart`) and the MP3
/// lyrics writer (`id3_lyrics.dart`).
library;

import "dart:convert";
import "dart:typed_data";

/// `TXXX` descriptions that other taggers (FFmpeg included) use for lyrics.
const id3LyricsDescriptions = {"lyrics", "unsyncedlyrics", "uslt"};

/// The 28-bit syncsafe integer at [offset].
int readSyncsafe(Uint8List data, int offset) =>
    (data[offset] & 0x7f) << 21 |
    (data[offset + 1] & 0x7f) << 14 |
    (data[offset + 2] & 0x7f) << 7 |
    (data[offset + 3] & 0x7f);

Uint8List encodeSyncsafe(int value) {
  if (value < 0 || value >= 1 << 28) {
    throw const FormatException("ID3 tag too large");
  }
  return Uint8List.fromList([
    (value >> 21) & 0x7f,
    (value >> 14) & 0x7f,
    (value >> 7) & 0x7f,
    value & 0x7f,
  ]);
}

/// Undoes ID3 unsynchronisation: every `FF 00` pair becomes `FF`.
Uint8List removeUnsynchronisation(Uint8List data) {
  final output = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i++) {
    output.addByte(data[i]);
    if (data[i] == 0xff && i + 1 < data.length && data[i + 1] == 0x00) i++;
  }
  return output.takeBytes();
}

bool _isUtf16(int encoding) => encoding == 1 || encoding == 2;

/// Text in an ID3 encoding: ISO-8859-1, UTF-16 with BOM, UTF-16BE, UTF-8.
String decodeId3Text(Uint8List data, int encoding) {
  switch (encoding) {
    case 1 || 2:
      var bigEndian = encoding == 2;
      var start = 0;
      if (encoding == 1 && data.length >= 2) {
        if (data[0] == 0xff && data[1] == 0xfe) {
          bigEndian = false;
          start = 2;
        } else if (data[0] == 0xfe && data[1] == 0xff) {
          bigEndian = true;
          start = 2;
        }
      }
      return String.fromCharCodes([
        for (var i = start; i + 1 < data.length; i += 2)
          bigEndian
              ? (data[i] << 8) | data[i + 1]
              : data[i] | (data[i + 1] << 8),
      ]);
    case 3:
      return utf8.decode(data, allowMalformed: true);
    default:
      return latin1.decode(data);
  }
}

/// Skips an encoded, terminated string that starts at [offset] and returns
/// the offset after its terminator.
int skipId3Text(Uint8List data, int offset, int encoding) {
  if (_isUtf16(encoding)) {
    for (var i = offset; i + 1 < data.length; i += 2) {
      if (data[i] == 0 && data[i + 1] == 0) return i + 2;
    }
  } else {
    for (var i = offset; i < data.length; i++) {
      if (data[i] == 0) return i + 1;
    }
  }
  throw const FormatException("Unterminated ID3 text");
}

/// A `TXXX` (or v2.2 `TXX`) frame's description and value. A frame without
/// a terminated description has neither.
(String, String) parseTxxx(Uint8List frame) {
  if (frame.length < 2) return ("", "");
  final encoding = frame[0];
  final int start;
  try {
    start = skipId3Text(frame, 1, encoding);
  } on FormatException {
    return ("", "");
  }
  final terminator = _isUtf16(encoding) ? 2 : 1;
  return (
    decodeId3Text(
      Uint8List.sublistView(frame, 1, start - terminator),
      encoding,
    ),
    decodeId3Text(Uint8List.sublistView(frame, start), encoding),
  );
}
