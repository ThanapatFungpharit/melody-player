import "package:flutter_test/flutter_test.dart";
import "package:melody/core/loudness.dart";

void main() {
  const peakAt3 = LoudnessMeasurement(integratedLufs: -14, truePeakDb: -3);

  test("no offset leaves normalization's gain alone", () {
    expect(adjustedGainDb(-4, 0, measurement: peakAt3, maxBoostDb: 6), -4);
  });

  test("a cut always applies, down to the minimum gain", () {
    expect(adjustedGainDb(2, -5, measurement: peakAt3, maxBoostDb: 6), -3);
    expect(adjustedGainDb(-25, -12), minimumGainDb);
  });

  test("a raise stops at the true-peak ceiling", () {
    // Peaks at -3 dBTP leave 2 dB to the -1 dBTP ceiling.
    expect(adjustedGainDb(0, 6, measurement: peakAt3, maxBoostDb: 6), 2);
    // Already cut by normalization: the raise can bring it back up to there.
    expect(adjustedGainDb(-6, 3, measurement: peakAt3, maxBoostDb: 6), -3);
  });

  test("a limiter lets a boost past the ceiling by its headroom", () {
    expect(
      adjustedGainDb(
        0,
        12,
        measurement: peakAt3,
        maxBoostDb: 12,
        limiterHeadroomDb: 6,
      ),
      8,
    );
  });

  test("an engine that cannot boost keeps raises at unity", () {
    expect(adjustedGainDb(-2, 6, measurement: peakAt3), 0);
    expect(adjustedGainDb(0, 6, measurement: peakAt3), 0);
  });

  test("unknown peaks allow no raise above the track's own level", () {
    expect(adjustedGainDb(0, 6, maxBoostDb: 6), 0);
    expect(adjustedGainDb(-4, 3, maxBoostDb: 6), -1);
    expect(adjustedGainDb(0, 3, maxBoostDb: 12, limiterHeadroomDb: 6), 3);
  });

  test("a raise never lowers what normalization gave", () {
    const hot = LoudnessMeasurement(integratedLufs: -20, truePeakDb: 0.5);
    expect(adjustedGainDb(3, 2, measurement: hot, maxBoostDb: 6), 3);
  });

  test("non-finite offsets are ignored", () {
    expect(adjustedGainDb(-1, double.nan), -1);
    expect(adjustedGainDb(-1, double.infinity), -1);
  });

  group("the playback chain", () {
    test(
      "is normalization, then the offset, then the equalizer's headroom",
      () {
        // -4 dB from normalization, +1 within the peaks, 3 dB kept free.
        expect(
          playbackGainDb(
            normalizationDb: -4,
            offsetDb: 1,
            equalizerHeadroomDb: 3,
            measurement: peakAt3,
            maxBoostDb: 6,
          ),
          -6,
        );
      },
    );

    test("keeps headroom for the equalizer even past the peak limit", () {
      // The raise stops at +2 (the ceiling); the headroom still comes off.
      expect(
        playbackGainDb(
          normalizationDb: 0,
          offsetDb: 6,
          equalizerHeadroomDb: 4,
          measurement: peakAt3,
          maxBoostDb: 6,
        ),
        -2,
      );
    });

    test("without a measurement, only cuts apply", () {
      expect(playbackGainDb(normalizationDb: 0, offsetDb: 5), 0);
      expect(
        playbackGainDb(
          normalizationDb: 0,
          offsetDb: -5,
          equalizerHeadroomDb: 2,
        ),
        -7,
      );
    });

    test("ignores a negative headroom", () {
      expect(playbackGainDb(normalizationDb: -3, equalizerHeadroomDb: -4), -3);
    });

    test("leaves a silent track at normalization's gain", () {
      const silent = LoudnessMeasurement(
        integratedLufs: LoudnessMeasurement.silenceLufs,
        truePeakDb: double.negativeInfinity,
      );
      expect(
        playbackGainDb(
          normalizationDb: 0,
          offsetDb: -6,
          equalizerHeadroomDb: 6,
          measurement: silent,
          maxBoostDb: 6,
        ),
        0,
      );
    });
  });
}
