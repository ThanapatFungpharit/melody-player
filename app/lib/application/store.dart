import "dart:async";
import "dart:convert";
import "dart:math" show max;

import "package:sqlite3/sqlite3.dart";

import "../core/library/manager.dart" show listensSchema, trackDetailsSchema;
import "../core/storage.dart";
import "models.dart";

/// The application's own tables, beside the library's in the same file.
const applicationStateSchema =
    """
CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
$trackDetailsSchema
""";

/// Listens waiting to reach a scrobbling service, oldest first. A listen is
/// queued once per service (`listened_at` is the second it began), and goes
/// when the service accepts it or refuses it for good.
const scrobbleQueueSchema = """
CREATE TABLE IF NOT EXISTS scrobble_queue (
    id INTEGER PRIMARY KEY,
    service TEXT NOT NULL,
    listened_at INTEGER NOT NULL,
    listen TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    UNIQUE (service, listened_at)
) STRICT;
""";

/// A listen waiting in the scrobble queue.
class PendingScrobble {
  const PendingScrobble(this.id, this.listenedAt, this.listen, this.attempts);

  final int id;

  /// Seconds since the Unix epoch when the listen began.
  final int listenedAt;

  /// The service's own form of the listen.
  final Map<String, Object?> listen;

  /// How many submissions of it have failed so far.
  final int attempts;
}

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
/// another, so a change rewrites one row. Where playback is has a small row of
/// its own ([_cursorKey]), so moving through the queue never rewrites the queue.
///
/// It shares the library's file over a connection of its own, which is what lets
/// its commits differ from the library's: they survive application crashes, and a
/// power loss can drop only the most recent ones (`synchronous=NORMAL`). A track's
/// row here goes with the track ([trackDetailsSchema]).
class ApplicationStore {
  ApplicationStore._(this.path, this._db, this._defaultDownloadDirectory);

  final String path;
  final SqliteStore _db;
  final String _defaultDownloadDirectory;
  late Map<String, Object?> _data;

  /// The JSON last written for each top-level row (except the per-track
  /// details), so a commit encodes each value once instead of re-encoding
  /// the stored copy to compare it. Top-level values are only ever replaced,
  /// never changed in place, which keeps these current.
  final Map<String, String> _written = {};

  /// The most download history entries kept.
  static const maxDownloadRecords = 250;

  /// The played-track histories, newest first, and how many each keeps.
  static const _playHistories = [
    ("recent_tracks", 20),
    ("playback_history", 100),
  ];

  static const _searchHistoryKey = "search_history";

  /// Where playback is in the queue, laid over the `playback` row when read.
  /// A `playback` row written before this split still holds these fields
  /// itself, and they count until the cursor row has its own.
  static const _cursorKey = "playback_position";
  static const _cursorFields = {"current_index", "position_ms", "duration_ms"};

  /// State the launch pass over the library's lyrics kept.
  static const _retiredKeys = ["lyrics_not_embedded"];

  /// How many earlier searches the search history keeps.
  static const _searchHistoryLimit = 20;

  /// Pending play batches may arrive after a track is removed. Keep their IDs
  /// for this process lifetime so those writes cannot recreate it.
  final Set<String> _deletedTrackIds = {};

  static ApplicationStore open(
    String path, {
    required String defaultDownloadDirectory,
  }) {
    final db = SqliteStore.open(path, fullSync: false);
    final store = ApplicationStore._(path, db, defaultDownloadDirectory);
    try {
      store._data = store._open();
    } catch (_) {
      unawaited(db.close());
      rethrow;
    }
    return store;
  }

  Future<void> close() => _db.close();

  /// The most listens statistics keep; the oldest go first.
  static const maxListens = 200000;

  /// The most listens waiting for a scrobbling service; the oldest go first,
  /// so months offline cannot grow the queue without bound.
  static const maxQueuedScrobbles = 10000;

  Map<String, Object?> _open() {
    final data = _db.hasTable("state") ? _load() : null;
    _db.transaction((db) {
      if (data == null) db.execute(applicationStateSchema);
      // Tables later releases added; earlier ones leave them alone.
      db.execute(listensSchema);
      db.execute(scrobbleQueueSchema);
      db.execute(
        "DELETE FROM listens WHERE id <= "
        "(SELECT id FROM listens ORDER BY id DESC LIMIT 1 OFFSET ?)",
        [maxListens],
      );
    });
    if (data != null) return data;
    final defaults = _defaults();
    _db.transaction((db) => _writeRows(db, defaults, const {}, const {}));
    return defaults;
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
      if (_retiredKeys.any(raw.containsKey)) {
        _db.transaction((db) {
          for (final key in _retiredKeys) {
            db.execute("DELETE FROM state WHERE key = ?", [key]);
            raw.remove(key);
          }
        });
      }
    } on FormatException catch (error) {
      throw FormatException("Could not read application settings: $error");
    }
    return {..._defaults(), ...raw};
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

  bool hasTrackDetails(String trackId) => _details.containsKey(trackId);

  Set<String> favoriteTrackIds() => {
    for (final entry in _details.entries)
      if (entry.value case final Map value when value["favorite"] == true)
        entry.key,
  };

  /// The order the user dragged Favorites into. It may name tracks that are
  /// no longer favorites and miss newer ones; readers reconcile it.
  List<String> favoritesOrder() => _stringList("favorites_order");

  void saveFavoritesOrder(List<String> trackIds) =>
      _commit({"favorites_order": trackIds});

  void saveTrackDetails(String trackId, TrackDetails details) {
    _commit(const {}, trackDetails: {trackId: details.toJson()});
    _deletedTrackIds.remove(trackId);
  }

  void removeTrackDetails(String trackId) {
    final lists = {
      for (final (name, _) in _playHistories)
        name: _stringList(name).where((item) => item != trackId).toList(),
      "favorites_order": favoritesOrder()
          .where((item) => item != trackId)
          .toList(),
    };
    _commit(
      lists,
      trackDetails: {trackId: _missing},
      also: (db) =>
          db.execute("DELETE FROM listens WHERE track_id = ?", [trackId]),
    );
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
      };
    } else {
      cleared = _defaults()["playback"] as Map<String, Object?>;
    }
    _commit({
      "track_details": <String, Object?>{},
      "recent_tracks": <Object?>[],
      "playback_history": <Object?>[],
      "favorites_order": <Object?>[],
      "playback": cleared,
    }, also: (db) => db.execute("DELETE FROM listens"));
    _deletedTrackIds.addAll(removed);
  }

  Object? get(String key, [Object? fallback]) {
    if (!_data.containsKey(key)) return fallback;
    if (key == "playback") {
      final playback = _data[key];
      if (playback is Map) return _clone({...playback, ..._cursor});
    }
    return _clone(_data[key]);
  }

  void set(String key, Object? value) => _commit({key: _clone(value)});

  /// Library tracks played lately, newest first. It may name tracks the
  /// library no longer has; readers skip them.
  List<String> recentTrackIds() => _stringList("recent_tracks");

  /// Earlier search queries, newest first.
  List<String> searchHistory() => _stringList(_searchHistoryKey);

  /// Puts [query] first in the search history, dropping its earlier place.
  void addSearch(String query) => _commit({
    _searchHistoryKey: _recentItems(
      _searchHistoryKey,
      query,
      limit: _searchHistoryLimit,
    ),
  });

  /// Replaces the search history with [queries], newest first.
  void saveSearchHistory(List<String> queries) =>
      _commit({_searchHistoryKey: List.of(queries)});

  List<DownloadRecord> downloads() => [
    if (_data["downloads"] case final List<Object?> records)
      for (final record in records)
        if (record is Map)
          DownloadRecord.fromJson(record.cast<String, Object?>()),
  ];

  void saveDownloads(Iterable<DownloadRecord> records) {
    final list = records.toList();
    final retained = list.length > maxDownloadRecords
        ? list.sublist(list.length - maxDownloadRecords)
        : list;
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
    final staleHistory = <String>{
      for (final row in _db.query("SELECT DISTINCT track_id FROM listens"))
        if (!validIds.contains(row["track_id"])) row["track_id"] as String,
    };
    final staleListens = staleHistory.toList();
    final histories = <String, Object?>{};
    for (final (name, _) in _playHistories) {
      final items = _stringList(name);
      staleHistory.addAll(items.where((item) => !validIds.contains(item)));
      histories[name] = items.where(validIds.contains).toList();
    }
    _commit(
      histories,
      trackDetails: stale,
      also: staleListens.isEmpty
          ? null
          : (db) {
              for (final id in staleListens) {
                db.execute("DELETE FROM listens WHERE track_id = ?", [id]);
              }
            },
    );
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
    } else if (changes["position"] case final Map position) {
      updates[_cursorKey] = {..._cursor, ...position};
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
      for (final (name, limit) in _playHistories) {
        updates[name] = {...newest, ..._stringList(name)}.take(limit).toList();
      }
    }
    _commit(updates, trackDetails: details);
  }

  // -- listens ---------------------------------------------------------------

  /// Records a listen for statistics. A track removed meanwhile keeps none.
  void recordListen(Listen listen) {
    if (_deletedTrackIds.contains(listen.trackId)) return;
    _db.transaction(
      (db) => db.execute(
        "INSERT INTO listens (track_id, started_at, day, listened_ms, title, "
        "artist, album) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
          listen.trackId,
          listen.startedAt.millisecondsSinceEpoch ~/ 1000,
          listen.day,
          max(0, listen.listenedMs),
          listen.title,
          listen.artist,
          listen.album,
        ],
      ),
    );
  }

  // -- scrobble queue --------------------------------------------------------

  /// Queues [listen] for [service]; false when it was queued already.
  bool enqueueScrobble(
    String service,
    int listenedAt,
    Map<String, Object?> listen,
  ) => _db.transaction((db) {
    db.execute(
      "INSERT OR IGNORE INTO scrobble_queue (service, listened_at, listen) "
      "VALUES (?, ?, ?)",
      [service, listenedAt, jsonEncode(listen)],
    );
    final added = db.updatedRows > 0;
    if (added) {
      db.execute(
        "DELETE FROM scrobble_queue WHERE service = ? AND id <= "
        "(SELECT id FROM scrobble_queue WHERE service = ? "
        "ORDER BY id DESC LIMIT 1 OFFSET ?)",
        [service, service, maxQueuedScrobbles],
      );
    }
    return added;
  });

  /// The oldest listens waiting for [service], at most [limit].
  List<PendingScrobble> pendingScrobbles(String service, {int limit = 50}) => [
    for (final row in _db.query(
      "SELECT id, listened_at, listen, attempts FROM scrobble_queue "
      "WHERE service = ? ORDER BY listened_at, id LIMIT ?",
      [service, limit],
    ))
      if (_decodeListen(row["listen"]) case final listen?)
        PendingScrobble(
          row["id"] as int,
          row["listened_at"] as int,
          listen,
          row["attempts"] as int,
        ),
  ];

  static Map<String, Object?>? _decodeListen(Object? text) {
    try {
      final value = jsonDecode(text as String);
      return value is Map ? value.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }

  int pendingScrobbleCount(String service) =>
      _db.query("SELECT count(*) AS n FROM scrobble_queue WHERE service = ?", [
            service,
          ]).first["n"]
          as int;

  /// Removes listens the service accepted, or refused for good.
  void removeScrobbles(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _db.transaction((db) {
      for (final id in list) {
        db.execute("DELETE FROM scrobble_queue WHERE id = ?", [id]);
      }
    });
  }

  /// Counts a failed submission of each of [ids].
  void recordScrobbleAttempt(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _db.transaction((db) {
      for (final id in list) {
        db.execute(
          "UPDATE scrobble_queue SET attempts = attempts + 1 WHERE id = ?",
          [id],
        );
      }
    });
  }

  /// Forgets every listen waiting for [service].
  void clearScrobbles(String service) => _db.transaction(
    (db) =>
        db.execute("DELETE FROM scrobble_queue WHERE service = ?", [service]),
  );

  /// Persists changed entries once, preserving the old state on failure.
  /// [also] writes other tables in the same transaction.
  void _commit(
    Map<String, Object?> changes, {
    Map<String, Object?> trackDetails = const {},
    void Function(Database db)? also,
  }) {
    final updates = <String, Object?>{};
    final encoded = <String, String>{};
    final rows = changes["playback"] is Map
        ? {...changes, ..._splitSession(changes["playback"] as Map)}
        : changes;
    for (final MapEntry(:key, :value) in rows.entries) {
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
    if (updates.isEmpty && changedDetails.isEmpty && also == null) return;
    _db.transaction((db) {
      _writeRows(db, updates, encoded, changedDetails);
      also?.call(db);
    });
    // Committed. A failure above leaves the model as it was.
    _data = {..._data, ...updates};
    if (changedDetails.isNotEmpty) {
      final details = _data["track_details"] as Map;
      for (final entry in changedDetails.entries) {
        if (identical(entry.value, _missing)) {
          details.remove(entry.key);
        } else {
          details[entry.key] = entry.value;
        }
      }
    }
    encoded.remove("track_details");
    _written.addAll(encoded);
  }

  Map<Object?, Object?> get _cursor => switch (_data[_cursorKey]) {
    final Map cursor => cursor,
    _ => const {},
  };

  /// A whole session as its two rows.
  static Map<String, Object?> _splitSession(Map session) => {
    "playback": {
      for (final MapEntry(:key, :value) in session.entries)
        if (!_cursorFields.contains(key)) key: value,
    },
    _cursorKey: {
      for (final MapEntry(:key, :value) in session.entries)
        if (_cursorFields.contains(key)) key: value,
    },
  };

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
