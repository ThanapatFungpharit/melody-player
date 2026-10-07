/// Writes lyrics into MP3 files as an ID3 `USLT` frame.
///
/// FFmpeg can only store a `lyrics` key in MP3 as a non-standard `TXXX`
/// frame that players ignore, so the downloader writes the standard frame
/// itself, in staging, before artwork verification and content hashing.
library;

import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "id3.dart";

/// Room left after the frames so later tag edits need not rewrite the audio.
const _padding = 1024;

/// Replaces the lyrics in an MP3's ID3v2.3/2.4 tag (adding a v2.4 tag when
/// there is none). Every other frame is kept byte for byte. Returns false
/// when the tag uses a layout this writer does not rewrite (v2.2, or v2.4
/// tag-wide unsynchronisation). Runs off the UI isolate.
Future<bool> writeId3Lyrics(String path, String lyrics) =>
    Isolate.run(() => writeId3LyricsSync(path, lyrics));

bool writeId3LyricsSync(String path, String lyrics) {
  // Only the tag is held in memory; the audio after it streams through a
  // fixed buffer, so a long recording is never loaded whole.
  final temporary = File("$path.lyrics.tmp");
  final input = File(path).openSync();
  try {
    final length = input.lengthSync();
    final header = _read(input, length < 10 ? length : 10);
    var major = 4;
    var audioStart = 0;
    final kept = BytesBuilder(copy: false);
    if (header.length == 10 && latin1.decode(header.sublist(0, 3)) == "ID3") {
      major = header[3];
      final flags = header[5];
      final size = readSyncsafe(header, 6);
      if (major < 3 || major > 4 || (major == 4 && flags & 0x80 != 0)) {
        return false;
      }
      audioStart = 10 + size + (major == 4 && flags & 0x10 != 0 ? 10 : 0);
      if (audioStart > length) {
        throw const FormatException("Truncated ID3 tag");
      }
      var body = _read(input, size);
      if (major == 3 && flags & 0x80 != 0) body = removeUnsynchronisation(body);
      var offset = 0;
      if (flags & 0x40 != 0) {
        // Extended header: v2.3 size excludes itself; v2.4 size includes it.
        offset = major == 4
            ? readSyncsafe(body, 0)
            : 4 + ByteData.sublistView(body, 0, 4).getUint32(0);
      }
      while (offset + 10 <= body.length) {
        if (body[offset] == 0) break; // padding
        final id = latin1.decode(body.sublist(offset, offset + 4));
        final frameSize = major == 4
            ? readSyncsafe(body, offset + 4)
            : ByteData.sublistView(body, offset + 4, offset + 8).getUint32(0);
        final end = offset + 10 + frameSize;
        if (frameSize <= 0 || end > body.length) {
          throw const FormatException("Invalid ID3 frame");
        }
        final frameFlags = (body[offset + 8] << 8) | body[offset + 9];
        final content = Uint8List.sublistView(body, offset + 10, end);
        if (!_isLyricsFrame(id, frameFlags, content, major)) {
          kept.add(Uint8List.sublistView(body, offset, end));
        }
        offset = end;
      }
    }
    final frames = kept.takeBytes();
    final lyricsFrame = _usltFrame(lyrics, major);
    final tagSize = frames.length + lyricsFrame.length + _padding;
    final tag =
        (BytesBuilder(copy: false)
              ..add(latin1.encode("ID3"))
              ..add([major, 0, 0])
              ..add(encodeSyncsafe(tagSize))
              ..add(frames)
              ..add(lyricsFrame)
              ..add(Uint8List(_padding)))
            .takeBytes();
    input.setPositionSync(audioStart);
    final output = temporary.openSync(mode: FileMode.writeOnly);
    try {
      output.writeFromSync(tag);
      final buffer = Uint8List(1024 * 1024);
      while (true) {
        final read = input.readIntoSync(buffer);
        if (read == 0) break;
        output.writeFromSync(buffer, 0, read);
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
  } catch (_) {
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  } finally {
    // Closed before the rename: Windows cannot replace an open file.
    input.closeSync();
  }
  try {
    temporary.renameSync(path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
  return true;
}

/// Exactly [count] bytes from the current position of [file].
Uint8List _read(RandomAccessFile file, int count) {
  final buffer = Uint8List(count);
  var filled = 0;
  while (filled < count) {
    final read = file.readIntoSync(buffer, filled);
    if (read == 0) throw const FormatException("Truncated ID3 tag");
    filled += read;
  }
  return buffer;
}

/// Existing lyrics: USLT, and TXXX frames FFmpeg or other taggers named
/// as lyrics. Compressed or encrypted frames are left alone.
bool _isLyricsFrame(String id, int flags, Uint8List content, int major) {
  if (id == "USLT") return true;
  if (id != "TXXX" || content.isEmpty) return false;
  final opaque = major == 3 ? flags & 0x00c0 != 0 : flags & 0x000d != 0;
  if (opaque) return false;
  return id3LyricsDescriptions.contains(parseTxxx(content).$1.toLowerCase());
}

/// A USLT frame with an unknown language and no description: UTF-8 in
/// v2.4, UTF-16 with a byte-order mark in v2.3 (which has no UTF-8).
Uint8List _usltFrame(String lyrics, int major) {
  final content = BytesBuilder(copy: false);
  if (major == 4) {
    content
      ..addByte(3)
      ..add(latin1.encode("XXX"))
      ..addByte(0)
      ..add(utf8.encode(lyrics));
  } else {
    content
      ..addByte(1)
      ..add(latin1.encode("XXX"))
      ..add(const [0xff, 0xfe, 0, 0])
      ..add(const [0xff, 0xfe]);
    for (final unit in lyrics.codeUnits) {
      content.add([unit & 0xff, unit >> 8]);
    }
  }
  final data = content.takeBytes();
  final size = major == 4
      ? encodeSyncsafe(data.length)
      : (ByteData(4)..setUint32(0, data.length)).buffer.asUint8List();
  return (BytesBuilder(copy: false)
        ..add(latin1.encode("USLT"))
        ..add(size)
        ..add(const [0, 0])
        ..add(data))
      .takeBytes();
}
