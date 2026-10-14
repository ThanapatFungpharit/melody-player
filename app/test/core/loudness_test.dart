import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/id3_lyrics.dart";
import "package:melody/core/loudness.dart";
import "package:path/path.dart" as p;

const _summary = """
[Parsed_ebur128_0 @ 000001ab72ecb500] Summary:

  Integrated loudness:
    I:          -9.4 LUFS
    Threshold: -19.6 LUFS

  Loudness range:
    LRA:         5.1 LU
    Threshold: -29.6 LUFS
    LRA low:   -12.9 LUFS
    LRA high:   -7.8 LUFS

  True peak:
    Peak:        0.6 dBFS
[out#0/null @ 000001ab72f0ed80] video:0KiB audio:431KiB subtitle:0KiB
""";

const _silence = """
[Parsed_ebur128_0 @ 0000024e43842fc0] Summary:

  Integrated loudness:
    I:         -70.0 LUFS
    Threshold:   0.0 LUFS

  True peak:
    Peak:       -inf dBFS
""";

LoudnessMeasurement _measured(double lufs, double peak) =>
    LoudnessMeasurement(integratedLufs: lufs, truePeakDb: peak);

/// FFmpeg for the measurement tests: MELODY_FFMPEG_DIR, the staged build
/// copy, or none (those tests are skipped).
String? _ffmpeg() {
  final name = Platform.isWindows ? "ffmpeg.exe" : "ffmpeg";
  final override = Platform.environment["MELODY_FFMPEG_DIR"];
  final staged = Directory(p.join("media")).existsSync()
      ? Directory("media")
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => p.basename(file.path) == name)
            .map((file) => file.path)
            .firstOrNull
      : null;
  for (final candidate in [
    if (override != null && override.isNotEmpty) p.join(override, name),
    ?staged,
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  group("parseEbur128Summary", () {
    test("reads integrated loudness and true peak", () {
      final measurement = parseEbur128Summary(_summary.split("\n"))!;
      expect(measurement.integratedLufs, -9.4);
      expect(measurement.truePeakDb, 0.6);
      expect(measurement.silent, isFalse);
    });

    test("reads digital silence", () {
      final measurement = parseEbur128Summary(_silence.split("\n"))!;
      expect(measurement.silent, isTrue);
      expect(measurement.truePeakDb, double.negativeInfinity);
    });

    test("ignores readings outside the summary", () {
      final lines = [
        "[Parsed_ebur128_0 @ 0] t: 0.4  M: -20.0 S:-120.7     I: -21.0 LUFS",
        "    I:         -5.0 LUFS",
        "    Peak:       1.0 dBFS",
      ];
      expect(parseEbur128Summary(lines), isNull);
    });

    test("needs both values", () {
      final lines = _summary
          .split("\n")
          .where((line) => !line.contains("Peak"));
      expect(parseEbur128Summary(lines), isNull);
      expect(parseEbur128Summary(const []), isNull);
    });
  });

  group("normalizationGainDb", () {
    test("turns a loud track down to the target", () {
      expect(
        normalizationGainDb(_measured(-9, -3), targetLufs: -14),
        closeTo(-5, 1e-9),
      );
    });

    test("leaves a quieter track unchanged: the decoder cannot boost", () {
      expect(normalizationGainDb(_measured(-20, -6), targetLufs: -14), 0);
    });

    test("keeps the true peak under the ceiling", () {
      // At the target already, but peaking above 0 dBTP.
      expect(
        normalizationGainDb(_measured(-14, 0.5), targetLufs: -14),
        closeTo(truePeakCeilingDb - 0.5, 1e-9),
      );
      // The loudness cut already leaves headroom.
      expect(
        normalizationGainDb(_measured(-8, 0.5), targetLufs: -14),
        closeTo(-6, 1e-9),
      );
    });

    test("leaves silence alone and bounds absurd readings", () {
      expect(
        normalizationGainDb(
          _measured(-70, double.negativeInfinity),
          targetLufs: -14,
        ),
        0,
      );
      expect(
        normalizationGainDb(_measured(40, 50), targetLufs: -14),
        minimumGainDb,
      );
    });

    test("raises a quiet track as far as the platform and its peaks allow", () {
      // 6 dB short of the target, with plenty of headroom.
      expect(
        normalizationGainDb(
          _measured(-20, -12),
          targetLufs: -14,
          maxBoostDb: 6,
        ),
        closeTo(6, 1e-9),
      );
      // Further below the target: the platform's limit.
      expect(
        normalizationGainDb(
          _measured(-30, -20),
          targetLufs: -14,
          maxBoostDb: 6,
        ),
        6,
      );
      // A peak at -3 dBTP leaves 2 dB below the ceiling.
      expect(
        normalizationGainDb(_measured(-20, -3), targetLufs: -14, maxBoostDb: 6),
        closeTo(2, 1e-9),
      );
      // Loud tracks are cut as before.
      expect(
        normalizationGainDb(_measured(-9, -3), targetLufs: -14, maxBoostDb: 6),
        closeTo(-5, 1e-9),
      );
    });

    test("a limiter lets a boost take peaks over the ceiling", () {
      // 3 dB short of the target, but peaking at -0.5 dBTP: without a
      // limiter it may only be cut to keep its peaks clear.
      expect(
        normalizationGainDb(
          _measured(-17, -0.5),
          targetLufs: -14,
          maxBoostDb: 12,
        ),
        closeTo(-0.5, 1e-9),
      );
      expect(
        normalizationGainDb(
          _measured(-17, -0.5),
          targetLufs: -14,
          maxBoostDb: 12,
          limiterHeadroomDb: 6,
        ),
        closeTo(3, 1e-9),
      );
      // Far below the target: the limiter's headroom bounds the boost...
      expect(
        normalizationGainDb(
          _measured(-30, -0.5),
          targetLufs: -14,
          maxBoostDb: 12,
          limiterHeadroomDb: 6,
        ),
        closeTo(5.5, 1e-9),
      );
      // ...and with low peaks, the platform's limit does.
      expect(
        normalizationGainDb(
          _measured(-30, -12),
          targetLufs: -14,
          maxBoostDb: 12,
          limiterHeadroomDb: 6,
        ),
        12,
      );
    });

    test("a limiter does not loosen cuts, which play without it", () {
      // At the target, peaking over 0 dBTP: still cut under the ceiling.
      expect(
        normalizationGainDb(
          _measured(-14, 0.5),
          targetLufs: -14,
          maxBoostDb: 12,
          limiterHeadroomDb: 6,
        ),
        closeTo(truePeakCeilingDb - 0.5, 1e-9),
      );
      // Nor does it boost where the engine cannot.
      expect(
        normalizationGainDb(
          _measured(-20, -0.5),
          targetLufs: -14,
          limiterHeadroomDb: 6,
        ),
        closeTo(-0.5, 1e-9),
      );
    });

    test("linear gains", () {
      expect(linearGain(0), 1);
      expect(linearGain(-6.0206), closeTo(0.5, 1e-4));
    });
  });

  test("ffmpegExecutable follows yt-dlp's ffmpeg_location", () {
    final name = Platform.isWindows ? "ffmpeg.exe" : "ffmpeg";
    expect(ffmpegExecutable(null), "ffmpeg");
    expect(
      ffmpegExecutable(p.join("bin", "tools")),
      p.join("bin", "tools", name),
    );
    expect(
      ffmpegExecutable("/lib/arm64/libffmpeg.so"),
      "/lib/arm64/libffmpeg.so",
    );
    expect(ffmpegExecutable(p.join("tools", name)), p.join("tools", name));
  });

  group("ffmpegLoudnessMeter", () {
    final ffmpeg = _ffmpeg();
    final skip = ffmpeg == null ? "FFmpeg is not staged" : null;
    late Directory root;

    setUp(
      () async => root = await Directory.systemTemp.createTemp("melody-lufs"),
    );
    tearDown(() => root.delete(recursive: true));

    Future<String> generate(String name, String source) async {
      final path = p.join(root.path, name);
      final result = await Process.run(ffmpeg!, [
        "-hide_banner", "-v", "error", "-y", "-f", "lavfi", "-i", source, //
        "-t", "4", path,
      ]);
      expect(result.exitCode, 0, reason: "${result.stderr}");
      return path;
    }

    test("measures a tone", () async {
      // A full-scale sine is about -3 LUFS; lavfi's default is -18 dBFS.
      final path = await generate("tone.flac", "sine=frequency=1000");
      final measurement = await ffmpegLoudnessMeter(ffmpeg!)(path);
      expect(measurement.integratedLufs, closeTo(-21, 1));
      expect(measurement.truePeakDb, closeTo(-18, 1));
    }, skip: skip);

    test("reports silence", () async {
      final path = await generate("silence.flac", "anullsrc=r=44100");
      final measurement = await ffmpegLoudnessMeter(ffmpeg!)(path);
      expect(measurement.silent, isTrue);
    }, skip: skip);

    test(
      "the audio hash ignores tags, lyrics included, but not the audio",
      () async {
        final path = await generate("song.mp3", "sine=frequency=440");
        final measured = await ffmpegLoudnessMeter(ffmpeg!)(path);
        final hasher = ffmpegAudioHasher(ffmpeg);
        expect(measured.audioHash, matches(RegExp(r"^[0-9a-f]{64}$")));
        expect(await hasher(path), measured.audioHash);

        // Melody's own lyrics writer, as the desktop lyrics embedder uses it.
        expect(await writeId3Lyrics(path, "[00:01.00]Hello"), isTrue);
        expect(await hasher(path), measured.audioHash);

        // An FFmpeg tag copy, as the worker's `tag` operation makes for other
        // formats.
        final flac = await generate("song.flac", "sine=frequency=440");
        final before = await hasher(flac);
        final tagged = p.join(root.path, "tagged.flac");
        final copy = await Process.run(ffmpeg, [
          "-v", "error", "-i", flac, "-map", "0", "-c", "copy", //
          "-metadata", "lyrics=Hello", tagged,
        ]);
        expect(copy.exitCode, 0, reason: "${copy.stderr}");
        expect(await hasher(tagged), before);

        final other = await generate("other.flac", "sine=frequency=880");
        expect(await hasher(other), isNot(before));
      },
      skip: skip,
    );

    test("rejects a file that is not audio", () async {
      final path = p.join(root.path, "broken.mp3");
      await File(path).writeAsString("not audio at all");
      await expectLater(
        ffmpegLoudnessMeter(ffmpeg!)(path),
        throwsA(isA<LoudnessUnmeasurable>()),
      );
      await expectLater(
        ffmpegAudioHasher(ffmpeg)(path),
        throwsA(isA<LoudnessUnmeasurable>()),
      );
    }, skip: skip);

    test("a missing FFmpeg is not the file's fault", () async {
      final path = p.join(root.path, "any.mp3");
      await expectLater(
        ffmpegLoudnessMeter(p.join(root.path, "no-ffmpeg"))(path),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
