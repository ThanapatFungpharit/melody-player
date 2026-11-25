/// The listener's sound adjustments: a ten-band equalizer, and gain offsets
/// per track and per album on top of loudness normalization.
///
/// None of it changes files. Offsets reach playback through each queue row's
/// gain, so they work on every platform and follow the same clipping rules
/// as normalization (`adjustedGainDb`). The equalizer runs in the decoder
/// where it has one (Android); its boosts would clip a full-scale track, so
/// while it boosts, every row's gain is lowered by its largest boost.
library;

import "dart:async";
import "dart:math";

import "package:melody_audio/melody_audio.dart" show EqualizerSettings;

import "models.dart";
import "store.dart";

/// The equalizer's band centers, in Hz (the ISO octave bands).
const equalizerFrequencies = <double>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// How far a band moves either way, in dB.
const maxEqualizerGainDb = 12.0;

/// Named equalizer curves, one gain per [equalizerFrequencies] band.
const equalizerPresets = <String, List<double>>{
  "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  "Bass boost": [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  "Treble boost": [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],
  "Vocal": [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
  "Acoustic": [3, 3, 2, 1, 1, 1, 2, 3, 3, 2],
  "Electronic": [5, 4, 1, 0, -2, 1, 0, 1, 4, 5],
  // Once named "Loudness"; renamed so it isn't taken for loudness
  // normalization. Saved curves keep matching it: a preset is stored as its
  // gains, never by name.
  "Bass & treble": [5, 3, 0, 0, -1, 0, -1, 0, 3, 5],
};

/// What a change to the adjustments affects.
enum AdjustmentChange {
  /// The equalizer's curve or switch.
  equalizer,

  /// A track's or album's offset.
  gain,
}

/// The equalizer as the listener set it.
class EqualizerState {
  const EqualizerState({required this.enabled, required this.gains});

  static final flat = EqualizerState(
    enabled: false,
    gains: List.filled(equalizerFrequencies.length, 0.0),
  );

  final bool enabled;

  /// One gain per [equalizerFrequencies] band, in dB.
  final List<double> gains;

  /// The preset these gains match, or null for a curve of one's own.
  String? get preset {
    for (final MapEntry(:key, :value) in equalizerPresets.entries) {
      var same = true;
      for (var index = 0; index < gains.length; index++) {
        if ((gains[index] - value[index]).abs() > 0.05) same = false;
      }
      if (same) return key;
    }
    return null;
  }

  /// The largest boost of any band; 0 while off or only cutting.
  double get maxBoostDb => enabled ? max(0.0, gains.reduce(max)) : 0.0;

  EqualizerSettings get settings => EqualizerSettings(
    enabled: enabled,
    bands: [
      for (final (index, frequency) in equalizerFrequencies.indexed)
        (frequency: frequency, gainDb: gains[index]),
    ],
  );

  factory EqualizerState.fromJson(Object? data) {
    if (data is! Map) return flat;
    final raw = data["gains"];
    final gains = [
      for (var index = 0; index < equalizerFrequencies.length; index++)
        if (raw is List && index < raw.length && raw[index] is num)
          _clampBand((raw[index] as num).toDouble())
        else
          0.0,
    ];
    return EqualizerState(enabled: data["enabled"] == true, gains: gains);
  }

  Map<String, Object?> toJson() => {"enabled": enabled, "gains": gains};
}

double _clampBand(double gain) => gain.isFinite
    ? gain.clamp(-maxEqualizerGainDb, maxEqualizerGainDb).toDouble()
    : 0.0;

double _clampOffset(double gain) => gain.isFinite
    ? gain.clamp(-maxGainOffsetDb, maxGainOffsetDb).toDouble()
    : 0.0;

/// Owns the equalizer and gain offsets and tells playback when they change.
///
/// The equalizer lives in the `equalizer` state row, album offsets in
/// `album_gains` (keyed by album name, as statistics group albums), and a
/// track's offset in its details. Each change is one write; a failed write
/// changes nothing.
class AudioAdjustments {
  AudioAdjustments(
    this._store, {
    required this.equalizerSupported,
    this.applyEqualizer,
  }) {
    _equalizer = EqualizerState.fromJson(_store.get(_equalizerKey));
    _albumGains = {
      if (_store.get(_albumKey) case final Map saved)
        for (final MapEntry(:key, :value) in saved.entries)
          if (key is String && value is num && value.isFinite && value != 0)
            key: _clampOffset(value.toDouble()),
    };
    _sendEqualizer();
  }

  static const _equalizerKey = "equalizer";
  static const _albumKey = "album_gains";

  final ApplicationStore _store;

  /// Whether the decoder on this platform has an equalizer.
  final bool equalizerSupported;

  /// Hands the equalizer to the decoder.
  final void Function(EqualizerSettings settings)? applyEqualizer;

  late EqualizerState _equalizer;
  late Map<String, double> _albumGains;
  final _changes = StreamController<AdjustmentChange>.broadcast(sync: true);

  Stream<AdjustmentChange> get changes => _changes.stream;
  EqualizerState get equalizer => _equalizer;

  /// What every row's gain leaves free for the equalizer's boosts, in dB.
  double get headroomDb => equalizerSupported ? _equalizer.maxBoostDb : 0;

  void setEqualizer(EqualizerState state) {
    final next = EqualizerState(
      enabled: state.enabled,
      gains: [for (final gain in state.gains) _clampBand(gain)],
    );
    _store.set(_equalizerKey, next.toJson());
    _equalizer = next;
    _sendEqualizer();
    _changes.add(AdjustmentChange.equalizer);
  }

  void setEqualizerEnabled(bool enabled) =>
      setEqualizer(EqualizerState(enabled: enabled, gains: _equalizer.gains));

  void setBand(int index, double gainDb) => setEqualizer(
    EqualizerState(
      enabled: _equalizer.enabled,
      gains: [
        for (final (band, gain) in _equalizer.gains.indexed)
          band == index ? gainDb : gain,
      ],
    ),
  );

  void applyPreset(String name) {
    final gains = equalizerPresets[name];
    if (gains == null) return;
    setEqualizer(EqualizerState(enabled: true, gains: gains));
  }

  void _sendEqualizer() {
    if (equalizerSupported) applyEqualizer?.call(_equalizer.settings);
  }

  /// [trackId]'s own offset, in dB.
  double trackGainDb(String trackId) => _store.trackDetails(trackId).gainDb;

  void setTrackGain(String trackId, double gainDb) {
    final details = _store.trackDetails(trackId)
      ..gainDb = (_clampOffset(gainDb) * 2).round() / 2;
    _store.saveTrackDetails(trackId, details);
    _changes.add(AdjustmentChange.gain);
  }

  /// [album]'s offset, in dB; 0 for none.
  double albumGainDb(String album) => _albumGains[album.trim()] ?? 0;

  void setAlbumGain(String album, double gainDb) {
    final key = album.trim();
    if (key.isEmpty) return;
    final value = (_clampOffset(gainDb) * 2).round() / 2;
    final next = {..._albumGains};
    if (value == 0) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    _store.set(_albumKey, next);
    _albumGains = next;
    _changes.add(AdjustmentChange.gain);
  }

  /// The total offset for [trackId]: its own plus its album's.
  double offsetDb(String trackId) {
    final details = _store.trackDetails(trackId);
    final album = details.album.trim();
    return _clampOffset(
      details.gainDb + (album.isEmpty ? 0 : albumGainDb(album)),
    );
  }

  Future<void> close() => _changes.close();
}
