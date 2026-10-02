/// Reads cover artwork back from completed audio containers.
///
/// The downloader uses this read-back as proof that yt-dlp burned the
/// thumbnail into the output before staged files are committed. Supported:
/// ID3v2.2–2.4 (MP3), MP4/M4A `covr`, FLAC PICTURE blocks, and
/// `METADATA_BLOCK_PICTURE` comments in Ogg Opus and Vorbis.
library;

import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:path/path.dart" as p;

const maxArtworkBytes = 8 * 1024 * 1024;
const _frontCover = 3;

/// The largest front-cover payload in [path], or empty bytes when the file
/// has no readable artwork. Runs off the UI isolate.
Future<Uint8List> readEmbeddedArtwork(String path) =>
    Isolate.run(() => readEmbeddedArtworkSync(path));

Uint8List readEmbeddedArtworkSync(String path) {
  List<(int, Uint8List)> pictures;
  try {
    pictures = switch (p.extension(path).toLowerCase()) {
      ".mp3" => _id3Pictures(path),
      ".m4a" || ".mp4" || ".m4v" || ".mov" => _mp4Pictures(path),
      ".flac" => _flacPictures(path),
      ".ogg" || ".opus" => _oggPictures(path),
      _ => const [],
    };
  } on Object {
    // Damaged tags are a failed verification; the caller decides whether
    // artwork was required.
    return Uint8List(0);
  }
  final usable = [
    for (final (type, data) in pictures)
      if (data.isNotEmpty && data.length <= maxArtworkBytes) (type, data),
  ];
  final front = usable.where((item) => item.$1 == _frontCover).toList();
  final candidates = front.isNotEmpty ? front : usable;
  Uint8List best = Uint8List(0);
  for (final (_, data) in candidates) {
    if (data.length > best.length) best = data;
  }
  return best;
}

class _Bytes {
  _Bytes(this.data, [this.offset = 0]);

  final Uint8List data;
  int offset;

  int get remaining => data.length - offset;

  void _need(int count) {
    if (count < 0 || offset + count > data.length) {
      throw const FormatException("Truncated tag data");
    }
  }

  int u8() {
    _need(1);
    return data[offset++];
  }

  int u16() {
    _need(2);
    final value = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return value;
  }

  int u24() {
    _need(3);
    final value = (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2];
    offset += 3;
    return value;
  }

  int u32() {
    _need(4);
    final value = ByteData.sublistView(data, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  int u32le() {
    _need(4);
    final value = ByteData.sublistView(data, offset, offset + 4).getUint32(0, Endian.little);
    offset += 4;
    return value;
  }

  int syncsafe() {
    final raw = u32();
    return ((raw & 0x7f000000) >> 3) |
        ((raw & 0x007f0000) >> 2) |
        ((raw & 0x00007f00) >> 1) |
        (raw & 0x0000007f);
  }

  Uint8List take(int count) {
    _need(count);
    final value = Uint8List.sublistView(data, offset, offset + count);
    offset += count;
    return value;
  }

  String ascii(int count) => latin1.decode(take(count));
}

Uint8List _readPrefix(RandomAccessFile file, int length) {
  final buffer = Uint8List(length);
  final read = file.readIntoSync(buffer);
  return Uint8List.sublistView(buffer, 0, read);
}

// -- ID3v2 ------------------------------------------------------------------

Uint8List _removeUnsynchronisation(Uint8List data) {
  final output = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i++) {
    output.addByte(data[i]);
    if (data[i] == 0xff && i + 1 < data.length && data[i + 1] == 0x00) i++;
  }
  return output.takeBytes();
}

List<(int, Uint8List)> _id3Pictures(String path) {
  final file = File(path).openSync();
  final Uint8List tag;
  final int major;
  final int flags;
  try {
    final header = _readPrefix(file, 10);
    if (header.length < 10 || latin1.decode(header.sublist(0, 3)) != "ID3") {
      return const [];
    }
    major = header[3];
    flags = header[5];
    final size = _Bytes(header, 6).syncsafe();
    tag = _readPrefix(file, size);
    if (tag.length < size) throw const FormatException("Truncated ID3 tag");
  } finally {
    file.closeSync();
  }
  if (major < 2 || major > 4) return const [];
  final body = (major < 4 && flags & 0x80 != 0) ? _removeUnsynchronisation(tag) : tag;
  final reader = _Bytes(body);
  if (flags & 0x40 != 0 && major >= 3) {
    // Extended header: v2.3 size excludes itself; v2.4 size includes itself.
    final size = major == 4 ? reader.syncsafe() : reader.u32();
    reader.offset = major == 4 ? size : 4 + size;
  }
  final pictures = <(int, Uint8List)>[];
  while (reader.remaining >= (major == 2 ? 6 : 10)) {
    final String id;
    final int size;
    var frameFlags = 0;
    if (major == 2) {
      id = reader.ascii(3);
      size = reader.u24();
    } else {
      id = reader.ascii(4);
      size = major == 4 ? reader.syncsafe() : reader.u32();
      frameFlags = reader.u16();
    }
    if (id.codeUnits.every((unit) => unit == 0) || size <= 0) break;
    var frame = reader.take(size);
    if (id != "APIC" && id != "PIC") continue;
    frame = _decodeFrame(frame, major, frameFlags);
    final picture = id == "PIC" ? _parsePic(frame) : _parseApic(frame);
    if (picture != null) pictures.add(picture);
  }
  return pictures;
}

Uint8List _decodeFrame(Uint8List frame, int major, int flags) {
  var data = frame;
  if (major == 3) {
    if (flags & 0x0040 != 0) throw const FormatException("Encrypted frame");
    var start = 0;
    if (flags & 0x0080 != 0) start += 4; // decompressed size
    if (flags & 0x0020 != 0) start += 1; // group identifier
    data = Uint8List.sublistView(data, start);
    if (flags & 0x0080 != 0) data = Uint8List.fromList(zlib.decode(data));
  } else if (major == 4) {
    if (flags & 0x0004 != 0) throw const FormatException("Encrypted frame");
    var start = 0;
    if (flags & 0x0040 != 0) start += 1; // group identifier
    if (flags & 0x0001 != 0) start += 4; // data length indicator
    data = Uint8List.sublistView(data, start);
    if (flags & 0x0002 != 0) data = _removeUnsynchronisation(data);
    if (flags & 0x0008 != 0) data = Uint8List.fromList(zlib.decode(data));
  }
  return data;
}

/// Skips an encoded, terminated description and returns the next offset.
int _skipText(Uint8List data, int offset, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (var i = offset; i + 1 < data.length; i += 2) {
      if (data[i] == 0 && data[i + 1] == 0) return i + 2;
    }
  } else {
    for (var i = offset; i < data.length; i++) {
      if (data[i] == 0) return i + 1;
    }
  }
  throw const FormatException("Unterminated picture description");
}

(int, Uint8List)? _parseApic(Uint8List frame) {
  if (frame.length < 4) return null;
  final encoding = frame[0];
  var offset = 1;
  while (offset < frame.length && frame[offset] != 0) {
    offset++;
  }
  offset++; // MIME terminator
  if (offset >= frame.length) return null;
  final type = frame[offset++];
  offset = _skipText(frame, offset, encoding);
  return (type, Uint8List.sublistView(frame, offset));
}

(int, Uint8List)? _parsePic(Uint8List frame) {
  if (frame.length < 6) return null;
  final encoding = frame[0];
  final type = frame[4]; // after encoding and a three-letter image format
  final offset = _skipText(frame, 5, encoding);
  return (type, Uint8List.sublistView(frame, offset));
}

// -- MP4 --------------------------------------------------------------------

List<(int, Uint8List)> _mp4Pictures(String path) {
  final file = File(path).openSync();
  Uint8List? moov;
  try {
    final length = file.lengthSync();
    var position = 0;
    while (position + 8 <= length) {
      file.setPositionSync(position);
      final header = _Bytes(_readPrefix(file, 16));
      var size = header.u32();
      final type = header.ascii(4);
      var headerSize = 8;
      if (size == 1) {
        size = (header.u32() << 32) | header.u32();
        headerSize = 16;
      } else if (size == 0) {
        size = length - position;
      }
      if (size < headerSize) throw const FormatException("Invalid MP4 atom");
      if (type == "moov") {
        if (size > 64 * 1024 * 1024) throw const FormatException("moov too large");
        file.setPositionSync(position + headerSize);
        moov = _readPrefix(file, size - headerSize);
        break;
      }
      position += size;
    }
  } finally {
    file.closeSync();
  }
  if (moov == null) return const [];
  final udta = _childAtom(moov, "udta");
  final meta = udta == null ? null : _childAtom(udta, "meta");
  final ilst = meta == null ? null : _metaChild(meta, "ilst");
  final covr = ilst == null ? null : _childAtom(ilst, "covr");
  if (covr == null) return const [];
  return [
    for (final data in _childAtoms(covr, "data"))
      if (data.length >= 8) (_frontCover, Uint8List.sublistView(data, 8)),
  ];
}

Iterable<Uint8List> _childAtoms(Uint8List container, String wanted) sync* {
  var offset = 0;
  while (offset + 8 <= container.length) {
    final reader = _Bytes(container, offset);
    var size = reader.u32();
    final type = reader.ascii(4);
    var headerSize = 8;
    if (size == 1) {
      size = (reader.u32() << 32) | reader.u32();
      headerSize = 16;
    } else if (size == 0) {
      size = container.length - offset;
    }
    if (size < headerSize || offset + size > container.length) {
      throw const FormatException("Invalid MP4 atom");
    }
    if (type == wanted) {
      yield Uint8List.sublistView(container, offset + headerSize, offset + size);
    }
    offset += size;
  }
}

Uint8List? _childAtom(Uint8List container, String wanted) =>
    _childAtoms(container, wanted).firstOrNull;

/// iTunes writes "meta" as a full box (version and flags first); QuickTime
/// writes it as a plain container. Accept either.
Uint8List? _metaChild(Uint8List meta, String wanted) {
  for (final start in const [4, 0]) {
    if (meta.length < start) continue;
    try {
      final child = _childAtom(Uint8List.sublistView(meta, start), wanted);
      if (child != null) return child;
    } on FormatException {
      continue;
    }
  }
  return null;
}

// -- FLAC -------------------------------------------------------------------

(int, Uint8List) _flacPicture(Uint8List block) {
  final reader = _Bytes(block);
  final type = reader.u32();
  reader.take(reader.u32()); // MIME type
  reader.take(reader.u32()); // description
  reader.take(16); // width, height, depth, colors
  return (type, reader.take(reader.u32()));
}

List<(int, Uint8List)> _flacPictures(String path) {
  final file = File(path).openSync();
  try {
    final magic = _readPrefix(file, 4);
    if (magic.length < 4 || latin1.decode(magic) != "fLaC") return const [];
    final pictures = <(int, Uint8List)>[];
    while (true) {
      final header = _readPrefix(file, 4);
      if (header.length < 4) throw const FormatException("Truncated FLAC");
      final last = header[0] & 0x80 != 0;
      final type = header[0] & 0x7f;
      final length = _Bytes(header, 1).u24();
      if (type == 6) {
        final block = _readPrefix(file, length);
        if (block.length < length) throw const FormatException("Truncated FLAC");
        pictures.add(_flacPicture(block));
      } else {
        file.setPositionSync(file.positionSync() + length);
      }
      if (last) break;
    }
    return pictures;
  } finally {
    file.closeSync();
  }
}

// -- Ogg Opus / Vorbis --------------------------------------------------------

/// The first two packets of the first logical stream: identification and
/// comment headers. The comment packet can span many pages.
List<Uint8List> _oggHeaderPackets(RandomAccessFile file) {
  final packets = <Uint8List>[];
  var current = BytesBuilder(copy: false);
  int? serial;
  var totalBytes = 0;
  while (packets.length < 2) {
    final header = _readPrefix(file, 27);
    if (header.length < 27) throw const FormatException("Truncated Ogg stream");
    if (latin1.decode(header.sublist(0, 4)) != "OggS") {
      throw const FormatException("Invalid Ogg page");
    }
    final pageSerial = _Bytes(header, 14).u32le();
    final segmentCount = header[26];
    final table = _readPrefix(file, segmentCount);
    final pageLength = table.fold<int>(0, (sum, value) => sum + value);
    final body = _readPrefix(file, pageLength);
    if (table.length < segmentCount || body.length < pageLength) {
      throw const FormatException("Truncated Ogg page");
    }
    serial ??= pageSerial;
    if (pageSerial != serial) continue;
    var offset = 0;
    for (final segment in table) {
      current.add(Uint8List.sublistView(body, offset, offset + segment));
      offset += segment;
      totalBytes += segment;
      if (totalBytes > 3 * maxArtworkBytes) {
        throw const FormatException("Ogg comment header too large");
      }
      if (segment < 255) {
        packets.add(current.takeBytes());
        current = BytesBuilder(copy: false);
        if (packets.length == 2) break;
      }
    }
  }
  return packets;
}

List<(int, Uint8List)> _oggPictures(String path) {
  final file = File(path).openSync();
  final List<Uint8List> packets;
  try {
    packets = _oggHeaderPackets(file);
  } finally {
    file.closeSync();
  }
  final comment = packets[1];
  final reader = _Bytes(comment);
  if (comment.length >= 8 && latin1.decode(comment.sublist(0, 8)) == "OpusTags") {
    reader.offset = 8;
  } else if (comment.length >= 7 &&
      comment[0] == 3 &&
      latin1.decode(comment.sublist(1, 7)) == "vorbis") {
    reader.offset = 7;
  } else {
    return const [];
  }
  reader.take(reader.u32le()); // vendor
  final count = reader.u32le();
  final pictures = <(int, Uint8List)>[];
  const key = "metadata_block_picture=";
  for (var i = 0; i < count; i++) {
    final entry = reader.take(reader.u32le());
    if (entry.length <= key.length) continue;
    final name = latin1.decode(entry.sublist(0, key.length)).toLowerCase();
    if (name != key) continue;
    try {
      final decoded = base64.decode(latin1.decode(entry.sublist(key.length)).trim());
      final picture = _flacPicture(decoded);
      if (picture.$2.isNotEmpty) pictures.add(picture);
    } on FormatException {
      continue;
    }
  }
  return pictures;
}
