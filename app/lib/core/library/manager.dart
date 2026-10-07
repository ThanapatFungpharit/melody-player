import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:sqlite3/sqlite3.dart";
import "package:uuid/uuid.dart";

import "../media.dart";
import "../storage.dart";
import "models.dart";

const _schemaVersion = 1;
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
CREATE TABLE playlists (id BLOB PRIMARY KEY, name TEXT NOT NULL) STRICT;
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
String uuidString(List<int> bytes) => Uuid.unparse(bytes);

/// Canonical lowercase UUID text, or null when [value] is not a UUID.
String? normalizeUuid(String value) {
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

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, "0")).join();

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
  Map<String, String>? _searchText;
  Map<String, String>? _titleKeys;
  final Map<String, String> _validatedPaths = {};

  /// Opens the library. [legacyMetadataPath] names a pre-SQLite `MMD1` file
  /// imported once in the transaction that creates the schema.
  /// [syncInBackground] keeps commits from waiting for the disk on the
  /// calling isolate (see [SqliteStore]).
  static MusicManager open(
    String metadataPath,
    String musicFolder, {
    List<String> additionalMusicFolders = const [],
    String? legacyMetadataPath,
    bool syncInBackground = false,
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
    );
    try {
      manager._open(legacyMetadataPath);
    } catch (_) {
      unawaited(db.close());
      rethrow;
    }
    return manager;
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

  /// Completes once every committed change is on durable storage.
  Future<void> flushed() => _db.flushed();

  // -- persistence -------------------------------------------------------
  void _open(String? legacyPath) {
    if (!_db.hasTable("library_meta")) {
      _initialize(legacyPath);
    } else {
      // A crash after the import committed but before the rename.
      if (legacyPath != null) retireLegacyFile(legacyPath);
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
        db.execute("INSERT INTO playlists (id, name) VALUES (?, ?)", [
          uuidBytes(playlist.id),
          playlist.name,
        ]);
        _writePlaylistTracks(db, playlist);
      }
    });
    if (legacyPath != null) retireLegacyFile(legacyPath);
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
      "SELECT id, name FROM playlists ORDER BY rowid",
    )) {
      final id = uuidString(row["id"] as List<int>);
      playlists[id] = Playlist(id: id, name: row["name"] as String);
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
      // A durable placeholder lets integrity checks report an unavailable
      // legacy file without trusting its current contents.
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
        // A later integrity check reports files that cannot be read.
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
    _searchText = null;
    _titleKeys = null;
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
        track.id: "${track.title}\u0000${track.filename}\u0000${track.source}"
            .toLowerCase(),
    };
  }

  Map<String, String> get _titles {
    return _titleKeys ??= {
      for (final track in _tracks.values)
        track.id:
            (track.title.isNotEmpty
                    ? track.title
                    : p.basenameWithoutExtension(track.filename))
                .toLowerCase(),
    };
  }

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

  List<Track> searchTracks(
    String query, {
    int offset = 0,
    int? limit,
    String sort = "recent",
  }) {
    final needle = query.trim().toLowerCase();
    if (limit != null && limit <= 0) return const [];
    final start = offset < 0 ? 0 : offset;
    final search = needle.isEmpty ? const <String, String>{} : _search;
    Iterable<String> matching = _newestIds.where(
      (id) => needle.isEmpty || search[id]!.contains(needle),
    );
    if (sort == "title" || sort == "oldest") {
      final ordered = matching.toList();
      if (sort == "title") {
        final titles = _titles;
        // A stable sort keeps newest-first order between equal titles.
        mergeSort(ordered, compare: (a, b) => titles[a]!.compareTo(titles[b]!));
      } else {
        mergeSort(
          ordered,
          compare: (a, b) => _tracks[a]!.addedAt.compareTo(_tracks[b]!.addedAt),
        );
      }
      matching = ordered;
    }
    var page = matching.skip(start);
    if (limit != null) page = page.take(limit);
    return [for (final id in page) _tracks[id]!.copy()];
  }

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
      target = _comparable(relativeFilename(filename));
    } on ArgumentError {
      return false;
    }
    final excluded = excluding == null ? null : normalizeUuid(excluding);
    return _tracks.values.any(
      (track) => track.id != excluded && _comparable(track.filename) == target,
    );
  }

  // -- integrity -----------------------------------------------------------
  Future<IntegrityProblem?> checkTrackIntegrity(String trackId) async {
    final track = getTrack(trackId);
    final String path;
    try {
      path = _pathForFilename(track.filename);
    } on ArgumentError catch (error) {
      return IntegrityProblem(
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
      return IntegrityProblem(
        track.id,
        track.filename,
        "unreadable",
        "Cannot read $path: $error",
      );
    }
    if (status.type == FileSystemEntityType.notFound) {
      return IntegrityProblem(
        track.id,
        track.filename,
        "missing",
        "Missing file: $path",
      );
    }
    if (status.type != FileSystemEntityType.file) {
      return IntegrityProblem(
        track.id,
        track.filename,
        "missing",
        "Expected a file but found: $path",
      );
    }
    if (status.size <= 0) {
      return IntegrityProblem(
        track.id,
        track.filename,
        "empty",
        "Audio file is empty: $path",
      );
    }
    final String actual;
    try {
      actual = await sha256File(path);
    } on FileSystemException catch (error) {
      return IntegrityProblem(
        track.id,
        track.filename,
        "unreadable",
        "Cannot read $path: $error",
      );
    }
    if (actual != track.contentHash) {
      return IntegrityProblem(
        track.id,
        track.filename,
        "modified",
        "File content differs from recorded SHA-256: $path",
        expectedHash: track.contentHash,
        actualHash: actual,
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

  String createPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException("Playlist name cannot be empty");
    }
    final playlist = Playlist(id: _uuid.v4(), name: trimmed);
    _playlists[playlist.id] = playlist;
    try {
      _commit((db) {
        db.execute("INSERT INTO playlists (id, name) VALUES (?, ?)", [
          uuidBytes(playlist.id),
          trimmed,
        ]);
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

  void addToPlaylist(String playlistId, String trackId) {
    final playlist = _getPlaylist(playlistId);
    final track = _getTrack(trackId);
    if (playlist.trackIds.contains(track.id)) return;
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

  /// Copies a track between playlists, preserving source membership.
  void copyPlaylistTrack(String sourceId, String targetId, String trackId) {
    final source = _getPlaylist(sourceId);
    final target = _getPlaylist(targetId);
    final track = _getTrack(trackId);
    if (!source.trackIds.contains(track.id)) {
      throw ArgumentError("Track ${track.id} is not in playlist ${source.id}");
    }
    if (target.trackIds.contains(track.id)) return;
    target.trackIds.add(track.id);
    try {
      _commit(
        (db) => _appendPlaylistTrack(db, target.id, track.id),
        tracksChanged: false,
      );
    } catch (_) {
      target.trackIds.removeLast();
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

  static String _comparable(String path) =>
      Platform.isWindows ? path.toLowerCase().replaceAll("/", r"\") : path;

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
