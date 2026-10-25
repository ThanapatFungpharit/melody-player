/// Loudness normalization: measures library tracks in the background and
/// gives playback a per-track gain, so tracks play at a similar loudness.
library;

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:flutter/foundation.dart";

import "../core/library/manager.dart";
import "../core/loudness.dart";
import "../core/storage.dart" show atomicWrite;

/// What changed the gains [LoudnessNormalizer] gives out.
enum LoudnessChange {
  /// New measurements: tracks that start from now on use them.
  measured,

  /// Normalization was switched on or off, or the target moved: the
  /// playing track follows too.
  settings,
}

/// The file a measurement belongs to: when its size or modification time
/// changes, the track is measured again.
typedef _Fingerprint = ({int size, int modified});

class _Entry {
  const _Entry(this.file, {this.measurement, this.error});

  final _Fingerprint file;
  final LoudnessMeasurement? measurement;

  /// Why FFmpeg could not measure the file; it is not tried again until
  /// the file changes.
  final String? error;

  /// The same result for the file as it is now, when only its tags changed.
  _Entry movedTo(_Fingerprint file) =>
      _Entry(file, measurement: measurement, error: error);

  static _Entry? fromJson(Object? data) {
    if (data is! Map) return null;
    final size = data["size"];
    final modified = data["modified"];
    if (size is! int || modified is! int) return null;
    final file = (size: size, modified: modified);
    final lufs = data["lufs"];
    final peak = data["peak"];
    if (lufs is num && lufs.isFinite) {
      return _Entry(
        file,
        measurement: LoudnessMeasurement(
          integratedLufs: lufs.toDouble(),
          // JSON has no infinity: digital silence is stored without a peak.
          truePeakDb: peak is num && peak.isFinite
              ? peak.toDouble()
              : double.negativeInfinity,
          audioHash: switch (data["audio"]) {
            final String hash => hash,
            _ => null,
          },
        ),
      );
    }
    final error = data["error"];
    return error is String ? _Entry(file, error: error) : null;
  }

  Map<String, Object?> toJson() => {
    "size": file.size,
    "modified": file.modified,
    if (measurement case final measured?) ...{
      "lufs": measured.integratedLufs,
      if (measured.truePeakDb.isFinite) "peak": measured.truePeakDb,
      "audio": ?measured.audioHash,
    },
    "error": ?error,
  };
}

/// Measures library tracks with FFmpeg one at a time, in the background,
/// and turns the results into playback gains.
///
/// Results are cached in `cache/loudness.json` by track ID with the file's
/// size and modification time, so a changed file is measured again and the
/// cache can be deleted at any time. A track that is not measured yet, or
/// cannot be measured (corrupted or unsupported), plays at the library's
/// typical gain (the median), so it is not much louder than its neighbors.
/// Original files are never changed.
class LoudnessNormalizer {
  /// A normalizer with nothing measured yet; [open] loads the cache.
  LoudnessNormalizer(
    this._manager,
    this._cachePath,
    this._meter, {
    required this._enabled,
    required this._targetLufs,
    this.maxBoostDb = 0,
    this.limiterHeadroomDb = 0,
    this._hasher,
    this.saveDelay = const Duration(seconds: 3),
    this.notifyDelay = const Duration(seconds: 1),
  });

  /// Loads the cache; an unreadable one starts empty.
  static Future<LoudnessNormalizer> open(
    MusicManager manager,
    String cachePath,
    LoudnessMeter meter, {
    required bool enabled,
    required double targetLufs,
    double maxBoostDb = 0,
    double limiterHeadroomDb = 0,
    AudioHasher? hasher,
    Duration saveDelay = const Duration(seconds: 3),
    Duration notifyDelay = const Duration(seconds: 1),
  }) async {
    var entries = <String, _Entry>{};
    try {
      entries = await Isolate.run(() => _readCache(cachePath));
    } on Object catch (error) {
      debugPrint("Loudness measurements will be taken again: $error");
    }
    return LoudnessNormalizer(
      manager,
      cachePath,
      meter,
      enabled: enabled,
      targetLufs: targetLufs,
      maxBoostDb: maxBoostDb,
      limiterHeadroomDb: limiterHeadroomDb,
      hasher: hasher,
      saveDelay: saveDelay,
      notifyDelay: notifyDelay,
    ).._entries.addAll(entries);
  }

  final MusicManager _manager;
  final String _cachePath;
  final LoudnessMeter _meter;

  /// Tells a tag-only rewrite (lyrics, cover art) from new audio, so it is
  /// not measured again.
  final AudioHasher? _hasher;

  /// How far a quiet track may be raised (the audio engine's limit here).
  final double maxBoostDb;

  /// How far a boost may take peaks over the ceiling, where the audio
  /// engine limits them (0 where it has no limiter).
  final double limiterHeadroomDb;
  final Map<String, _Entry> _entries = {};

  /// How long new measurements wait before the cache is written, so a
  /// library pass writes it every few seconds rather than per track.
  final Duration saveDelay;

  /// New measurements are announced together at most this often.
  final Duration notifyDelay;

  bool _enabled;
  double _targetLufs;
  double? _typicalGainDb;

  final _changes = StreamController<LoudnessChange>.broadcast(sync: true);
  final _pending = <String>{};
  final _priority = <String>{};
  final _closing = Completer<void>();
  Completer<void>? _draining;
  Timer? _saveTimer;

  /// Unsaved changes, and the write in progress (one at a time).
  bool _dirty = false;
  Future<void> _saving = Future.value();
  Timer? _notifyTimer;
  bool _available = true;

  Stream<LoudnessChange> get changes => _changes.stream;
  bool get enabled => _enabled;
  double get targetLufs => _targetLufs;
  bool get _closed => _closing.isCompleted;

  /// False once FFmpeg could not be started; nothing more is measured
  /// this session.
  bool get available => _available;

  /// Library tracks with a current measurement (or a known failure).
  int get analyzedCount =>
      _entries.keys.where((id) => _manager.hasTrack(id)).length;

  /// Applies the user's settings; the playing track follows.
  void configure({required bool enabled, required double targetLufs}) {
    if (enabled == _enabled && targetLufs == _targetLufs) return;
    _enabled = enabled;
    _targetLufs = targetLufs;
    _typicalGainDb = null;
    if (!_changes.isClosed) _changes.add(LoudnessChange.settings);
  }

  /// The linear volume factor for [trackId] (1 when normalization is off).
  double gainFor(String trackId) {
    if (!_enabled) return 1;
    final measurement = _entries[trackId]?.measurement;
    return linearGain(
      measurement == null ? _typicalGain() : _gainDb(measurement),
    );
  }

  double _gainDb(LoudnessMeasurement measurement) => normalizationGainDb(
    measurement,
    targetLufs: _targetLufs,
    maxBoostDb: maxBoostDb,
    limiterHeadroomDb: limiterHeadroomDb,
  );

  /// The factor for a track that is not measured, such as a stream.
  double get fallbackGain => _enabled ? linearGain(_typicalGain()) : 1;

  /// The median gain of the measured, non-silent tracks; 0 dB before any.
  double _typicalGain() => _typicalGainDb ??= () {
    final gains = [
      for (final MapEntry(key: id, value: entry) in _entries.entries)
        if (entry.measurement case final measured?
            when !measured.silent && _manager.hasTrack(id))
          _gainDb(measured),
    ]..sort();
    if (gains.isEmpty) return 0.0;
    final middle = gains.length ~/ 2;
    return gains.length.isOdd
        ? gains[middle]
        : (gains[middle - 1] + gains[middle]) / 2;
  }();

  /// Queues tracks for measurement. [first] puts them ahead of the rest,
  /// such as the track that is starting to play. Tracks whose measurement
  /// is current are skipped after a quick check of their file.
  void analyze(Iterable<String> trackIds, {bool first = false}) {
    if (_closed || !_available) return;
    for (final id in trackIds) {
      if (first) {
        _pending.remove(id);
        _priority.add(id);
      } else if (!_priority.contains(id)) {
        _pending.add(id);
      }
    }
    if ((_pending.isNotEmpty || _priority.isNotEmpty) && _draining == null) {
      unawaited(_drain());
    }
  }

  /// Queues library tracks not measured since their file last changed,
  /// and forgets tracks the library no longer has. The files are checked
  /// together in one background isolate.
  Future<void> analyzeLibrary() async {
    if (_closed || !_available) return;
    final removed = _entries.keys.where((id) => !_manager.hasTrack(id));
    if (removed.isNotEmpty) {
      _entries.removeWhere((id, _) => !_manager.hasTrack(id));
      _typicalGainDb = null;
      _scheduleSave();
    }
    final paths = _trackPaths(_manager.listTracks().map((track) => track.id));
    final Map<String, _Fingerprint?> files;
    try {
      files = await _fingerprintAll(paths);
    } on Object catch (error) {
      debugPrint("Could not check files for loudness measurement: $error");
      return;
    }
    analyze([
      for (final MapEntry(key: id, value: file) in files.entries)
        if (file != null && _entries[id]?.file != file) id,
    ]);
  }

  /// Queues tracks the library has but the cache has never seen, such as
  /// new downloads and imports. Needs no disk access.
  void analyzeNew() => analyze([
    for (final track in _manager.listTracks())
      if (!_entries.containsKey(track.id)) track.id,
  ]);

  /// Completes once nothing is queued.
  @visibleForTesting
  Future<void> get idle => _draining?.future ?? Future.value();

  /// Stops measuring (killing a running FFmpeg) and writes the cache.
  Future<void> close() async {
    if (_closed) return;
    _closing.complete();
    _pending.clear();
    _priority.clear();
    _notifyTimer?.cancel();
    await _changes.close();
    _saveTimer?.cancel();
    await _flush();
  }

  Future<void> _drain() async {
    final draining = _draining = Completer<void>();
    try {
      while (!_closed && _available) {
        final String trackId;
        if (_priority.isNotEmpty) {
          trackId = _priority.first;
          _priority.remove(trackId);
        } else if (_pending.isNotEmpty) {
          trackId = _pending.first;
          _pending.remove(trackId);
        } else {
          break;
        }
        await _measure(trackId);
      }
    } finally {
      _draining = null;
      draining.complete();
    }
  }

  Future<void> _measure(String trackId) async {
    if (!_manager.hasTrack(trackId)) return;
    final path = _trackPaths([trackId])[trackId];
    if (path == null) return;
    final _Fingerprint file;
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return;
      file = (size: stat.size, modified: stat.modified.millisecondsSinceEpoch);
    } on FileSystemException {
      return;
    }
    final known = _entries[trackId];
    if (known?.file == file) return;
    _Entry entry;
    try {
      final hash = known?.measurement?.audioHash;
      if (hash != null &&
          _hasher != null &&
          await _sameAudio(path, hash, _hasher)) {
        // Only the tags changed: keep the measurement for the new file.
        entry = known!.movedTo(file);
      } else {
        final measurement = await _meter(path, cancel: _closing.future);
        entry = _Entry(file, measurement: measurement);
      }
    } on LoudnessUnmeasurable catch (error) {
      debugPrint("Loudness of $path cannot be measured: ${error.message}");
      entry = _Entry(file, error: error.message);
    } on ProcessException catch (error) {
      // FFmpeg is missing or cannot run here: every track would fail alike.
      debugPrint("Loudness normalization is unavailable: $error");
      _available = false;
      _pending.clear();
      _priority.clear();
      return;
    } on Object catch (error) {
      // A timeout, cancellation, or disk error: tried again next launch.
      if (!_closed) debugPrint("Loudness of $path was not measured: $error");
      return;
    }
    // The track may have been removed, or its file replaced, meanwhile.
    if (_closed || !_manager.hasTrack(trackId)) return;
    _entries[trackId] = entry;
    _scheduleSave();
    if (identical(entry.measurement, known?.measurement)) return;
    _typicalGainDb = null;
    _scheduleNotify();
  }

  /// Whether the file at [path] still holds the audio hashed as [hash]. A
  /// file whose audio cannot be read is measured, which records why.
  Future<bool> _sameAudio(String path, String hash, AudioHasher hasher) async {
    try {
      return await hasher(path, cancel: _closing.future) == hash;
    } on LoudnessUnmeasurable {
      return false;
    }
  }

  Map<String, String> _trackPaths(Iterable<String> trackIds) {
    final paths = <String, String>{};
    for (final id in trackIds) {
      try {
        paths[id] = _manager.trackPath(id);
      } on ArgumentError {
        // Its stored path is outside the music folders: not playable.
      }
    }
    return paths;
  }

  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(notifyDelay, () {
      if (!_changes.isClosed) _changes.add(LoudnessChange.measured);
    });
  }

  void _scheduleSave() {
    _dirty = true;
    if (_closed || (_saveTimer?.isActive ?? false)) return;
    _saveTimer = Timer(saveDelay, () => unawaited(_flush()));
  }

  /// Writes after any write in progress, so two never race to the file.
  Future<void> _flush() => _saving = _saving.then((_) => _save());

  Future<void> _save() async {
    if (!_dirty) return;
    _dirty = false;
    final json = jsonEncode({
      "version": 1,
      "tracks": {
        for (final MapEntry(:key, :value) in _entries.entries)
          key: value.toJson(),
      },
    });
    try {
      await atomicWrite(_cachePath, utf8.encode(json));
    } on Object catch (error) {
      // Only a cache: the measurements are taken again next launch.
      debugPrint("Could not save loudness measurements: $error");
    }
  }
}

Map<String, _Entry> _readCache(String path) {
  final File file = File(path);
  if (!file.existsSync()) return {};
  final data = jsonDecode(file.readAsStringSync());
  final tracks = data is Map && data["version"] == 1 ? data["tracks"] : null;
  if (tracks is! Map) return {};
  return {
    for (final MapEntry(:key, :value) in tracks.entries)
      if (key is String) key: ?_Entry.fromJson(value),
  };
}

/// Checks every file in one background isolate. Top-level, so the closure
/// sent to the isolate captures only [paths].
Future<Map<String, _Fingerprint?>> _fingerprintAll(Map<String, String> paths) =>
    Isolate.run(
      () => {
        for (final MapEntry(key: id, value: path) in paths.entries)
          id: _fingerprint(path),
      },
    );

_Fingerprint? _fingerprint(String path) {
  try {
    final stat = File(path).statSync();
    if (stat.type != FileSystemEntityType.file) return null;
    return (size: stat.size, modified: stat.modified.millisecondsSinceEpoch);
  } on FileSystemException {
    return null;
  }
}
