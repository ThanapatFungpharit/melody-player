import "dart:async";
import "dart:convert";
import "dart:io";

import "package:sqlite3/sqlite3.dart";

import "../core/storage.dart";
import "models.dart";

const _schema = """
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE track_details (track_id TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
""";
const _upsertState =
    "INSERT INTO state (key, value) VALUES (?, ?) "
    "ON CONFLICT (key) DO UPDATE SET value = excluded.value";
const _upsertDetails =
    "INSERT INTO track_details (track_id, value) VALUES (?, ?) "
    "ON CONFLICT (track_id) DO UPDATE SET value = excluded.value";

/// Marks a deleted entry in a change set.
const Object _missing = _Missing();

class _Missing {
  const _Missing();
}

String _encode(Object? value) => jsonEncode(value);

Object? _clone(Object? value) =>
    value == null ? null : jsonDecode(jsonEncode(value));

bool _sameJson(Object? a, Object? b) => _encode(a) == _encode(b);

/// SQLite persistence for state outside MusicManager's domain: preferences,
/// playback session, enriched metadata, favorites, histories, and download
/// history. Each top-level value is one JSON row and each track's details
/// another, so a position save rewrites one small row.
///
/// Commits survive application crashes; a power loss can drop only the most
/// recent commits (`synchronous=NORMAL`).
class ApplicationStore {
  ApplicationStore._(this.path, this._db, this._defaultDownloadDirectory);

  final String path;
  final SqliteStore _db;
  final String _defaultDownloadDirectory;
  late Map<String, Object?> _data;

  /// The JSON last written for each top-level row (except the per-track
  /// details), so a commit encodes each value once instead of re-encoding
  /// the stored copy to compare it. `_data` is only ever replaced, never
  /// changed in place, which keeps these current.
  final Map<String, String> _written = {};

  /// Pending play batches may arrive after a track is removed. Keep their IDs
  /// for this process lifetime so those writes cannot recreate it.
  final Set<String> _deletedTrackIds = {};

  static ApplicationStore open(
    String path, {
    required String defaultDownloadDirectory,
    String? legacyPath,
  }) {
    final db = SqliteStore.open(path, fullSync: false);
    final store = ApplicationStore._(path, db, defaultDownloadDirectory);
    try {
      store._data = store._open(legacyPath);
    } catch (_) {
      unawaited(db.close());
      rethrow;
    }
    return store;
  }

  Future<void> close() => _db.close();

  Map<String, Object?> _open(String? legacyPath) {
    if (_db.hasTable("state")) {
      if (legacyPath != null) retireLegacyFile(legacyPath);
      return _load();
    }
    final data = legacyPath != null ? _loadLegacy(legacyPath) : _defaults();
    _db.transaction((db) {
      db.execute(_schema);
      _writeRows(db, data, const {}, const {});
    });
    if (legacyPath != null) retireLegacyFile(legacyPath);
    return data;
  }

  Map<String, Object?> _load() {
    final Map<String, Object?> raw;
    try {
      raw = {
        for (final row in _db.query("SELECT key, value FROM state"))
          row["key"] as String: jsonDecode(row["value"] as String),
      };
      raw["track_details"] = {
        for (final row in _db.query(
          "SELECT track_id, value FROM track_details ORDER BY rowid",
        ))
          row["track_id"] as String: jsonDecode(row["value"] as String),
      };
    } on FormatException catch (error) {
      throw FormatException("Could not read application settings: $error");
    }
    return _migrate({..._defaults(), ...raw});
  }

  Map<String, Object?> _loadLegacy(String path) {
    final file = File(path);
    if (!file.existsSync()) return _defaults();
    final contents = file.readAsStringSync();
    if (contents.isEmpty) return _defaults();
    final Object? raw;
    try {
      raw = jsonDecode(contents);
    } on FormatException catch (error) {
      throw FormatException("Could not read application settings: $error");
    }
    if (raw is! Map<String, Object?>) {
      throw const FormatException(
        "Application settings must contain a JSON object",
      );
    }
    return _migrate({..._defaults(), ...raw});
  }

  static int _version(Map<String, Object?> data) => switch (data["version"]) {
    num value when value.isFinite => value.toInt(),
    _ => 1,
  };

  static Map<String, Object?> _migrate(Map<String, Object?> data) {
    if (_version(data) < 2) {
      final details = data["track_details"];
      if (details is Map) {
        for (final value in details.values) {
          if (value is! Map) continue;
          if (!value.containsKey("uploader") && value.containsKey("artist")) {
            value["uploader"] = value["artist"];
          }
          value
            ..remove("artist")
            ..remove("album");
        }
      }
      final downloads = data["downloads"];
      if (downloads is List) {
        for (final record in downloads) {
          if (record is! Map) continue;
          if (!record.containsKey("uploader") && record.containsKey("artist")) {
            record["uploader"] = record["artist"];
          }
          record.remove("artist");
        }
      }
      data["version"] = 2;
    }
    if (_version(data) < 3) {
      final settings = data["settings"];
      if (settings is Map) {
        // Browser cookie extraction was removed; a user must upload a cookie
        // file before authenticated requests are enabled again.
        settings
          ..remove("use_browser_cookies")
          ..remove("cookie_browser")
          ..remove("cookie_profile");
      }
      data["version"] = 3;
    }
    final playback = data["playback"];
    if (playback is Map) playback.remove("shuffle");
    return data;
  }

  Map<String, Object?> _defaults() => {
    "version": 3,
    "settings": AppSettings(
      downloadDirectory: _defaultDownloadDirectory,
    ).toJson(),
    "track_details": <String, Object?>{},
    "recent_tracks": <Object?>[],
    "playback_history": <Object?>[],
    "search_history": <Object?>[],
    "downloads": <Object?>[],
    "playback": {
      "queue": <Object?>[],
      "current_index": -1,
      "position_ms": 0,
      "repeat": "off",
    },
  };

  Map<String, Object?> get _details =>
      (_data["track_details"] as Map).cast<String, Object?>();

  Map<String, Object?> _detailsJson(String key) {
    final value = _details[key];
    return value is Map ? value.cast<String, Object?>() : const {};
  }

  List<String> _stringList(String key) => [
    if (_data[key] case final List<Object?> items)
      for (final item in items)
        if (item is String) item,
  ];

  AppSettings get settings {
    final raw = _data["settings"];
    return AppSettings.fromJson(
      raw is Map ? raw.cast<String, Object?>() : const {},
      defaultDownloadDirectory: _defaultDownloadDirectory,
    );
  }

  void saveSettings(AppSettings settings) =>
      _commit({"settings": settings.toJson()});

  TrackDetails trackDetails(String trackId) =>
      TrackDetails.fromJson(_detailsJson(trackId));

  /// One metadata snapshot for a multi-row render.
  Map<String, TrackDetails> trackDetailsMany(Iterable<String> trackIds) => {
    for (final id in trackIds)
      if (id.isNotEmpty) id: TrackDetails.fromJson(_detailsJson(id)),
  };

  bool hasTrackDetails(String trackId) => _details.containsKey(trackId);

  Set<String> favoriteTrackIds() => {
    for (final entry in _details.entries)
      if (entry.value case final Map value when value["favorite"] == true)
        entry.key,
  };

  void saveTrackDetails(String trackId, TrackDetails details) {
    _commit(const {}, trackDetails: {trackId: details.toJson()});
    _deletedTrackIds.remove(trackId);
  }

  void removeTrackDetails(String trackId) {
    final histories = {
      for (final name in const ["recent_tracks", "playback_history"])
        name: _stringList(name).where((item) => item != trackId).toList(),
    };
    _commit(histories, trackDetails: {trackId: _missing});
    _deletedTrackIds.add(trackId);
  }

  /// Clears state that refers to library tracks, preserving other app data.
  void clearLibraryData() {
    final removed = <String>{
      ..._details.keys,
      ..._stringList("recent_tracks"),
      ..._stringList("playback_history"),
    };
    final playback = _data["playback"];
    final Map<String, Object?> cleared;
    if (playback is Map) {
      final queue = playback["queue"];
      if (queue is List) removed.addAll(queue.whereType<String>());
      cleared = {
        ...playback.cast<String, Object?>(),
        "queue": <Object?>[],
        "current_index": -1,
        "position_ms": 0,
      }..remove("shuffle");
    } else {
      cleared = _defaults()["playback"] as Map<String, Object?>;
    }
    _commit({
      "track_details": <String, Object?>{},
      "recent_tracks": <Object?>[],
      "playback_history": <Object?>[],
      "playback": cleared,
    });
    _deletedTrackIds.addAll(removed);
  }

  Object? get(String key, [Object? fallback]) =>
      _data.containsKey(key) ? _clone(_data[key]) : fallback;

  void set(String key, Object? value) => _commit({key: _clone(value)});

  void addRecent(String key, String value, {int limit = 50}) =>
      _commit({key: _recentItems(key, value, limit: limit)});

  /// Updates play metadata, histories, and optional session state atomically.
  void recordPlay(
    String trackId, {
    required double playedAt,
    Map<String, Object?>? playback,
  }) {
    if (_deletedTrackIds.contains(trackId)) return;
    final details = trackDetails(trackId)
      ..playCount += 1
      ..lastPlayed = playedAt;
    _commit(
      {
        "recent_tracks": _recentItems("recent_tracks", trackId, limit: 20),
        "playback_history": _recentItems(
          "playback_history",
          trackId,
          limit: 100,
        ),
        if (playback != null) "playback": _clone(playback),
      },
      trackDetails: {trackId: details.toJson()},
    );
  }

  List<DownloadRecord> downloads() => [
    if (_data["downloads"] case final List<Object?> records)
      for (final record in records)
        if (record is Map)
          DownloadRecord.fromJson(record.cast<String, Object?>()),
  ];

  void saveDownloads(Iterable<DownloadRecord> records) {
    final list = records.toList();
    final retained = list.length > 250 ? list.sublist(list.length - 250) : list;
    _commit({
      "downloads": [for (final record in retained) record.toJson()],
    });
  }

  /// Marks several tracks as favorites with one atomic write.
  int favoriteTracks(Iterable<String> trackIds) {
    final changes = <String, Object?>{};
    for (final key in trackIds.toSet()) {
      final details = trackDetails(key);
      if (details.favorite) continue;
      details.favorite = true;
      changes[key] = details.toJson();
    }
    _commit(const {}, trackDetails: changes);
    return changes.length;
  }

  /// Removes references to tracks the library no longer has; returns the
  /// number of distinct track IDs whose references were removed.
  int reconcileTrackReferences(Set<String> validIds) {
    final stale = <String, Object?>{
      for (final key in _details.keys)
        if (!validIds.contains(key)) key: _missing,
    };
    final staleHistory = <String>{};
    final histories = <String, Object?>{};
    for (final name in const ["recent_tracks", "playback_history"]) {
      final items = _stringList(name);
      staleHistory.addAll(items.where((item) => !validIds.contains(item)));
      histories[name] = items.where(validIds.contains).toList();
    }
    _commit(histories, trackDetails: stale);
    _deletedTrackIds
      ..addAll(stale.keys)
      ..addAll(staleHistory);
    return staleHistory.union(stale.keys.toSet()).length;
  }

  List<String> _recentItems(String key, String value, {required int limit}) => [
    value,
    ..._stringList(key).where((item) => item != value),
  ].take(limit < 0 ? 0 : limit).toList();

  /// Commits coalesced session/volume changes and exact play counts once.
  void savePlaybackUpdates(
    Map<String, Object?> changes,
    Map<String, int> plays,
  ) {
    final updates = <String, Object?>{};
    if (changes.containsKey("playback")) {
      updates["playback"] = changes["playback"];
    }
    if (changes["volume"] case final Map volume) {
      updates["settings"] = {
        ...(_data["settings"] as Map).cast<String, Object?>(),
        ...volume.cast<String, Object?>(),
      };
    }
    final accepted = {
      for (final entry in plays.entries)
        if (!_deletedTrackIds.contains(entry.key)) entry.key: entry.value,
    };
    final playback = _data["playback"];
    final hasQueue =
        playback is Map &&
        playback["queue"] is List &&
        (playback["queue"] as List).isNotEmpty;
    if (!hasQueue && !updates.containsKey("playback")) accepted.clear();
    final details = <String, Object?>{};
    if (accepted.isNotEmpty) {
      final now = unixSeconds();
      for (final entry in accepted.entries) {
        final item = trackDetails(entry.key)
          ..playCount += entry.value
          ..lastPlayed = now;
        details[entry.key] = item.toJson();
      }
      // [plays] is oldest-to-newest; recents are newest first.
      final newest = accepted.keys.toList().reversed;
      for (final (name, limit) in const [
        ("recent_tracks", 20),
        ("playback_history", 100),
      ]) {
        updates[name] = {...newest, ..._stringList(name)}.take(limit).toList();
      }
    }
    _commit(updates, trackDetails: details);
  }

  /// Persists changed entries once, preserving the old state on failure.
  void _commit(
    Map<String, Object?> changes, {
    Map<String, Object?> trackDetails = const {},
  }) {
    final updates = <String, Object?>{};
    final encoded = <String, String>{};
    for (final MapEntry(:key, :value) in changes.entries) {
      if (trackDetails.isNotEmpty && key == "track_details") continue;
      final json = _encode(value);
      if (_data.containsKey(key) && json == _storedJson(key)) continue;
      updates[key] = value;
      encoded[key] = json;
    }
    final current = _details;
    final changedDetails = <String, Object?>{
      for (final entry in trackDetails.entries)
        if (identical(entry.value, _missing)
            ? current.containsKey(entry.key)
            : !current.containsKey(entry.key) ||
                  !_sameJson(current[entry.key], entry.value))
          entry.key: entry.value,
    };
    if (updates.isEmpty && changedDetails.isEmpty) return;
    final candidate = {..._data, ...updates};
    if (changedDetails.isNotEmpty) {
      final details = Map<String, Object?>.of(
        (candidate["track_details"] as Map).cast<String, Object?>(),
      );
      for (final entry in changedDetails.entries) {
        if (identical(entry.value, _missing)) {
          details.remove(entry.key);
        } else {
          details[entry.key] = entry.value;
        }
      }
      candidate["track_details"] = details;
    }
    _db.transaction((db) => _writeRows(db, updates, encoded, changedDetails));
    _data = candidate;
    encoded.remove("track_details");
    _written.addAll(encoded);
  }

  String _storedJson(String key) => key == "track_details"
      ? _encode(_data[key])
      : _written[key] ??= _encode(_data[key]);

  /// [encoded] holds the JSON of [updates] already encoded; others are
  /// encoded here.
  static void _writeRows(
    Database db,
    Map<String, Object?> updates,
    Map<String, String> encoded,
    Map<String, Object?> trackDetails,
  ) {
    for (final entry in updates.entries) {
      if (entry.key == "track_details") {
        // A whole-catalog replacement, such as clearing library data.
        db.execute("DELETE FROM track_details");
        for (final detail in (entry.value as Map).entries) {
          db.execute(_upsertDetails, [detail.key, _encode(detail.value)]);
        }
      } else {
        db.execute(_upsertState, [
          entry.key,
          encoded[entry.key] ?? _encode(entry.value),
        ]);
      }
    }
    for (final entry in trackDetails.entries) {
      if (identical(entry.value, _missing)) {
        db.execute("DELETE FROM track_details WHERE track_id = ?", [entry.key]);
      } else {
        db.execute(_upsertDetails, [entry.key, _encode(entry.value)]);
      }
    }
  }
}
