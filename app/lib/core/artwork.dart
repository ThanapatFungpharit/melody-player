/// Reads cover artwork and lyrics back from audio containers.
///
/// The downloader uses the artwork read-back as proof that yt-dlp burned the
/// thumbnail into the output before staged files are committed. Supported:
/// ID3v2.2–2.4 (MP3), MP4/M4A `covr`, FLAC PICTURE blocks, and
/// `METADATA_BLOCK_PICTURE` comments in Ogg Opus and Vorbis.
///
/// Lyrics come from ID3 `USLT`/`ULT` frames (and `TXXX` frames named
/// `LYRICS`, `UNSYNCEDLYRICS`, or `USLT`), MP4 `©lyr`, and `LYRICS` or
/// `UNSYNCEDLYRICS` Vorbis comments in FLAC and Ogg.
library;

import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:path/path.dart" as p;

import "id3.dart";

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
      ".m4a" || ".m4b" || ".mp4" || ".m4v" || ".mov" => _mp4Pictures(path),
      ".flac" => _flacPictures(path),
      ".ogg" || ".oga" || ".opus" => _oggPictures(path),
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

/// The lyrics text embedded in [path], or an empty string. Synced lyrics are
/// usually LRC text. Runs off the UI isolate.
Future<String> readEmbeddedLyrics(String path) =>
    Isolate.run(() => readEmbeddedLyricsSync(path));

String readEmbeddedLyricsSync(String path) {
  try {
    final text = switch (p.extension(path).toLowerCase()) {
      ".mp3" => _id3Lyrics(path),
      ".m4a" || ".m4b" || ".mp4" || ".m4v" || ".mov" => _mp4Lyrics(path),
      ".flac" => _vorbisLyrics(_flacComments(path)),
      ".ogg" || ".oga" || ".opus" => _vorbisLyrics(_oggComments(path)),
      _ => "",
    };
    return text.replaceAll("\u0000", "").trim();
  } on Object {
    // Missing or damaged tags simply mean no embedded lyrics.
    return "";
  }
}

const _vorbisLyricsKeys = ["lyrics", "unsyncedlyrics"];

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

  int u16() {
    _need(2);
    final value = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return value;
  }

  int u24() {
    _need(3);
    final value =
        (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2];
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
    final value = ByteData.sublistView(
      data,
      offset,
      offset + 4,
    ).getUint32(0, Endian.little);
    offset += 4;
    return value;
  }

  int syncsafe() {
    _need(4);
    final value = readSyncsafe(data, offset);
    offset += 4;
    return value;
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

List<(int, Uint8List)> _id3Pictures(String path) => [
  for (final (id, frame) in _id3Frames(path, const {"APIC", "PIC"}))
    ?(id == "PIC" ? _parsePic(frame) : _parseApic(frame)),
];

String _id3Lyrics(String path) {
  final frames = _id3Frames(path, const {"USLT", "ULT", "TXXX", "TXX"});
  for (final (id, frame) in frames) {
    if (id == "USLT" || id == "ULT") {
      final text = _parseUslt(frame);
      if (text.trim().isNotEmpty) return text;
    }
  }
  for (final (_, frame) in frames.where((item) => item.$1.startsWith("TX"))) {
    final (description, value) = parseTxxx(frame);
    if (id3LyricsDescriptions.contains(description.toLowerCase()) &&
        value.trim().isNotEmpty) {
      return value;
    }
  }
  return "";
}

/// Decoded frames whose ID is in [wanted], in tag order.
List<(String, Uint8List)> _id3Frames(String path, Set<String> wanted) {
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
  final body = (major < 4 && flags & 0x80 != 0)
      ? removeUnsynchronisation(tag)
      : tag;
  final reader = _Bytes(body);
  if (flags & 0x40 != 0 && major >= 3) {
    // Extended header: v2.3 size excludes itself; v2.4 size includes itself.
    final size = major == 4 ? reader.syncsafe() : reader.u32();
    reader.offset = major == 4 ? size : 4 + size;
  }
  final frames = <(String, Uint8List)>[];
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
    final frame = reader.take(size);
    if (!wanted.contains(id)) continue;
    frames.add((id, _decodeFrame(frame, major, frameFlags)));
  }
  return frames;
}

/// USLT (or v2.2 ULT): encoding, language, terminated description, text.
String _parseUslt(Uint8List frame) {
  if (frame.length < 5) return "";
  final encoding = frame[0];
  final start = skipId3Text(frame, 4, encoding);
  return decodeId3Text(Uint8List.sublistView(frame, start), encoding);
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
    if (flags & 0x0002 != 0) data = removeUnsynchronisation(data);
    if (flags & 0x0008 != 0) data = Uint8List.fromList(zlib.decode(data));
  }
  return data;
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
  offset = skipId3Text(frame, offset, encoding);
  return (type, Uint8List.sublistView(frame, offset));
}

(int, Uint8List)? _parsePic(Uint8List frame) {
  if (frame.length < 6) return null;
  final encoding = frame[0];
  final type = frame[4]; // after encoding and a three-letter image format
  final offset = skipId3Text(frame, 5, encoding);
  return (type, Uint8List.sublistView(frame, offset));
}

// -- MP4 --------------------------------------------------------------------

List<(int, Uint8List)> _mp4Pictures(String path) {
  final covr = switch (_mp4Ilst(path)) {
    final ilst? => _childAtom(ilst, "covr"),
    null => null,
  };
  if (covr == null) return const [];
  return [
    for (final data in _childAtoms(covr, "data"))
      if (data.length >= 8) (_frontCover, Uint8List.sublistView(data, 8)),
  ];
}

String _mp4Lyrics(String path) {
  final ilst = _mp4Ilst(path);
  // "©lyr": the copyright sign is one Latin-1 byte in atom names.
  final lyrics = ilst == null ? null : _childAtom(ilst, "\u00a9lyr");
  final data = lyrics == null ? null : _childAtom(lyrics, "data");
  if (data == null || data.length < 8) return "";
  return utf8.decode(Uint8List.sublistView(data, 8), allowMalformed: true);
}

/// The iTunes metadata list (`moov/udta/meta/ilst`), or null.
Uint8List? _mp4Ilst(String path) {
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
        if (size > 64 * 1024 * 1024) {
          throw const FormatException("moov too large");
        }
        file.setPositionSync(position + headerSize);
        moov = _readPrefix(file, size - headerSize);
        break;
      }
      position += size;
    }
  } finally {
    file.closeSync();
  }
  if (moov == null) return null;
  final udta = _childAtom(moov, "udta");
  final meta = udta == null ? null : _childAtom(udta, "meta");
  return meta == null ? null : _metaChild(meta, "ilst");
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
      yield Uint8List.sublistView(
        container,
        offset + headerSize,
        offset + size,
      );
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

List<(int, Uint8List)> _flacPictures(String path) => [
  for (final block in _flacBlocks(path, 6)) _flacPicture(block),
];

/// The FLAC VORBIS_COMMENT block's comments.
List<(String, Uint8List)> _flacComments(String path) => [
  for (final block in _flacBlocks(path, 4)) ..._vorbisComments(_Bytes(block)),
];

/// Metadata blocks of [wantedType], in file order.
List<Uint8List> _flacBlocks(String path, int wantedType) {
  final file = File(path).openSync();
  try {
    final magic = _readPrefix(file, 4);
    if (magic.length < 4 || latin1.decode(magic) != "fLaC") return const [];
    final blocks = <Uint8List>[];
    while (true) {
      final header = _readPrefix(file, 4);
      if (header.length < 4) throw const FormatException("Truncated FLAC");
      final last = header[0] & 0x80 != 0;
      final type = header[0] & 0x7f;
      final length = _Bytes(header, 1).u24();
      if (type == wantedType) {
        final block = _readPrefix(file, length);
        if (block.length < length) {
          throw const FormatException("Truncated FLAC");
        }
        blocks.add(block);
      } else {
        file.setPositionSync(file.positionSync() + length);
      }
      if (last) break;
    }
    return blocks;
  } finally {
    file.closeSync();
  }
}

/// A Vorbis comment list: vendor string, then `KEY=value` entries. Keys are
/// returned lower-cased.
List<(String, Uint8List)> _vorbisComments(_Bytes reader) {
  reader.take(reader.u32le()); // vendor
  final count = reader.u32le();
  final comments = <(String, Uint8List)>[];
  for (var i = 0; i < count; i++) {
    final entry = reader.take(reader.u32le());
    final separator = entry.indexOf(0x3d); // "="
    if (separator <= 0) continue;
    comments.add((
      latin1.decode(entry.sublist(0, separator)).toLowerCase(),
      Uint8List.sublistView(entry, separator + 1),
    ));
  }
  return comments;
}

String _vorbisLyrics(List<(String, Uint8List)> comments) {
  for (final key in _vorbisLyricsKeys) {
    for (final (name, value) in comments) {
      if (name != key) continue;
      final text = utf8.decode(value, allowMalformed: true);
      if (text.trim().isNotEmpty) return text;
    }
  }
  return "";
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
  final pictures = <(int, Uint8List)>[];
  for (final (name, value) in _oggComments(path)) {
    if (name != "metadata_block_picture") continue;
    try {
      final picture = _flacPicture(base64.decode(latin1.decode(value).trim()));
      if (picture.$2.isNotEmpty) pictures.add(picture);
    } on FormatException {
      continue;
    }
  }
  return pictures;
}

/// The Opus or Vorbis comment header's comments.
List<(String, Uint8List)> _oggComments(String path) {
  final file = File(path).openSync();
  final List<Uint8List> packets;
  try {
    packets = _oggHeaderPackets(file);
  } finally {
    file.closeSync();
  }
  final comment = packets[1];
  final reader = _Bytes(comment);
  if (comment.length >= 8 &&
      latin1.decode(comment.sublist(0, 8)) == "OpusTags") {
    reader.offset = 8;
  } else if (comment.length >= 7 &&
      comment[0] == 3 &&
      latin1.decode(comment.sublist(1, 7)) == "vorbis") {
    reader.offset = 7;
  } else {
    return const [];
  }
  return _vorbisComments(reader);
}
