import "../support/temp.dart";
import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/loudness.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/loudness.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;
  late String music;
  late String cache;
  late MusicManager manager;

  /// Integrated loudness by file name; a missing name cannot be measured.
  late Map<String, double> loudness;
  late List<String> measured;
  late List<String> hashed;

  /// The fake files' audio is their text before any `#`; what follows is
  /// tags.
  Future<String> audioOf(String path) async =>
      (await File(path).readAsString()).split("#").first;

  Future<LoudnessMeasurement> meter(String path, {Future<void>? cancel}) async {
    final name = p.basename(path);
    measured.add(name);
    final lufs = loudness[name];
    if (lufs == null) throw const LoudnessUnmeasurable("Invalid data");
    return LoudnessMeasurement(
      integratedLufs: lufs,
      truePeakDb: -3,
      audioHash: await audioOf(path),
    );
  }

  Future<String> hasher(String path, {Future<void>? cancel}) async {
    hashed.add(p.basename(path));
    final audio = await audioOf(path);
    if (audio.isEmpty) throw const LoudnessUnmeasurable("No audio");
    return audio;
  }

  Future<LoudnessNormalizer> open({
    LoudnessMeter? using,
    bool enabled = true,
    double maxBoostDb = 0,
    double limiterHeadroomDb = 0,
  }) => LoudnessNormalizer.open(
    manager,
    cache,
    using ?? meter,
    hasher: hasher,
    enabled: enabled,
    targetLufs: -14,
    maxBoostDb: maxBoostDb,
    limiterHeadroomDb: limiterHeadroomDb,
    saveDelay: Duration.zero,
    notifyDelay: Duration.zero,
  );

  Future<String> track(String name) async {
    final path = p.join(music, name);
    await File(path).writeAsString(name);
    return manager.addTrack(path, title: name);
  }

  setUp(() async {
    root = await createTestDirectory("melody-loudness");
    music = p.join(root.path, "music");
    cache = p.join(root.path, "cache", "loudness.json");
    await Directory(music).create();
    manager = MusicManager.open(p.join(root.path, "library.db"), music);
    loudness = {};
    measured = [];
    hashed = [];
  });

  tearDown(() async {
    await manager.close();
    await root.delete(recursive: true);
  });

  test("gains bring loud tracks to the target and never boost", () async {
    final loud = await track("loud.mp3");
    final quiet = await track("quiet.mp3");
    loudness.addAll({"loud.mp3": -8, "quiet.mp3": -20});
    final normalizer = await open();
    await normalizer.analyzeLibrary();
    await normalizer.idle;

    expect(normalizer.gainFor(loud), closeTo(linearGain(-6), 1e-9));
    expect(normalizer.gainFor(quiet), 1);
    expect(normalizer.analyzedCount, 2);

    normalizer.configure(enabled: true, targetLufs: -18);
    expect(normalizer.gainFor(loud), closeTo(linearGain(-10), 1e-9));
    normalizer.configure(enabled: false, targetLufs: -18);
    expect(normalizer.gainFor(loud), 1);
    expect(normalizer.fallbackGain, 1);
    await normalizer.close();
  });

  test(
    "unmeasured and unmeasurable tracks play at the library's median gain",
    () async {
      final ids = [
        for (final name in ["a.mp3", "b.mp3", "c.mp3", "broken.mp3"])
          await track(name),
      ];
      final normalizer = await open();
      // Nothing measured yet: unchanged.
      expect(normalizer.gainFor(ids[0]), 1);

      loudness.addAll({"a.mp3": -10, "b.mp3": -11, "c.mp3": -20});
      await normalizer.analyzeLibrary();
      await normalizer.idle;

      // Gains -4, -3, and 0 dB: the median is -3 dB.
      expect(normalizer.gainFor(ids[3]), closeTo(linearGain(-3), 1e-9));
      expect(normalizer.fallbackGain, closeTo(linearGain(-3), 1e-9));
      await normalizer.close();
    },
  );

  test("quiet tracks are raised where the engine can boost", () async {
    final quiet = await track("quiet.mp3");
    final faint = await track("faint.mp3");
    loudness.addAll({"quiet.mp3": -18, "faint.mp3": -40});
    final normalizer = await open(maxBoostDb: 6);
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    // The fake peaks at -3 dBTP, leaving 2 dB below the ceiling.
    expect(normalizer.gainFor(quiet), closeTo(linearGain(2), 1e-9));
    expect(normalizer.gainFor(faint), closeTo(linearGain(2), 1e-9));
    await normalizer.close();
  });

  test("a limiting engine raises quiet tracks past their peaks", () async {
    final quiet = await track("quiet.mp3");
    final faint = await track("faint.mp3");
    loudness.addAll({"quiet.mp3": -18, "faint.mp3": -40});
    final normalizer = await open(maxBoostDb: 12, limiterHeadroomDb: 6);
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    // To the target; the faint one by as much as 6 dB of limiting allows.
    expect(normalizer.gainFor(quiet), closeTo(linearGain(4), 1e-9));
    expect(normalizer.gainFor(faint), closeTo(linearGain(8), 1e-9));
    await normalizer.close();
  });

  test("rewriting only the tags keeps the measurement", () async {
    final id = await track("song.mp3");
    loudness["song.mp3"] = -9;
    var normalizer = await open();
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    final gain = normalizer.gainFor(id);
    // Let the first pass's announcement go out.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final changes = <LoudnessChange>[];
    normalizer.changes.listen(changes.add);

    // The lyrics embedder rewrites the file: new size and time, same audio.
    final path = manager.trackPath(id);
    await File(path).writeAsString("song.mp3#USLT lyrics and a cover");
    await File(path).setLastModified(DateTime(2030));
    measured.clear();
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    expect(hashed, ["song.mp3"]);
    expect(measured, isEmpty);
    expect(normalizer.gainFor(id), gain);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(changes, isEmpty);
    await normalizer.close();

    // The cache follows the rewritten file, so the next launch does nothing.
    hashed.clear();
    normalizer = await open();
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    expect(hashed, isEmpty);
    expect(measured, isEmpty);
    await normalizer.close();
  });

  test("new audio, or audio that cannot be hashed, is measured", () async {
    final id = await track("song.mp3");
    loudness["song.mp3"] = -9;
    final normalizer = await open();
    await normalizer.analyzeLibrary();
    await normalizer.idle;

    final path = manager.trackPath(id);
    await File(path).writeAsString("a remaster#same tags");
    await File(path).setLastModified(DateTime(2030));
    loudness["song.mp3"] = -12;
    measured.clear();
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    expect(measured, ["song.mp3"]);
    expect(normalizer.gainFor(id), closeTo(linearGain(-2), 1e-9));

    await File(path).writeAsString("#tags around broken audio");
    await File(path).setLastModified(DateTime(2031));
    loudness.remove("song.mp3");
    measured.clear();
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    // Measured, which records the file as unmeasurable.
    expect(measured, ["song.mp3"]);
    expect(normalizer.gainFor(id), normalizer.fallbackGain);
    await normalizer.close();
  });

  test("results are cached until a file changes", () async {
    final id = await track("song.mp3");
    await track("broken.mp3");
    loudness["song.mp3"] = -9;
    var normalizer = await open();
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    await normalizer.close();
    expect(measured, unorderedEquals(["song.mp3", "broken.mp3"]));
    final saved = jsonDecode(await File(cache).readAsString()) as Map;
    expect((saved["tracks"] as Map).keys, hasLength(2));

    // A later launch measures nothing again, failures included.
    measured.clear();
    normalizer = await open();
    expect(normalizer.gainFor(id), closeTo(linearGain(-5), 1e-9));
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    expect(measured, isEmpty);

    // A rewritten file is measured again.
    final path = manager.trackPath(id);
    await File(path).writeAsString("a longer, louder master");
    await File(path).setLastModified(DateTime(2030));
    loudness["song.mp3"] = -6;
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    expect(measured, ["song.mp3"]);
    expect(normalizer.gainFor(id), closeTo(linearGain(-8), 1e-9));
    await normalizer.close();
  });

  test(
    "a corrupt cache starts over, and removed tracks are forgotten",
    () async {
      await Directory(p.dirname(cache)).create(recursive: true);
      await File(cache).writeAsString("{not json");
      final id = await track("song.mp3");
      loudness["song.mp3"] = -9;
      final normalizer = await open();
      await normalizer.analyzeLibrary();
      await normalizer.idle;
      expect(normalizer.analyzedCount, 1);

      manager.deleteTrack(id);
      await normalizer.analyzeLibrary();
      await normalizer.close();
      final saved = jsonDecode(await File(cache).readAsString()) as Map;
      expect(saved["tracks"], isEmpty);
    },
  );

  test("prioritized tracks are measured first", () async {
    final ids = [
      for (final name in ["1.mp3", "2.mp3", "3.mp3"]) await track(name),
    ];
    for (final id in ids) {
      loudness[p.basename(manager.trackPath(id))] = -10;
    }
    final gate = Completer<void>();
    final normalizer = await open(
      using: (path, {cancel}) async {
        await gate.future;
        return meter(path);
      },
    );
    normalizer.analyze(ids);
    // The first is already running; the last jumps the rest of the queue.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    normalizer.analyze([ids[2]], first: true);
    gate.complete();
    await normalizer.idle;
    expect(measured, ["1.mp3", "3.mp3", "2.mp3"]);
    await normalizer.close();
  });

  test("new library tracks are queued without touching the disk", () async {
    await track("old.mp3");
    loudness.addAll({"old.mp3": -9, "new.mp3": -9});
    final normalizer = await open();
    normalizer.analyzeNew();
    await normalizer.idle;
    final added = await track("new.mp3");
    measured.clear();
    normalizer.analyzeNew();
    await normalizer.idle;
    expect(measured, ["new.mp3"]);
    expect(normalizer.gainFor(added), lessThan(1));
    await normalizer.close();
  });

  test("a missing FFmpeg turns measuring off for the session", () async {
    final ids = [
      for (final name in ["a.mp3", "b.mp3"]) await track(name),
    ];
    var attempts = 0;
    final normalizer = await open(
      using: (path, {cancel}) async {
        attempts++;
        throw const ProcessException("ffmpeg", [], "not found");
      },
    );
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    expect(attempts, 1);
    expect(normalizer.available, isFalse);
    expect(normalizer.gainFor(ids[0]), 1);
    normalizer.analyze(ids);
    await normalizer.idle;
    expect(attempts, 1);
    await normalizer.close();
  });

  test("closing cancels a running measurement and records nothing", () async {
    await track("long.mp3");
    final started = Completer<void>();
    final normalizer = await open(
      using: (path, {cancel}) async {
        started.complete();
        await cancel;
        throw const LoudnessCancelled();
      },
    );
    unawaited(normalizer.analyzeLibrary());
    await started.future;
    await normalizer.close();
    await normalizer.idle;
    expect(normalizer.analyzedCount, 0);
  });

  test("settings changes and measurements are announced", () async {
    await track("song.mp3");
    loudness["song.mp3"] = -9;
    final normalizer = await open();
    final changes = <LoudnessChange>[];
    normalizer.changes.listen(changes.add);
    await normalizer.analyzeLibrary();
    await normalizer.idle;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    normalizer.configure(enabled: true, targetLufs: -14);
    normalizer.configure(enabled: false, targetLufs: -14);
    expect(changes, [LoudnessChange.measured, LoudnessChange.settings]);
    await normalizer.close();
  });
}
