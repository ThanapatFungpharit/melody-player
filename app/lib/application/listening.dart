/// Listening history: which plays count as listens, and statistics over them.
///
/// [ListeningTracker] watches playback from outside: it reads the
/// controller's state on each change and never drives it, so counting a
/// listen cannot change what plays. Listens are stored by [ApplicationStore]
/// (the `listens` table) and also handed to whoever subscribes, such as the
/// scrobbler. Statistics are aggregate queries over that table, run in a
/// background isolate on a read-only connection of their own.
library;

import "dart:async";
import "dart:isolate";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:sqlite3/sqlite3.dart";

import "../core/library/manager.dart";
import "library_service.dart";
import "models.dart";
import "playback.dart";
import "store.dart";

/// What the tracker reads from playback on each change.
typedef PlaybackObservation = ({
  String? trackId,
  bool playing,
  int positionMs,
  int durationMs,
});

/// What a listen records about its track.
typedef ListenDescription = ({
  String title,
  String artist,
  String album,
  String source,

  /// The length the library knows, in milliseconds; 0 when unknown.
  int durationMs,
});

/// Turns playback into listens.
///
/// A play counts once it has been heard for half the track or four minutes,
/// whichever is less (ListenBrainz's and Last.fm's rule), so skipping through
/// a track does not count it. Only time heard counts: position moving
/// forward in small steps while playing. A jump (a seek) adds nothing.
/// Each play counts at most once; the same track starting again (a new
/// selection, repeat, or a rewind to its start after it counted) is a new play.
class ListeningTracker {
  ListeningTracker(
    Stream<PlaybackChange> changes,
    this._observe, {
    required this.describe,
    this.record,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _subscription = changes.listen(_changed);
    _begin(_observe());
  }

  /// A tracker of [playback] that records into [store].
  factory ListeningTracker.forPlayback(
    PlaybackController playback,
    MusicManager manager,
    LibraryService library,
    ApplicationStore store,
  ) => ListeningTracker(
    playback.changes,
    () => (
      trackId: playback.currentTrackId,
      playing: playback.playing,
      positionMs: playback.positionMs,
      durationMs: playback.durationMs,
    ),
    describe: (trackId) {
      if (!manager.hasTrack(trackId)) return null;
      final track = manager.getTrack(trackId);
      final details = library.details(trackId);
      return (
        title: track.displayTitle,
        artist: details.uploader.trim(),
        album: details.album.trim(),
        source: track.source,
        durationMs: (details.duration * 1000).round(),
      );
    },
    record: store.recordListen,
  );

  /// The longest position step that still counts as listening. Positions
  /// arrive every 0.5 to 5 seconds while playing; anything longer is a seek.
  static const maxStep = Duration(seconds: 15);

  /// A play counts after half the track, or this long, whichever is less.
  static const countAfter = Duration(minutes: 4);

  final PlaybackObservation Function() _observe;
  final ListenDescription? Function(String trackId) describe;

  /// Stores a listen; a failure loses that listen only.
  final void Function(Listen listen)? record;
  final DateTime Function() _clock;
  late final StreamSubscription<PlaybackChange> _subscription;
  final _listens = StreamController<Listen>.broadcast(sync: true);

  String? _trackId;
  DateTime? _startedAt;
  int _heardMs = 0;
  int? _lastPosition;
  bool _counted = false;

  /// Every listen as it counts.
  Stream<Listen> get listens => _listens.stream;

  void _begin(PlaybackObservation now) {
    _trackId = now.trackId;
    _startedAt = now.playing ? _clock() : null;
    _heardMs = 0;
    _lastPosition = now.positionMs;
    _counted = false;
  }

  void _changed(PlaybackChange change) {
    final now = _observe();
    if (change == PlaybackChange.track || now.trackId != _trackId) {
      _begin(now);
      return;
    }
    if (change != PlaybackChange.progress && change != PlaybackChange.state) {
      return;
    }
    final position = now.positionMs;
    final last = _lastPosition;
    _lastPosition = position;
    if (!now.playing || last == null) return;
    _startedAt ??= _clock();
    final step = position - last;
    if (step > 0 && step <= maxStep.inMilliseconds) {
      _heardMs += step;
      _countIfDue(now);
    } else if (_counted && step < 0 && position < 5000) {
      // Repeat, or a rewind to the start, after this play counted.
      _begin(now);
      _startedAt = _clock();
    }
  }

  void _countIfDue(PlaybackObservation now) {
    final trackId = _trackId;
    if (_counted || trackId == null) return;
    final description = describe(trackId);
    if (description == null) return;
    final duration = now.durationMs > 0
        ? now.durationMs
        : description.durationMs;
    final due = duration > 0
        ? min(duration ~/ 2, countAfter.inMilliseconds)
        : countAfter.inMilliseconds;
    if (_heardMs < max(due, 1)) return;
    _counted = true;
    final listen = Listen(
      trackId: trackId,
      startedAt: _startedAt ?? _clock(),
      listenedMs: _heardMs,
      durationMs: max(0, duration),
      title: description.title,
      artist: description.artist,
      album: description.album,
      source: description.source,
    );
    try {
      record?.call(listen);
    } on Object catch (error) {
      // Statistics lose this one listen; playback is unaffected.
      debugPrint("Could not record a listen: $error");
    }
    if (!_listens.isClosed) _listens.add(listen);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _listens.close();
  }
}

// -- statistics ---------------------------------------------------------------

/// The length of the period statistics cover.
enum StatsPeriod {
  week("Week"),
  month("Month");

  const StatsPeriod(this.label);

  final String label;
}

/// A span of the listener's calendar days, first and last included.
@immutable
class StatsRange {
  const StatsRange(this.period, this.firstDay, this.lastDay);

  /// The week (from Monday) or calendar month [offset] periods before the
  /// one holding [now].
  factory StatsRange.of(StatsPeriod period, DateTime now, {int offset = 0}) {
    final local = now.toLocal();
    switch (period) {
      case StatsPeriod.week:
        final today = localDay(local);
        final monday = today - (local.weekday - DateTime.monday) - 7 * offset;
        return StatsRange(period, monday, monday + 6);
      case StatsPeriod.month:
        final first = DateTime(local.year, local.month - offset);
        final next = DateTime(first.year, first.month + 1);
        return StatsRange(period, localDay(first), localDay(next) - 1);
    }
  }

  final StatsPeriod period;
  final int firstDay;
  final int lastDay;

  int get length => lastDay - firstDay + 1;

  @override
  bool operator ==(Object other) =>
      other is StatsRange &&
      other.period == period &&
      other.firstDay == firstDay &&
      other.lastDay == lastDay;

  @override
  int get hashCode => Object.hash(period, firstDay, lastDay);
}

/// A row of a top list: a track, artist, or album.
@immutable
class StatsEntry {
  const StatsEntry({
    required this.name,
    required this.listens,
    required this.listenedMs,
    this.detail = "",
    this.trackId,
  });

  /// The title, artist, or album.
  final String name;

  /// The artist of a track or album.
  final String detail;
  final int listens;
  final int listenedMs;

  /// The library track a track row is for.
  final String? trackId;
}

/// Listens on one day of the range.
typedef DayTotal = ({int day, int listens, int listenedMs});

/// Statistics for one [range], with streaks over all of history.
@immutable
class ListeningStats {
  const ListeningStats({
    required this.range,
    required this.listens,
    required this.listenedMs,
    required this.tracks,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.days,
    required this.currentStreak,
    required this.longestStreak,
  });

  /// How many rows each top list has at most.
  static const topCount = 10;

  final StatsRange range;
  final int listens;
  final int listenedMs;

  /// Distinct tracks heard.
  final int tracks;
  final List<StatsEntry> topTracks;
  final List<StatsEntry> topArtists;
  final List<StatsEntry> topAlbums;

  /// Every day of the range, oldest first, including days without listens.
  final List<DayTotal> days;

  /// Consecutive days with a listen up to today, or up to yesterday while
  /// today has none yet.
  final int currentStreak;
  final int longestStreak;

  bool get isEmpty => listens == 0;

  /// Reads statistics from [db]: indexed aggregate queries, a handful of
  /// rows each, whatever the history's length.
  static ListeningStats read(
    Database db,
    StatsRange range, {
    required int today,
  }) {
    final span = [range.firstDay, range.lastDay];
    const inRange = "WHERE day BETWEEN ? AND ?";
    final totals = db
        .select(
          "SELECT count(*) AS listens, coalesce(sum(listened_ms), 0) AS ms, "
          "count(DISTINCT track_id) AS tracks FROM listens $inRange",
          span,
        )
        .first;
    // A bare column beside max() takes its value from the row holding that
    // maximum, so each entry shows its most recent name.
    final topTracks = [
      for (final row in db.select(
        "SELECT track_id, title, artist, max(started_at), count(*) AS listens, "
        "sum(listened_ms) AS ms FROM listens $inRange GROUP BY track_id "
        "ORDER BY listens DESC, ms DESC, title LIMIT $topCount",
        span,
      ))
        StatsEntry(
          trackId: row["track_id"] as String,
          name: row["title"] as String,
          detail: row["artist"] as String,
          listens: row["listens"] as int,
          listenedMs: row["ms"] as int,
        ),
    ];
    final topArtists = [
      for (final row in db.select(
        "SELECT artist, count(*) AS listens, sum(listened_ms) AS ms "
        "FROM listens $inRange AND artist != '' GROUP BY artist "
        "ORDER BY listens DESC, ms DESC, artist LIMIT $topCount",
        span,
      ))
        StatsEntry(
          name: row["artist"] as String,
          listens: row["listens"] as int,
          listenedMs: row["ms"] as int,
        ),
    ];
    final topAlbums = [
      for (final row in db.select(
        "SELECT album, artist, max(started_at), count(*) AS listens, "
        "sum(listened_ms) AS ms FROM listens $inRange AND album != '' "
        "GROUP BY album ORDER BY listens DESC, ms DESC, album "
        "LIMIT $topCount",
        span,
      ))
        StatsEntry(
          name: row["album"] as String,
          detail: row["artist"] as String,
          listens: row["listens"] as int,
          listenedMs: row["ms"] as int,
        ),
    ];
    final perDay = {
      for (final row in db.select(
        "SELECT day, count(*) AS listens, sum(listened_ms) AS ms "
        "FROM listens $inRange GROUP BY day",
        span,
      ))
        row["day"] as int: (
          listens: row["listens"] as int,
          ms: row["ms"] as int,
        ),
    };
    final days = [
      for (var day = range.firstDay; day <= range.lastDay; day++)
        (
          day: day,
          listens: perDay[day]?.listens ?? 0,
          listenedMs: perDay[day]?.ms ?? 0,
        ),
    ];
    final (current, longest) = streaks([
      for (final row in db.select(
        "SELECT DISTINCT day FROM listens WHERE day <= ? ORDER BY day",
        [today],
      ))
        row["day"] as int,
    ], today: today);
    return ListeningStats(
      range: range,
      listens: totals["listens"] as int,
      listenedMs: totals["ms"] as int,
      tracks: totals["tracks"] as int,
      topTracks: topTracks,
      topArtists: topArtists,
      topAlbums: topAlbums,
      days: days,
      currentStreak: current,
      longestStreak: longest,
    );
  }
}

/// The current and longest runs of consecutive [days] (ascending, distinct).
/// The current run ends today, or yesterday while today has no listen yet.
(int current, int longest) streaks(List<int> days, {required int today}) {
  var longest = 0;
  var run = 0;
  int? previous;
  for (final day in days) {
    run = previous != null && day == previous + 1 ? run + 1 : 1;
    longest = max(longest, run);
    previous = day;
  }
  final current = previous != null && previous >= today - 1 ? run : 0;
  return (current, longest);
}

/// Reads statistics from the database at [path] in a background isolate, on
/// a read-only connection of its own, so the UI isolate never waits for it.
Future<ListeningStats> loadListeningStats(
  String path,
  StatsRange range, {
  DateTime? now,
}) {
  final today = localDay(now ?? DateTime.now());
  return Isolate.run(() {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      db.execute("PRAGMA busy_timeout=5000");
      return ListeningStats.read(db, range, today: today);
    } finally {
      db.close();
    }
  });
}
