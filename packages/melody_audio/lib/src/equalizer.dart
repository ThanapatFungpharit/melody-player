import "dart:math" show log, ln2;

import "package:flutter/foundation.dart";

/// One band of the listener's equalizer: a center frequency and its gain.
typedef EqualizerBand = ({double frequency, double gainDb});

/// What the engine's equalizer should do. The bands are the listener's own
/// layout; each decoder maps them onto the bands its effect has
/// ([equalizerGainAt]).
@immutable
class EqualizerSettings {
  const EqualizerSettings({this.enabled = false, this.bands = const []});

  /// Flat: the effect is off, and playback takes the same path as without it.
  static const off = EqualizerSettings();

  final bool enabled;
  final List<EqualizerBand> bands;

  /// Whether the settings change the sound at all.
  bool get active => enabled && bands.any((band) => band.gainDb.abs() >= 0.05);

  @override
  bool operator ==(Object other) =>
      other is EqualizerSettings &&
      other.enabled == enabled &&
      listEquals(other.bands, bands);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(bands));
}

/// The gain [bands] (ascending by frequency) ask for at [frequency]:
/// interpolated on a logarithmic frequency scale between the nearest two,
/// and the outermost band's gain beyond them.
double equalizerGainAt(List<EqualizerBand> bands, double frequency) {
  if (bands.isEmpty || frequency <= 0) return 0;
  if (frequency <= bands.first.frequency) return bands.first.gainDb;
  if (frequency >= bands.last.frequency) return bands.last.gainDb;
  for (var index = 1; index < bands.length; index++) {
    final high = bands[index];
    if (frequency > high.frequency) continue;
    final low = bands[index - 1];
    double octaves(double hz) => log(hz) / ln2;
    final span = octaves(high.frequency) - octaves(low.frequency);
    if (span <= 0) return high.gainDb;
    final t = (octaves(frequency) - octaves(low.frequency)) / span;
    return low.gainDb + (high.gainDb - low.gainDb) * t;
  }
  return bands.last.gainDb;
}
