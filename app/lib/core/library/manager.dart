import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:sqlite3/sqlite3.dart";
import "package:uuid/uuid.dart";

import "../media.dart";
import "../storage.dart";
import "models.dart";

const _schemaVersion = 2;
// Row order (rowid) preserves insertion order for tracks and playlists.
const _schema = """
CREATE TABLE library_meta (key TEXT PRIMARY KEY, value ANY) STRICT;
CREATE TABLE tracks (
    id BLOB PRIMARY KEY,
    filename TEXT NOT NULL,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    added_at REAL NOT NULL,
    content_hash BLOB NOT NULL
) STRICT;
CREATE TABLE playlists (
    id BLOB PRIMARY KEY,
    name TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT ''
) STRICT;
CREATE TABLE playlist_tracks (
    playlist_id BLOB NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    track_id BLOB NOT NULL REFERENCES tracks (id) ON DELETE CASCADE,
    PRIMARY KEY (playlist_id, position)
) STRICT, WITHOUT ROWID;
CREATE INDEX playlist_tracks_by_track ON playlist_tracks (track_id);
""";

const _uuid = Uuid();
const _zeroHash =
    "0000000000000000000000000000000000000000000000000000000000000000";

// Earlier releases stored any 128-bit value as an ID, so stored IDs need not
// be RFC 4122 compliant.
Uint8List uuidBytes(String id) => Uint8List.fromList(
  Uuid.parse(id, validationMode: ValidationMode.nonStrict),
);

/// Lowercase hex digits of every byte, as ASCII code units. Loading the
/// library formats two values per track.
final Uint16List _hexPairs = Uint16List.fromList([
  for (var byte = 0; byte < 256; byte++)
    _hexDigit(byte >> 4) << 8 | _hexDigit(byte & 15),
]);

int _hexDigit(int value) => value < 10 ? 0x30 + value : 0x61 + value - 10;

const _dash = 0x2d;

String uuidString(List<int> bytes) {
  if (bytes.length != 16) return Uuid.unparse(bytes);
  final text = Uint8List(36);
  var at = 0;
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) text[at++] = _dash;
    final pair = _hexPairs[bytes[i]];
    text[at++] = pair >> 8;
    text[at++] = pair & 255;
  }
  return String.fromCharCodes(text);
}

/// Whether [value] is already canonical UUID text, which nearly every ID
/// is. Library reads check an ID for each row, so this avoids parsing it.
bool _isCanonicalUuid(String value) {
  if (value.length != 36) return false;
  for (var i = 0; i < 36; i++) {
    final unit = value.codeUnitAt(i);
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (unit != _dash) return false;
    } else if (!(unit >= 0x30 && unit <= 0x39) &&
        !(unit >= 0x61 && unit <= 0x66)) {
      return false;
    }
  }
  return true;
}

/// Canonical lowercase UUID text, or null when [value] is not a UUID.
String? normalizeUuid(String value) {
  if (_isCanonicalUuid(value)) return value;
  try {
    return Uuid.unparse(
      Uuid.parse(value.trim(), validationMode: ValidationMode.nonStrict),
    );
  } on FormatException {
    return null;
  }
}

String _canonicalId(String value) {
  final id = normalizeUuid(value);
  if (id == null) throw ArgumentError("Invalid identifier: $value");
  return id;
}

final _sha256Hex = RegExp(r"^[0-9a-fA-F]{64}$");

Uint8List _hashBytes(Track track) {
  final hex = track.contentHash;
  if (!_sha256Hex.hasMatch(hex)) {
    throw FormatException("Invalid content hash for track ${track.id}");
  }
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

String _hex(List<int> bytes) {
  final text = Uint8List(bytes.length * 2);
  for (var i = 0; i < bytes.length; i++) {
    final pair = _hexPairs[bytes[i]];
    text[i * 2] = pair >> 8;
    text[i * 2 + 1] = pair & 255;
  }
  return String.fromCharCodes(text);
}

List<Object?> _trackRow(Track track) => [
  uuidBytes(track.id),
  track.filename,
  track.source,
  track.title,
  track.addedAt,
  _hashBytes(track),
];

/// Durable owner of track records, file references, hashes, and playlists.
///
/// Mutations change the in-memory model, commit one SQLite transaction, and
/// restore the model when the commit fails. Readers receive copies.
class MusicManager {
  MusicManager._(
    this.metadataPath,
    this._musicFolder,
    this._musicRoot,
    this._additionalRoots,
    this._db,
  );

  final String metadataPath;
  String _musicFolder;
  String _musicRoot;
  final List<String> _additionalRoots;
  final SqliteStore _db;

  /// Serializes file allocation, deduplication, and registration by services.
  final AsyncMutex mutation = AsyncMutex();

  Map<String, Track> _tracks = {};
  Map<String, Playlist> _playlists = {};
  Map<String, Set<String>> _sourceIndex = {};
  Map<String, Set<String>> _contentIndex = {};
  List<String>? _newest;
  Map<String, int>? _newestRank;
  List<String>? _byTitle;
  List<String>? _oldest;
  Map<String, String>? _searchText;
  final Map<String, String> _validatedPaths = {};

  /// Opens the library. [legacyMetadataPath] names a pre-SQLite `MMD1` file
  /// imported once in the transaction that creates the schema.
  /// [syncInBackground] keeps commits from waiting for the disk on the
  /// calling isolate (see [SqliteStore]). [moveJournal] is where
  /// [moveMusicFolder] records a move, so one a crash interrupted is settled
  /// here: its files go to whichever folder [musicFolder] is.
  static MusicManager open(
    String metadataPath,
    String musicFolder, {
    List<String> additionalMusicFolders = const [],
    String? legacyMetadataPath,
    bool syncInBackground = false,
    String? moveJournal,
  }) {
    Directory(musicFolder).createSync(recursive: true);
    Directory(p.dirname(metadataPath)).createSync(recursive: true);
    final root = _resolve(musicFolder);
    final additional = [
      for (final folder in additionalMusicFolders) _resolve(folder),
    ];
    final db = SqliteStore.open(
      metadataPath,
      syncInBackground: syncInBackground,
    );
    final manager = MusicManager._(
      metadataPath,
      musicFolder,
      root,
      additional,
      db,
    ).._moveJournal = moveJournal;
    try {
      manager._open(legacyMetadataPath);
    } catch (_) {
      unawaited(db.close());
      rethrow;
    }
    manager._settleInterruptedMove();
    return manager;
  }

  String? _moveJournal;

  /// Finishes or undoes a [moveMusicFolder] that a crash interrupted, so
  /// every recorded file is in the current music folder again. A file that
  /// cannot be moved keeps the journal for the next launch.
  void _settleInterruptedMove() {
    final journal = _moveJournal;
    if (journal == null || !File(journal).existsSync()) return;
    var settled = true;
    try {
      final data = jsonDecode(File(journal).readAsStringSync());
      final from = data is Map ? data["from"] : null;
      final to = data is Map ? data["to"] : null;
      final files = data is Map ? data["files"] : null;
      if (from is! String || to is! String || files is! List) {
        throw const FormatException("Invalid music folder move journal");
      }
      final String source;
      if (pathKey(_musicRoot) == pathKey(from)) {
        source = to;
      } else if (pathKey(_musicRoot) == pathKey(to)) {
        source = from;
      } else {
        // The music folder changed some other way since; nothing to settle.
        files.clear();
        source = to;
      }
      for (final name in files.whereType<String>()) {
        final target = p.join(_musicRoot, name);
        final stray = p.join(source, name);
        if (p.isAbsolute(name) ||
            !p.isWithin(_musicRoot, target) ||
            !p.isWithin(source, stray) ||
            File(target).existsSync() ||
            !File(stray).existsSync()) {
          continue;
        }
        try {
          _moveFileSync(stray, target);
        } on FileSystemException catch (error) {
          debugPrint("Could not move $stray back to $target: $error");
          settled = false;
        }
      }
    } on Object catch (error) {
      debugPrint("Discarding the music folder move journal: $error");
    }
    if (settled) {
      try {
        File(journal).deleteSync();
      } on FileSystemException catch (error) {
        debugPrint("Could not remove $journal: $error");
      }
    }
  }

  static void _moveFileSync(String source, String target) {
    Directory(p.dirname(target)).createSync(recursive: true);
    try {
      File(source).renameSync(target);
      return;
    } on FileSystemException {
      // Another volume: copied below.
    }
    final temporary = temporarySibling(target);
    try {
      File(source).copySync(temporary);
      File(temporary).renameSync(target);
    } finally {
      if (File(temporary).existsSync()) File(temporary).deleteSync();
    }
    File(source).deleteSync();
  }

  Future<void> close() => _db.close();

  /// Where managed tracks are stored; their filenames are relative to it.
  String get musicFolder => _musicFolder;

  /// [musicFolder] with links resolved: the form of every path the library
  /// returns, such as [trackPath].
  String get musicRoot => _musicRoot;

  /// Moves the library to [folder]. Stored filenames are relative to the
  /// music folder, so this is only possible while the library has no
  /// tracks; callers hold [mutation] so no import can race the check.
  void changeMusicFolder(String folder) {
    if (_tracks.isNotEmpty) {
      throw StateError(
        "The music folder can only be changed while the library is empty",
      );
    }
    Directory(folder).createSync(recursive: true);
    _musicFolder = folder;
    _musicRoot = _resolve(folder);
    _validatedPaths.clear();
  }

  /// Moves every file stored in the music folder, with the [companions] of
  /// each (such as a lyrics file beside it), to [folder] and makes it the
  /// music folder. Stored filenames stay valid because they are relative.
  /// Tracks whose file is already missing stay missing. A failure moves the
  /// files back and keeps the current folder. Callers hold [mutation] and
  /// make sure nothing holds a track file open. Returns the files moved.
  Future<int> moveMusicFolder(
    String folder, {
    Iterable<String> Function(String path) companions = _noCompanions,
  }) async {
    final from = _musicRoot;
    final to = _resolve(folder);
    if (p.equals(from, to)) {
      changeMusicFolder(folder);
      return 0;
    }
    if (p.isWithin(from, to) || p.isWithin(to, from)) {
      throw const FormatException(
        "The new music folder can't be inside the current one, or contain it.",
      );
    }
    final moves = <(String, String)>[];
    final targets = <String>{};
    for (final track in _tracks.values) {
      if (p.isAbsolute(track.filename)) continue;
      final source = p.join(from, track.filename);
      for (final path in [source, ...companions(source)]) {
        if (!await File(path).exists()) continue;
        final target = p.join(to, p.relative(path, from: from));
        // Two tracks may share one file.
        if (!targets.add(pathKey(target))) continue;
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw FormatException(
            "The new music folder already has a file named "
            "“${p.relative(path, from: from)}”.",
          );
        }
        moves.add((path, target));
      }
    }
    await Directory(to).create(recursive: true);
    final journal = _moveJournal;
    if (journal != null) {
      // Lets the next launch put files back where the saved settings say
      // the library is, should the process end before they are saved.
      await atomicWrite(
        journal,
        utf8.encode(
          jsonEncode({
            "from": from,
            "to": to,
            "files": [
              for (final (path, _) in moves) p.relative(path, from: from),
            ],
          }),
        ),
      );
    }
    final done = <(String, String)>[];
    try {
      for (final move in moves) {
        await moveFile(move.$1, move.$2);
        done.add(move);
      }
    } catch (_) {
      var restored = true;
      for (final (source, target) in done.reversed) {
        try {
          await moveFile(target, source);
        } on FileSystemException catch (error) {
          debugPrint("Could not move $target back to $source: $error");
          restored = false;
        }
      }
      if (journal != null && restored) await deleteQuietly(journal);
      rethrow;
    }
    _musicFolder = folder;
    _musicRoot = to;
    _validatedPaths.clear();
    return moves.length;
  }

  static Iterable<String> _noCompanions(String path) => const [];

  /// Completes once every committed change is on durable storage.
  Future<void> flushed() => _db.flushed();

  // -- persistence -------------------------------------------------------
  void _open(String? legacyPath) {
    if (!_db.hasTable("library_meta")) {
      _initialize(legacyPath);
    } else {
      // A crash after the import committed but before the rename.
      if (legacyPath != null) retireLegacyFile(legacyPath);
      _addPlaylistSources();
      _load();
    }
    _rebuildIndexes();
  }

  void _initialize(String? legacyPath) {
    if (legacyPath != null) _loadLegacy(legacyPath);
    _db.transaction((db) {
      db.execute(_schema);
      db.execute("INSERT INTO library_meta (key, value) VALUES ('schema', ?)", [
        _schemaVersion,
      ]);
      final insert = db.prepare("INSERT INTO tracks VALUES (?, ?, ?, ?, ?, ?)");
      try {
        for (final track in _tracks.values) {
          insert.execute(_trackRow(track));
        }
      } finally {
        insert.close();
      }
      for (final playlist in _playlists.values) {
        db.execute(
          "INSERT INTO playlists (id, name, source) VALUES (?, ?, ?)",
          [uuidBytes(playlist.id), playlist.name, playlist.source],
        );
        _writePlaylistTracks(db, playlist);
      }
    });
    if (legacyPath != null) retireLegacyFile(legacyPath);
  }

  /// Schema 1 had no `source` column. Adding one with a default leaves the
  /// database readable by releases that name only the columns they know.
  void _addPlaylistSources() {
    final columns = _db.query("PRAGMA table_info(playlists)");
    if (columns.any((column) => column["name"] == "source")) return;
    _db.transaction((db) {
      db.execute(
        "ALTER TABLE playlists ADD COLUMN source TEXT NOT NULL DEFAULT ''",
      );
      db.execute("UPDATE library_meta SET value = ? WHERE key = 'schema'", [
        _schemaVersion,
      ]);
    });
  }

  void _load() {
    final tracks = <String, Track>{};
    for (final row in _db.query(
      "SELECT id, filename, source, title, added_at, content_hash "
      "FROM tracks ORDER BY rowid",
    )) {
      final id = uuidString(row["id"] as List<int>);
      tracks[id] = Track(
        id: id,
        filename: row["filename"] as String,
        source: row["source"] as String,
        title: row["title"] as String,
        addedAt: (row["added_at"] as num).toDouble(),
        contentHash: _hex(row["content_hash"] as List<int>),
      );
    }
    final playlists = <String, Playlist>{};
    for (final row in _db.query(
      "SELECT id, name, source FROM playlists ORDER BY rowid",
    )) {
      final id = uuidString(row["id"] as List<int>);
      playlists[id] = Playlist(
        id: id,
        name: row["name"] as String,
        source: row["source"] as String,
      );
    }
    for (final row in _db.query(
      "SELECT playlist_id, track_id FROM playlist_tracks "
      "ORDER BY playlist_id, position",
    )) {
      playlists[uuidString(row["playlist_id"] as List<int>)]?.trackIds.add(
        uuidString(row["track_id"] as List<int>),
      );
    }
    _tracks = tracks;
    _playlists = playlists;
  }

  void _loadLegacy(String path) {
    final file = File(path);
    if (!file.existsSync()) return;
    final data = file.readAsBytesSync();
    if (data.isEmpty) return;
    final reader = _LegacyReader(data, path);
    final (version, trackCount) = reader.header();
    final tracks = <String, Track>{};
    for (var i = 0; i < trackCount; i++) {
      final id = uuidString(reader.bytes(16));
      final addedAt = reader.float64();
      final filename = reader.string();
      final source = reader.string();
      final title = version >= 2 ? reader.string() : "";
      // A durable placeholder for a legacy file that was not hashed: it matches
      // no real file when looking for duplicates.
      final hash = version >= 3 ? _hex(reader.bytes(32)) : _zeroHash;
      tracks[id] = Track(
        id: id,
        filename: filename,
        source: source,
        title: title,
        addedAt: addedAt,
        contentHash: hash,
      );
    }
    final playlists = <String, Playlist>{};
    final playlistCount = reader.uint32();
    for (var i = 0; i < playlistCount; i++) {
      final id = uuidString(reader.bytes(16));
      final name = reader.string();
      final count = reader.uint32();
      final trackIds = [
        for (var j = 0; j < count; j++) uuidString(reader.bytes(16)),
      ];
      playlists[id] = Playlist(
        id: id,
        name: name,
        // Playlists hold each track once; the legacy format did not enforce it.
        trackIds: trackIds.where(tracks.containsKey).toSet().toList(),
      );
    }
    if (!reader.atEnd) {
      throw FormatException("$path contains trailing music metadata");
    }
    _tracks = tracks;
    _playlists = playlists;
    if (version < 3) _captureLegacyHashes();
  }

  void _captureLegacyHashes() {
    for (final track in _tracks.values) {
      try {
        final path = _pathForFilename(track.filename);
        if (File(path).existsSync()) track.contentHash = sha256FileSync(path);
      } on Object catch (error) {
        debugPrint("Could not hash legacy track ${track.id}: $error");
      }
    }
  }

  /// Applies one change durably, then invalidates derived read state.
  void _commit(void Function(Database db) write, {bool tracksChanged = true}) {
    _db.transaction(write);
    if (tracksChanged) _invalidateTrackViews();
  }

  void _invalidateTrackViews() {
    _newest = null;
    _newestRank = null;
    _byTitle = null;
    _oldest = null;
    _searchText = null;
  }

  static void _writePlaylistTracks(Database db, Playlist playlist) {
    final id = uuidBytes(playlist.id);
    db.execute("DELETE FROM playlist_tracks WHERE playlist_id = ?", [id]);
    final insert = db.prepare(
      "INSERT INTO playlist_tracks (playlist_id, position, track_id) "
      "VALUES (?, ?, ?)",
    );
    try {
      for (var position = 0; position < playlist.trackIds.length; position++) {
        insert.execute([id, position, uuidBytes(playlist.trackIds[position])]);
      }
    } finally {
      insert.close();
    }
  }

  static void _appendPlaylistTrack(
    Database db,
    String playlistId,
    String trackId,
  ) {
    // Positions only order rows; deletions may leave gaps, so append after
    // the current maximum instead of at the in-memory length.
    final playlist = uuidBytes(playlistId);
    db.execute(
      "INSERT INTO playlist_tracks (playlist_id, position, track_id) "
      "SELECT ?, COALESCE(MAX(position), -1) + 1, ? FROM playlist_tracks "
      "WHERE playlist_id = ?",
      [playlist, uuidBytes(trackId), playlist],
    );
  }

  // -- tracks --------------------------------------------------------------
  Future<String> _validatedFileHash(String path) async {
    final file = File(path);
    final FileStat status;
    try {
      status = await file.stat();
    } on FileSystemException {
      throw PathNotFoundException(path, const OSError("Track file is missing"));
    }
    if (status.type != FileSystemEntityType.file) {
      throw PathNotFoundException(path, const OSError("Track file is missing"));
    }
    if (status.size <= 0) throw const FormatException("Track file is empty");
    return sha256File(path);
  }

  /// Records an existing file inside a managed folder and captures its hash.
  /// The file is never copied, moved, or modified.
  Future<String> addTrack(
    String filename, {
    String source = "",
    String title = "",
  }) async {
    final relative = relativeFilename(filename);
    final digest = await _validatedFileHash(_pathForFilename(relative));
    final track = Track(
      id: _uuid.v4(),
      filename: relative,
      source: source,
      title: title.trim(),
      addedAt: unixSeconds(),
      contentHash: digest,
    );
    _tracks[track.id] = track;
    _indexTrack(track);
    try {
      _commit((db) {
        db.execute(
          "INSERT INTO tracks VALUES (?, ?, ?, ?, ?, ?)",
          _trackRow(track),
        );
      });
    } catch (_) {
      _tracks.remove(track.id);
      _unindexTrack(track);
      _invalidateTrackViews();
      rethrow;
    }
    return track.id;
  }

  /// Points an existing track at a verified replacement file, keeping its
  /// identity and playlist membership.
  Future<void> replaceTrackFile(String trackId, String filename) async {
    final relative = relativeFilename(filename);
    final digest = await _validatedFileHash(_pathForFilename(relative));
    final track = _getTrack(trackId);
    final previousFilename = track.filename;
    final previousHash = track.contentHash;
    if (previousFilename == relative && previousHash == digest) return;
    _removeIndexEntry(_contentIndex, previousHash, track.id);
    track.filename = relative;
    track.contentHash = digest;
    _contentIndex.putIfAbsent(digest, () => {}).add(track.id);
    try {
      _commit((db) {
        db.execute(
          "UPDATE tracks SET filename = ?, content_hash = ? WHERE id = ?",
          [track.filename, _hashBytes(track), uuidBytes(track.id)],
        );
      });
    } catch (_) {
      _removeIndexEntry(_contentIndex, digest, track.id);
      track.filename = previousFilename;
      track.contentHash = previousHash;
      if (previousHash.isNotEmpty) {
        _contentIndex.putIfAbsent(previousHash, () => {}).add(track.id);
      }
      rethrow;
    }
  }

  void updateTrack(String trackId, {String? title, String? source}) {
    final normalizedTitle = title?.trim();
    if (normalizedTitle != null && normalizedTitle.isEmpty) {
      throw const FormatException("Song title cannot be empty");
    }
    final track = _getTrack(trackId);
    final previousTitle = track.title;
    final previousSource = track.source;
    final titleChanged =
        normalizedTitle != null && normalizedTitle != track.title;
    final sourceChanged = source != null && source != track.source;
    if (!titleChanged && !sourceChanged) return;
    if (titleChanged) track.title = normalizedTitle;
    if (sourceChanged) {
      _unindexSource(track);
      track.source = source;
      _indexSource(track);
    }
    try {
      _commit((db) {
        db.execute("UPDATE tracks SET title = ?, source = ? WHERE id = ?", [
          track.title,
          track.source,
          uuidBytes(track.id),
        ]);
      });
    } catch (_) {
      if (sourceChanged) {
        _unindexSource(track);
        track.source = previousSource;
        _indexSource(track);
      }
      track.title = previousTitle;
      rethrow;
    }
  }

  /// Deletes the record and its playlist references; the file is untouched.
  void deleteTrack(String trackId) {
    final track = _getTrack(trackId);
    final removed = <(Playlist, List<String>)>[];
    for (final playlist in _playlists.values) {
      if (!playlist.trackIds.contains(track.id)) continue;
      // Every row: the database cascade removes them all.
      removed.add((playlist, playlist.trackIds));
      playlist.trackIds = [
        for (final id in playlist.trackIds)
          if (id != track.id) id,
      ];
    }
    _tracks.remove(track.id);
    try {
      // Playlist references cascade with the track row.
      _commit((db) {
        db.execute("DELETE FROM tracks WHERE id = ?", [uuidBytes(track.id)]);
      });
    } catch (_) {
      _tracks[track.id] = track;
      _invalidateTrackViews();
      for (final (playlist, trackIds) in removed) {
        playlist.trackIds = trackIds;
      }
      rethrow;
    }
    _unindexTrack(track);
  }

  /// Removes every track and playlist record without deleting audio files.
  (int, int) clearLibrary() {
    final trackCount = _tracks.length;
    final playlistCount = _playlists.length;
    if (trackCount == 0 && playlistCount == 0) return (0, 0);
    final previous = (_tracks, _playlists, _sourceIndex, _contentIndex);
    _tracks = {};
    _playlists = {};
    _sourceIndex = {};
    _contentIndex = {};
    try {
      _commit((db) {
        db.execute("DELETE FROM playlists");
        db.execute("DELETE FROM tracks");
      });
    } catch (_) {
      _tracks = previous.$1;
      _playlists = previous.$2;
      _sourceIndex = previous.$3;
      _contentIndex = previous.$4;
      _invalidateTrackViews();
      rethrow;
    }
    return (trackCount, playlistCount);
  }

  List<String> get _newestIds {
    return _newest ??= (_tracks.keys.toList()
      ..sort((a, b) => _tracks[b]!.addedAt.compareTo(_tracks[a]!.addedAt)));
  }

  Map<String, int> get _rank {
    return _newestRank ??= {
      for (final (index, id) in _newestIds.indexed) id: index,
    };
  }

  Map<String, String> get _search {
    return _searchText ??= {
      for (final track in _tracks.values)
        track.id: track.displayTitle.toLowerCase(),
    };
  }

  /// Every track ID in [sort] order. Pages ask on every rebuild, so the
  /// orders are kept until the tracks change. The sorts are stable: tracks
  /// that compare equal stay newest first.
  List<String> _ordered(String sort) => switch (sort) {
    "title" => _byTitle ??= () {
      final titles = {
        for (final track in _tracks.values)
          track.id:
              (track.title.isNotEmpty
                      ? track.title
                      : p.basenameWithoutExtension(track.filename))
                  .toLowerCase(),
      };
      final ids = List.of(_newestIds);
      mergeSort(ids, compare: (a, b) => titles[a]!.compareTo(titles[b]!));
      return ids;
    }(),
    "oldest" => _oldest ??= () {
      final ids = List.of(_newestIds);
      mergeSort(
        ids,
        compare: (a, b) => _tracks[a]!.addedAt.compareTo(_tracks[b]!.addedAt),
      );
      return ids;
    }(),
    _ => _newestIds,
  };

  /// Every track's canonical ID, for callers that need no track details.
  /// A live view: do not change the library while iterating it.
  Iterable<String> get trackIds => _tracks.keys;

  /// Tracks newest first.
  List<Track> listTracks({int? limit}) {
    final ids = _newestIds;
    final end = limit == null ? ids.length : limit.clamp(0, ids.length);
    return [for (final id in ids.take(end)) _tracks[id]!.copy()];
  }

  /// Selected tracks in library order without scanning the catalog.
  List<Track> tracksByIds(Iterable<String> trackIds, {int? limit}) {
    if (limit != null && limit <= 0) return const [];
    final rank = _rank;
    final selected = <String>{
      for (final id in trackIds)
        if (normalizeUuid(id) case final normalized?)
          if (rank.containsKey(normalized)) normalized,
    }.toList()..sort((a, b) => rank[a]!.compareTo(rank[b]!));
    final end = limit == null
        ? selected.length
        : limit.clamp(0, selected.length);
    return [for (final id in selected.take(end)) _tracks[id]!.copy()];
  }

  (int, int) counts() => (_tracks.length, _playlists.length);

  Track getTrack(String trackId) => _getTrack(trackId).copy();

  bool hasTrack(String trackId) {
    final id = normalizeUuid(trackId);
    return id != null && _tracks.containsKey(id);
  }

  /// Every track ID in [sort] order: `recent`, `oldest`, or `title`. Pages ask
  /// on every change, so the list is shared: do not change it.
  List<String> orderedTrackIds(String sort) => _ordered(sort);

  /// Whether [trackId]'s title holds [needle], in lower case.
  bool titleContains(String trackId, String needle) =>
      _search[trackId]?.contains(needle) ?? false;

  Track? findTrackBySource(String source) {
    final ids = _sourceIndex[sourceKey(source)];
    return ids == null || ids.isEmpty ? null : _tracks[ids.first]!.copy();
  }

  /// The track with the same bytes as [path], if one exists.
  Future<Track?> findTrackByContent(String path) async {
    final digest = await sha256File(path);
    final ids = _contentIndex[digest];
    return ids == null || ids.isEmpty ? null : _tracks[ids.first]!.copy();
  }

  String trackPath(String trackId) =>
      _pathForFilename(_getTrack(trackId).filename);

  /// Whether another library record still owns [filename]: an absolute path,
  /// or a name relative to [musicFolder].
  bool isPathReferenced(String filename, {String? excluding}) {
    final String target;
    try {
      target = pathKey(relativeFilename(filename));
    } on ArgumentError {
      return false;
    }
    final excluded = excluding == null ? null : normalizeUuid(excluding);
    return _tracks.values.any(
      (track) => track.id != excluded && pathKey(track.filename) == target,
    );
  }

  // -- file checks ---------------------------------------------------------
  /// Why [trackId] has no usable file, or null when its file is there and not
  /// empty. The recorded hash plays no part: it finds duplicates, and a file
  /// edited elsewhere (new tags, say) is still this track's.
  Future<TrackFileProblem?> checkTrackFile(String trackId) async {
    final track = getTrack(trackId);
    final String path;
    try {
      path = _pathForFilename(track.filename);
    } on ArgumentError catch (error) {
      return TrackFileProblem(
        track.id,
        track.filename,
        "invalid_path",
        "${error.message}",
      );
    }
    final FileStat status;
    try {
      status = await File(path).stat();
    } on FileSystemException catch (error) {
      return TrackFileProblem(
        track.id,
        track.filename,
        "unreadable",
        "Cannot read $path: $error",
      );
    }
    if (status.type == FileSystemEntityType.notFound) {
      return TrackFileProblem(
        track.id,
        track.filename,
        "missing",
        "Missing file: $path",
      );
    }
    if (status.type != FileSystemEntityType.file) {
      return TrackFileProblem(
        track.id,
        track.filename,
        "missing",
        "Expected a file but found: $path",
      );
    }
    if (status.size <= 0) {
      return TrackFileProblem(
        track.id,
        track.filename,
        "empty",
        "Audio file is empty: $path",
      );
    }
    return null;
  }

  // -- playlists -----------------------------------------------------------
  List<Playlist> listPlaylists() => [
    for (final playlist in _playlists.values) playlist.copy(),
  ];

  Playlist getPlaylist(String playlistId) => _getPlaylist(playlistId).copy();

  bool hasPlaylist(String playlistId) {
    final id = normalizeUuid(playlistId);
    return id != null && _playlists.containsKey(id);
  }

  /// The playlist imported from [source], if any.
  Playlist? findPlaylistBySource(String source) {
    for (final playlist in _playlists.values) {
      if (playlist.source == source) return playlist.copy();
    }
    return null;
  }

  String createPlaylist(String name, {String source = ""}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException("Playlist name cannot be empty");
    }
    final playlist = Playlist(id: _uuid.v4(), name: trimmed, source: source);
    _playlists[playlist.id] = playlist;
    try {
      _commit((db) {
        db.execute(
          "INSERT INTO playlists (id, name, source) VALUES (?, ?, ?)",
          [uuidBytes(playlist.id), trimmed, source],
        );
      }, tracksChanged: false);
    } catch (_) {
      _playlists.remove(playlist.id);
      rethrow;
    }
    return playlist.id;
  }

  void renamePlaylist(String playlistId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException("Playlist name cannot be empty");
    }
    final playlist = _getPlaylist(playlistId);
    final previous = playlist.name;
    if (previous == trimmed) return;
    playlist.name = trimmed;
    try {
      _commit((db) {
        db.execute("UPDATE playlists SET name = ? WHERE id = ?", [
          trimmed,
          uuidBytes(playlist.id),
        ]);
      }, tracksChanged: false);
    } catch (_) {
      playlist.name = previous;
      rethrow;
    }
  }

  void deletePlaylist(String playlistId) {
    final playlist = _getPlaylist(playlistId);
    final previous = _playlists;
    _playlists = Map.of(previous)..remove(playlist.id);
    try {
      _commit((db) {
        db.execute("DELETE FROM playlists WHERE id = ?", [
          uuidBytes(playlist.id),
        ]);
      }, tracksChanged: false);
    } catch (_) {
      _playlists = previous;
      rethrow;
    }
  }

  /// Deletes every playlist while preserving all library tracks.
  int clearPlaylists() {
    final count = _playlists.length;
    if (count == 0) return 0;
    final previous = _playlists;
    _playlists = {};
    try {
      _commit(
        (db) => db.execute("DELETE FROM playlists"),
        tracksChanged: false,
      );
    } catch (_) {
      _playlists = previous;
      rethrow;
    }
    return count;
  }

  List<Track> playlistTracks(String playlistId) => [
    for (final id in _getPlaylist(playlistId).trackIds)
      if (_tracks[id] case final track?) track.copy(),
  ];

  /// Returns false when the playlist already holds the track.
  bool addToPlaylist(String playlistId, String trackId) {
    final playlist = _getPlaylist(playlistId);
    final track = _getTrack(trackId);
    if (playlist.trackIds.contains(track.id)) return false;
    playlist.trackIds.add(track.id);
    try {
      _commit(
        (db) => _appendPlaylistTrack(db, playlist.id, track.id),
        tracksChanged: false,
      );
    } catch (_) {
      playlist.trackIds.removeLast();
      rethrow;
    }
    return true;
  }

  /// Adds several existing tracks with one atomic metadata write.
  int addTracksToPlaylist(String playlistId, Iterable<String> trackIds) {
    final playlist = _getPlaylist(playlistId);
    final existing = playlist.trackIds.toSet();
    final additions = <String>[];
    for (final trackId in trackIds) {
      final id = _getTrack(trackId).id;
      if (existing.add(id)) additions.add(id);
    }
    if (additions.isEmpty) return 0;
    final previous = List.of(playlist.trackIds);
    playlist.trackIds.addAll(additions);
    try {
      _commit((db) => _writePlaylistTracks(db, playlist), tracksChanged: false);
    } catch (_) {
      playlist.trackIds = previous;
      rethrow;
    }
    return additions.length;
  }

  /// Places known tracks first in the requested order with one write;
  /// existing members not listed stay after that prefix.
  int mergeTracksIntoPlaylist(
    String playlistId,
    Iterable<String> orderedTrackIds,
  ) {
    final playlist = _getPlaylist(playlistId);
    final ordered = <String>[];
    final orderedSet = <String>{};
    for (final trackId in orderedTrackIds) {
      final id = _getTrack(trackId).id;
      if (orderedSet.add(id)) ordered.add(id);
    }
    final previous = playlist.trackIds;
    final previousSet = previous.toSet();
    final merged = [
      ...ordered,
      ...previous.where((id) => !orderedSet.contains(id)),
    ];
    if (listEquals(merged, previous)) return 0;
    playlist.trackIds = merged;
    try {
      _commit((db) => _writePlaylistTracks(db, playlist), tracksChanged: false);
    } catch (_) {
      playlist.trackIds = previous;
      rethrow;
    }
    return orderedSet.difference(previousSet).length;
  }

  void removeFromPlaylist(String playlistId, String trackId) {
    final playlist = _getPlaylist(playlistId);
    final id = _canonicalId(trackId);
    final index = playlist.trackIds.indexOf(id);
    if (index < 0) {
      throw ArgumentError("Track $id is not in playlist ${playlist.id}");
    }
    playlist.trackIds.removeAt(index);
    try {
      _commit((db) => _writePlaylistTracks(db, playlist), tracksChanged: false);
    } catch (_) {
      playlist.trackIds.insert(index, id);
      rethrow;
    }
  }

  /// Persists an explicit order. Every member must be supplied exactly once,
  /// so a reordering bug can never drop or duplicate tracks.
  void reorderPlaylist(String playlistId, List<String> orderedTrackIds) {
    final playlist = _getPlaylist(playlistId);
    final normalized = [for (final id in orderedTrackIds) _canonicalId(id)];
    final normalizedSet = normalized.toSet();
    if (normalized.length != normalizedSet.length) {
      throw const FormatException("Playlist order contains duplicate tracks");
    }
    if (!setEquals(normalizedSet, playlist.trackIds.toSet())) {
      throw const FormatException(
        "Playlist order must contain every existing track",
      );
    }
    if (listEquals(normalized, playlist.trackIds)) return;
    final previous = playlist.trackIds;
    playlist.trackIds = normalized;
    try {
      _commit((db) => _writePlaylistTracks(db, playlist), tracksChanged: false);
    } catch (_) {
      playlist.trackIds = previous;
      rethrow;
    }
  }

  /// Moves a track between playlists as one atomic metadata update.
  void moveTrackBetweenPlaylists(
    String sourceId,
    String targetId,
    String trackId,
  ) {
    final source = _getPlaylist(sourceId);
    final target = _getPlaylist(targetId);
    final track = _getTrack(trackId);
    if (source.id == target.id) return;
    final index = source.trackIds.indexOf(track.id);
    if (index < 0) {
      throw ArgumentError("Track ${track.id} is not in playlist ${source.id}");
    }
    source.trackIds.removeAt(index);
    final addedToTarget = !target.trackIds.contains(track.id);
    if (addedToTarget) target.trackIds.add(track.id);
    try {
      _commit((db) {
        _writePlaylistTracks(db, source);
        _writePlaylistTracks(db, target);
      }, tracksChanged: false);
    } catch (_) {
      source.trackIds.insert(index, track.id);
      if (addedToTarget) target.trackIds.removeLast();
      rethrow;
    }
  }

  // -- paths ---------------------------------------------------------------
  static String _resolve(String path) {
    final absolute = p.normalize(p.absolute(path));
    try {
      final type = FileSystemEntity.typeSync(absolute, followLinks: false);
      if (type == FileSystemEntityType.notFound) return absolute;
      return p.normalize(File(absolute).resolveSymbolicLinksSync());
    } on FileSystemException {
      return absolute;
    }
  }

  /// A validated managed filename: compact and relative to [musicFolder], or
  /// absolute inside an explicitly configured public music root (Android).
  String relativeFilename(String filename) {
    final absolute = p.isAbsolute(filename);
    final path = _resolve(absolute ? filename : p.join(_musicRoot, filename));
    if (p.isWithin(_musicRoot, path)) return p.relative(path, from: _musicRoot);
    if (!absolute || !_additionalRoots.any((root) => p.isWithin(root, path))) {
      throw ArgumentError(
        "Track files must be inside a configured music folder",
      );
    }
    return path;
  }

  String _pathForFilename(String filename) {
    // Queue activation asks for every queued track; validate each name once.
    final cached = _validatedPaths[filename];
    if (cached != null) return cached;
    final stored = relativeFilename(filename);
    final path = p.isAbsolute(stored) ? stored : p.join(_musicRoot, stored);
    _validatedPaths[filename] = path;
    return path;
  }

  // -- indexes -------------------------------------------------------------
  void _rebuildIndexes() {
    _sourceIndex = {};
    _contentIndex = {};
    for (final track in _tracks.values) {
      _indexTrack(track);
    }
    _invalidateTrackViews();
  }

  void _indexTrack(Track track) {
    _indexSource(track);
    if (track.contentHash.isNotEmpty) {
      _contentIndex.putIfAbsent(track.contentHash, () => {}).add(track.id);
    }
  }

  void _unindexTrack(Track track) {
    _unindexSource(track);
    _removeIndexEntry(_contentIndex, track.contentHash, track.id);
  }

  void _indexSource(Track track) {
    final key = sourceKey(track.source);
    if (key.isNotEmpty) _sourceIndex.putIfAbsent(key, () => {}).add(track.id);
  }

  void _unindexSource(Track track) =>
      _removeIndexEntry(_sourceIndex, sourceKey(track.source), track.id);

  static void _removeIndexEntry(
    Map<String, Set<String>> index,
    String key,
    String trackId,
  ) {
    final matches = index[key];
    if (matches == null) return;
    matches.remove(trackId);
    if (matches.isEmpty) index.remove(key);
  }

  Track _getTrack(String trackId) {
    final track = _tracks[_canonicalId(trackId)];
    if (track == null) throw ArgumentError("No track with id $trackId");
    return track;
  }

  Playlist _getPlaylist(String playlistId) {
    final playlist = _playlists[_canonicalId(playlistId)];
    if (playlist == null) {
      throw ArgumentError("No playlist with id $playlistId");
    }
    return playlist;
  }
}

/// Reads the little-endian pre-SQLite `MMD1` library format.
class _LegacyReader {
  _LegacyReader(this._data, this._path) : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  final String _path;
  int _offset = 0;

  bool get atEnd => _offset == _data.length;

  void _require(int length) {
    if (_offset + length > _data.length) {
      throw FormatException("$_path contains invalid music metadata");
    }
  }

  (int, int) header() {
    _require(9);
    if (utf8.decode(bytes(4), allowMalformed: true) != "MMD1") {
      throw FormatException("$_path is not a valid MusicManager file");
    }
    final version = _view.getUint8(_offset++);
    if (version < 1 || version > 3) {
      throw FormatException("Unsupported metadata version: $version");
    }
    return (version, uint32());
  }

  Uint8List bytes(int length) {
    _require(length);
    final value = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return value;
  }

  int uint32() {
    _require(4);
    final value = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  double float64() {
    _require(8);
    final value = _view.getFloat64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  String string() => utf8.decode(bytes(uint32()));
}
