/// Measuring how loud an audio file is (EBU R128 / ITU-R BS.1770) with the
/// bundled FFmpeg, and the playback gain that brings it to a target.
library;

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:path/path.dart" as p;

/// Integrated loudness and true peak of one file.
class LoudnessMeasurement {
  const LoudnessMeasurement({
    required this.integratedLufs,
    required this.truePeakDb,
    this.audioHash,
  });

  /// Integrated loudness in LUFS. FFmpeg reports -70 (the absolute gate)
  /// when nothing is loud enough to measure.
  final double integratedLufs;

  /// True peak in dBTP (dBFS of the 4x oversampled signal); negative
  /// infinity for digital silence.
  final double truePeakDb;

  /// The [AudioHasher] identity of the measured audio, when known.
  final String? audioHash;

  /// Nothing rose above the absolute gate: there is no loudness to match.
  bool get silent => integratedLufs <= silenceLufs;

  static const silenceLufs = -70.0;
}

/// FFmpeg ran but could not measure the file: it is corrupted, has no audio
/// stream, or uses a codec FFmpeg cannot decode. Retrying the same file
/// gives the same answer.
class LoudnessUnmeasurable implements Exception {
  const LoudnessUnmeasurable(this.message);

  final String message;

  @override
  String toString() => "LoudnessUnmeasurable: $message";
}

/// A measurement stopped because its caller cancelled it.
class LoudnessCancelled implements Exception {
  const LoudnessCancelled();
}

/// Measures one file, giving up when [cancel] completes. Throws
/// [LoudnessUnmeasurable] for a file that cannot be measured; any other
/// error (FFmpeg missing, a timeout, cancellation) says nothing about the
/// file.
typedef LoudnessMeter =
    Future<LoudnessMeasurement> Function(String path, {Future<void>? cancel});

/// Identifies the audio of one file regardless of its tags: a hash of the
/// first audio stream's encoded packets. Rewriting tags, lyrics, or cover
/// art keeps it; re-encoding or replacing the audio changes it. Throws as
/// [LoudnessMeter] does.
typedef AudioHasher =
    Future<String> Function(String path, {Future<void>? cancel});

/// The FFmpeg executable for yt-dlp's `ffmpeg_location` (see `AppPaths`): a
/// directory on desktop, the executable itself on Android, or null to look
/// for `ffmpeg` on the PATH as yt-dlp does.
String ffmpegExecutable(String? location) {
  if (location == null || location.isEmpty) return "ffmpeg";
  final name = Platform.isWindows ? "ffmpeg.exe" : "ffmpeg";
  if (p.basename(location).toLowerCase() == name ||
      p.extension(location) == ".so") {
    return location;
  }
  return p.join(location, name);
}

/// A [LoudnessMeter] that runs FFmpeg's `ebur128` filter over the file's
/// first audio stream, and hashes that stream's packets in the same pass
/// (see [AudioHasher]). FFmpeg decodes in its own process, so the app only
/// reads its summary; a run longer than [timeout], or cancelled, is killed.
LoudnessMeter ffmpegLoudnessMeter(
  String executable, {
  Duration timeout = const Duration(minutes: 10),
}) => (path, {cancel}) async {
  final run = await _runFfmpeg(
    executable,
    [
      "-i",
      path,
      "-map",
      "0:a:0",
      // Per-frame readings go to the verbose level, below what is printed.
      "-af",
      "ebur128=peak=true:framelog=verbose",
      "-f",
      "null",
      "-",
      ..._hashOutput,
    ],
    cancel: cancel,
    timeout: timeout,
  );
  final measurement = run.exitCode == 0 ? parseEbur128Summary(run.log) : null;
  if (measurement == null) throw run.failure;
  return LoudnessMeasurement(
    integratedLufs: measurement.integratedLufs,
    truePeakDb: measurement.truePeakDb,
    audioHash: _audioHash(run.output),
  );
};

/// An [AudioHasher] that reads the file's packets with FFmpeg without
/// decoding them, which takes about as long as reading the file.
AudioHasher ffmpegAudioHasher(
  String executable, {
  Duration timeout = const Duration(minutes: 2),
}) => (path, {cancel}) async {
  final run = await _runFfmpeg(
    executable,
    ["-i", path, ..._hashOutput],
    cancel: cancel,
    timeout: timeout,
  );
  final hash = run.exitCode == 0 ? _audioHash(run.output) : null;
  if (hash == null) throw run.failure;
  return hash;
};

/// An output that copies the first audio stream into FFmpeg's `streamhash`
/// muxer, which prints `0,a,SHA256=<hex>` on stdout.
const _hashOutput = [
  "-map",
  "0:a:0",
  "-c",
  "copy",
  "-f",
  "streamhash",
  "-hash",
  "sha256",
  "-",
];

final _streamHash = RegExp(r"SHA256=([0-9a-f]{64})");

String? _audioHash(String output) => _streamHash.firstMatch(output)?[1];

typedef _FfmpegRun = ({int exitCode, String output, List<String> log});

extension on _FfmpegRun {
  /// What FFmpeg said last, as the reason the file cannot be read.
  LoudnessUnmeasurable get failure => LoudnessUnmeasurable(
    this.log
        .lastWhere(
          (line) => line.trim().isNotEmpty,
          orElse: () => "FFmpeg exited with code $exitCode",
        )
        .trim(),
  );
}

/// Runs FFmpeg to completion, keeping its stdout and the tail of its log.
Future<_FfmpegRun> _runFfmpeg(
  String executable,
  List<String> arguments, {
  required Future<void>? cancel,
  required Duration timeout,
}) async {
  final process = await Process.start(executable, [
    "-hide_banner",
    "-nostdin",
    "-nostats",
    ...arguments,
  ]);
  final tail = <String>[];
  final stderrDone = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
        tail.add(line);
        if (tail.length > 40) tail.removeAt(0);
      })
      .asFuture<void>();
  final output = StringBuffer();
  final stdoutDone = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(output.write)
      .asFuture<void>();
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      process.kill();
    }),
  );
  final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    rethrow;
  }
  if (cancelled) throw const LoudnessCancelled();
  await Future.wait([stderrDone, stdoutDone]);
  return (exitCode: exitCode, output: "$output", log: tail);
}

final _integrated = RegExp(r"^\s*I:\s*(-?[\d.]+|-?inf|nan)\s*LUFS");
final _peak = RegExp(r"^\s*Peak:\s*(-?[\d.]+|-?inf|nan)\s*dBFS");

/// Reads the integrated loudness and true peak from the summary FFmpeg's
/// `ebur128` filter logs when it finishes; null when either is missing.
LoudnessMeasurement? parseEbur128Summary(Iterable<String> lines) {
  double? integrated;
  double? peak;
  var inSummary = false;
  for (final line in lines) {
    if (line.contains("Summary:")) {
      inSummary = true;
      integrated = peak = null;
      continue;
    }
    if (!inSummary) continue;
    if (_integrated.firstMatch(line) case final match?) {
      integrated = _decibels(match[1]!);
    } else if (_peak.firstMatch(line) case final match?) {
      peak = _decibels(match[1]!);
    }
  }
  if (integrated == null || peak == null || integrated.isNaN || peak.isNaN) {
    return null;
  }
  return LoudnessMeasurement(
    integratedLufs: max(integrated, LoudnessMeasurement.silenceLufs),
    truePeakDb: peak,
  );
}

double _decibels(String text) => switch (text) {
  "-inf" => double.negativeInfinity,
  "inf" => double.infinity,
  _ => double.tryParse(text) ?? double.nan,
};

/// The highest true peak normalized playback may reach, in dBTP. Lossy
/// decoding and resampling overshoot a little, so a decibel stays free.
const truePeakCeilingDb = -1.0;

/// The deepest cut normalization applies, in dB: a bound on a bogus
/// measurement, far beyond any real master.
const minimumGainDb = -30.0;

/// The playback gain, in dB, that brings [measurement] to [targetLufs].
///
/// A quiet track is raised by at most [maxBoostDb], what the audio engine
/// can add on this platform (0 where it can only attenuate). Either way the
/// gain keeps the true peak at or below [truePeakCeilingDb], so a raised
/// track or a hot master does not clip. A silent track is left alone.
double normalizationGainDb(
  LoudnessMeasurement measurement, {
  required double targetLufs,
  double maxBoostDb = 0,
}) {
  if (measurement.silent) return 0;
  final toTarget = targetLufs - measurement.integratedLufs;
  final peak = measurement.truePeakDb;
  final toCeiling = peak.isFinite ? truePeakCeilingDb - peak : 0.0;
  final ceiling = max(maxBoostDb, 0.0);
  return min(min(toTarget, toCeiling), ceiling).clamp(minimumGainDb, ceiling);
}

/// A gain in dB as the linear volume factor the decoder takes.
double linearGain(double decibels) => pow(10, decibels / 20).toDouble();
