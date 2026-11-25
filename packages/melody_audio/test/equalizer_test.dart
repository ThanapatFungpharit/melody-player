import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/melody_audio.dart";

void main() {
  const bands = <EqualizerBand>[
    (frequency: 100, gainDb: 6),
    (frequency: 400, gainDb: 0),
    (frequency: 1600, gainDb: -6),
  ];

  test("a device band between two of ours takes a log-scale blend", () {
    expect(equalizerGainAt(bands, 100), 6);
    // 200 Hz is one octave above 100, half of the two to 400.
    expect(equalizerGainAt(bands, 200), closeTo(3, 1e-9));
    expect(equalizerGainAt(bands, 800), closeTo(-3, 1e-9));
  });

  test("beyond the outer bands the outer gain holds", () {
    expect(equalizerGainAt(bands, 20), 6);
    expect(equalizerGainAt(bands, 20000), -6);
    expect(equalizerGainAt(const [], 1000), 0);
    expect(equalizerGainAt(bands, 0), 0);
  });

  test("flat or switched-off settings do nothing", () {
    expect(EqualizerSettings.off.active, isFalse);
    expect(
      const EqualizerSettings(
        enabled: true,
        bands: [(frequency: 100, gainDb: 0.01)],
      ).active,
      isFalse,
    );
    expect(const EqualizerSettings(bands: bands).active, isFalse);
    expect(const EqualizerSettings(enabled: true, bands: bands).active, isTrue);
    expect(
      const EqualizerSettings(enabled: true, bands: bands),
      const EqualizerSettings(enabled: true, bands: [...bands]),
    );
  });
}
