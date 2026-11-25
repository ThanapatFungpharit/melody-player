import "../support/temp.dart";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/audio_adjustments.dart";
import "package:melody/application/models.dart";
import "package:melody/application/store.dart";
import "package:melody_audio/melody_audio.dart" show EqualizerSettings;
import "package:path/path.dart" as p;

void main() {
  late Directory root;
  late ApplicationStore store;

  ApplicationStore open() => ApplicationStore.open(
    p.join(root.path, "state.db"),
    defaultDownloadDirectory: p.join(root.path, "music"),
  );

  setUp(() async {
    root = await createTestDirectory("melody-adjustments");
    store = open();
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test("the equalizer starts flat and off, and is sent to the decoder", () {
    final sent = <EqualizerSettings>[];
    final adjustments = AudioAdjustments(
      store,
      equalizerSupported: true,
      applyEqualizer: sent.add,
    );
    expect(adjustments.equalizer.enabled, isFalse);
    expect(adjustments.equalizer.preset, "Flat");
    expect(adjustments.headroomDb, 0);
    expect(sent.single.active, isFalse);
  });

  test("presets, bands, and the switch survive a restart", () async {
    final adjustments = AudioAdjustments(store, equalizerSupported: true)
      ..applyPreset("Bass boost");
    expect(adjustments.equalizer.enabled, isTrue);
    expect(adjustments.equalizer.preset, "Bass boost");
    expect(adjustments.headroomDb, 6);
    adjustments.setBand(9, 3);
    expect(adjustments.equalizer.preset, isNull);

    await store.close();
    store = open();
    final sent = <EqualizerSettings>[];
    final restored = AudioAdjustments(
      store,
      equalizerSupported: true,
      applyEqualizer: sent.add,
    );
    expect(restored.equalizer.gains.first, 6);
    expect(restored.equalizer.gains.last, 3);
    expect(sent.single.bands.last, (frequency: 16000.0, gainDb: 3.0));
  });

  test("stored values out of range or malformed are tamed", () {
    store.set("equalizer", {
      "enabled": true,
      "gains": [99, -99, "x", double.maxFinite, null],
    });
    store.set("album_gains", {"LP": 40, "Bad": "x", "": 3});
    final adjustments = AudioAdjustments(store, equalizerSupported: true);
    expect(adjustments.equalizer.gains, [12, -12, 0, 12, 0, 0, 0, 0, 0, 0]);
    expect(adjustments.albumGainDb("LP"), maxGainOffsetDb);
    expect(adjustments.albumGainDb("Bad"), 0);
  });

  test("an unsupported equalizer is remembered but takes no headroom", () {
    final sent = <EqualizerSettings>[];
    final adjustments = AudioAdjustments(
      store,
      equalizerSupported: false,
      applyEqualizer: sent.add,
    )..applyPreset("Bass & treble");
    expect(adjustments.equalizer.enabled, isTrue);
    expect(adjustments.headroomDb, 0);
    expect(sent, isEmpty);
  });

  test("a curve saved before a preset was renamed still matches it", () {
    store.set("equalizer", {
      "enabled": true,
      "gains": [5, 3, 0, 0, -1, 0, -1, 0, 3, 5],
    });
    final adjustments = AudioAdjustments(store, equalizerSupported: true);
    expect(adjustments.equalizer.enabled, isTrue);
    expect(adjustments.equalizer.preset, "Bass & treble");
  });

  test("a track's offset adds to its album's and announces itself", () async {
    final adjustments = AudioAdjustments(store, equalizerSupported: false);
    final changes = <AdjustmentChange>[];
    adjustments.changes.listen(changes.add);
    store.saveTrackDetails("t1", TrackDetails(album: "LP"));
    store.saveTrackDetails("t2", TrackDetails());

    adjustments
      ..setTrackGain("t1", -2.3)
      ..setAlbumGain("LP", 4);
    expect(adjustments.trackGainDb("t1"), -2.5);
    expect(adjustments.offsetDb("t1"), 1.5);
    expect(adjustments.offsetDb("t2"), 0);
    expect(changes, [AdjustmentChange.gain, AdjustmentChange.gain]);

    // A zero offset removes the album's entry.
    adjustments.setAlbumGain("LP", 0);
    expect(store.get("album_gains"), isEmpty);
  });

  test("a failed write changes nothing", () async {
    final adjustments = AudioAdjustments(store, equalizerSupported: true);
    await store.close();
    expect(() => adjustments.applyPreset("Vocal"), throwsA(anything));
    expect(adjustments.equalizer.enabled, isFalse);
    expect(() => adjustments.setAlbumGain("LP", 3), throwsA(anything));
    expect(adjustments.albumGainDb("LP"), 0);
    store = open();
  });

  test("details without an album or offset keep their stored form", () {
    final json = TrackDetails(uploader: "A").toJson();
    expect(json.containsKey("album"), isFalse);
    expect(json.containsKey("gain_db"), isFalse);
    final round = TrackDetails.fromJson({
      ...json,
      "album": "LP",
      "gain_db": 30,
    });
    expect(round.album, "LP");
    expect(round.gainDb, maxGainOffsetDb);
  });
}
