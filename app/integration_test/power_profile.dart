/// Measures what the running desktop app costs in the states it spends long
/// stretches in: idle and playing, on screen and hidden, with Low Power Mode
/// off and on. It is the app itself with a driver around it, not a test:
/// test bindings draw and talk to the tool on their own, which would swamp
/// what is measured. It plays a local file through the real decoder,
/// samples the process's CPU time, context switches (wakeups), write
/// syscalls, and rendered frames, prints one table, and exits. Linux only,
/// since it reads /proc.
///
///   flutter build linux --profile -t integration_test/power_profile.dart
///   MELODY_DATA_DIR=EMPTY_FOLDER \
///   MELODY_FFMPEG_DIR=app/media/linux/x86_64 \
///   MELODY_POWER_AUDIO=path/to/long.mp3 \
///   MELODY_POWER_SECONDS=30 (optional) \
///   build/linux/x64/profile/bundle/melody
///
/// Nothing here asserts a budget, since timings depend on the machine.
/// Compare rows against each other, and against a build of an earlier commit.
library;

import "dart:async";
import "dart:io";

import "package:flutter/scheduler.dart";
import "package:flutter/widgets.dart";
import "package:melody/application/models.dart";
import "package:melody/main.dart" as melody;
import "package:melody/ui/app_state.dart";
import "package:melody/ui/desktop/shell.dart";

final _environment = Platform.environment;

Future<void> main() async {
  final data = _environment["MELODY_DATA_DIR"];
  final audio = _environment["MELODY_POWER_AUDIO"];
  if (data == null || audio == null) {
    stderr.writeln(
      "Set MELODY_DATA_DIR (an empty folder) and MELODY_POWER_AUDIO",
    );
    exit(2);
  }
  final seconds =
      int.tryParse(_environment["MELODY_POWER_SECONDS"] ?? "") ?? 30;
  melody.main();

  var frames = 0;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    frames += timings.length;
  });

  final app = await _waitFor(_findApp, "the app shell");
  final trackId = await app.services.library.importLocalFile(audio);
  app.touchLibrary();
  if (!app.playback.muted) app.playback.toggleMute();
  // The launch passes (artwork, loudness) start within ten seconds.
  await _idle(const Duration(seconds: 20));

  final rows = <_Row>[];
  Future<void> measure(String name) async {
    // Let the change that started this state settle first.
    await _idle(const Duration(seconds: 5));
    final from = _Sample.read(frames);
    await _idle(Duration(seconds: seconds));
    rows.add(_Row(name, from, _Sample.read(frames)));
    stdout.writeln("measured $name");
  }

  Future<void> profile(String mode) async {
    await measure("$mode idle, on screen");
    _setVisible(false);
    await measure("$mode idle, hidden");
    _setVisible(true);

    app.playback.playNow([trackId]);
    await _waitFor(() => app.positionAdvancing ? true : null, "playback");
    await measure("$mode playing, on screen");
    _setVisible(false);
    await measure("$mode playing, hidden");
    _setVisible(true);
    app.playback.toggle();
    await _waitFor(() => app.playback.playing ? null : true, "pause");
  }

  await profile("normal");
  app.settingsControls.update((next) => next.lowPowerMode = LowPowerSetting.on);
  await profile("low power");

  stdout.writeln(
    "\n${_Row.header}\n${rows.map((row) => row.format()).join("\n")}",
  );
  app.close();
  exit(0);
}

MelodyApp? _findApp() {
  MelodyApp? found;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is DesktopShell) {
      found = widget.app;
    } else if (found == null) {
      element.visitChildren(visit);
    }
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<void> _idle(Duration duration) => Future<void>.delayed(duration);

Future<T> _waitFor<T extends Object>(T? Function() value, String what) async {
  final deadline = DateTime.now().add(const Duration(minutes: 1));
  while (true) {
    if (value() case final T found) return found;
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln("Timed out waiting for $what");
      exit(1);
    }
    await _idle(const Duration(milliseconds: 100));
  }
}

/// Moves the app on or off the screen as the platform would report it.
void _setVisible(bool visible) {
  final binding = WidgetsBinding.instance;
  final states = visible
      ? const [AppLifecycleState.inactive, AppLifecycleState.resumed]
      : const [AppLifecycleState.inactive, AppLifecycleState.hidden];
  for (final state in states) {
    if (binding.lifecycleState != state) {
      binding.handleAppLifecycleStateChanged(state);
    }
  }
}

/// One reading of the process's counters.
class _Sample {
  _Sample.read(this.frames)
    : at = DateTime.now(),
      cpuTicks = _cpuTicks(),
      switches = _switches(),
      writes = _io("syscw"),
      writtenBytes = _io("write_bytes");

  final DateTime at;
  final int frames;
  final int cpuTicks;
  final int switches;
  final int writes;
  final int writtenBytes;

  static int _cpuTicks() {
    final stat = File("/proc/self/stat").readAsStringSync();
    // Fields after the command name, which may hold spaces, start at ")".
    final fields = stat.substring(stat.lastIndexOf(")") + 2).split(" ");
    return int.parse(fields[11]) + int.parse(fields[12]);
  }

  /// Voluntary and involuntary switches of every thread: each is a wakeup.
  static int _switches() {
    var total = 0;
    for (final task in Directory("/proc/self/task").listSync()) {
      try {
        for (final line in File("${task.path}/status").readAsLinesSync()) {
          if (line.contains("ctxt_switches:")) {
            total += int.parse(line.split(":").last.trim());
          }
        }
      } on FileSystemException {
        // The thread ended between listing and reading.
      }
    }
    return total;
  }

  static int _io(String key) {
    for (final line in File("/proc/self/io").readAsLinesSync()) {
      if (line.startsWith("$key:")) return int.parse(line.split(":")[1].trim());
    }
    return 0;
  }
}

class _Row {
  _Row(this.name, _Sample from, _Sample to)
    : seconds = to.at.difference(from.at).inMilliseconds / 1000,
      cpuMs = (to.cpuTicks - from.cpuTicks) * 10,
      switches = to.switches - from.switches,
      writes = to.writes - from.writes,
      writtenKb = (to.writtenBytes - from.writtenBytes) / 1024,
      frames = to.frames - from.frames;

  final String name;
  final double seconds;
  final int cpuMs;
  final int switches;
  final int writes;
  final double writtenKb;
  final int frames;

  static final header =
      "${"state".padRight(30)}${"CPU".padLeft(8)}"
      "${["wakes/s", "writes/s", "KiB/s", "frames/s"].map((h) => h.padLeft(10)).join()}";

  String format() {
    String rate(num value) => (value / seconds).toStringAsFixed(2).padLeft(10);
    return "${name.padRight(30)}"
        "${(cpuMs / seconds / 10).toStringAsFixed(2).padLeft(7)}%"
        "${rate(switches)}${rate(writes)}${rate(writtenKb)}${rate(frames)}";
  }
}
