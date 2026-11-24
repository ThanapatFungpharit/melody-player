import "dart:async";
import "dart:ffi";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Whether the system is saving power: Battery Saver on Android, the
/// power-saver profile on Linux, Energy Saver on Windows, Low Power Mode on
/// macOS. Platforms that cannot tell report false.
///
/// Android announces changes as they happen. Elsewhere nothing announces
/// them without a daemon connection or polling, so [refresh] reads the
/// state again when the app returns to the screen, at most once a
/// [minimumRecheck].
class SystemPowerSaver {
  SystemPowerSaver({
    Future<bool> Function()? read,
    this.minimumRecheck = const Duration(seconds: 30),
  }) : _read = read ?? _platformRead;

  static const _channel = MethodChannel("melody/power");

  final Future<bool> Function() _read;
  final Duration minimumRecheck;

  /// The last state read; listeners hear each change.
  final ValueNotifier<bool> saving = ValueNotifier(false);
  final Stopwatch _sinceRead = Stopwatch();
  bool _reading = false;
  bool _listening = false;

  /// Reads the state now and, on Android, follows its changes.
  Future<void> start() async {
    if (Platform.isAndroid && !_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == "changed" && call.arguments is bool) {
          saving.value = call.arguments as bool;
        }
      });
    }
    await _update();
  }

  /// Reads the state again unless it was read within [minimumRecheck].
  Future<void> refresh() async {
    if (_sinceRead.isRunning && _sinceRead.elapsed < minimumRecheck) return;
    await _update();
  }

  Future<void> _update() async {
    if (_reading) return;
    _reading = true;
    try {
      saving.value = await _read();
    } on Object catch (error) {
      // Unknown counts as not saving: Melody then works as it always has.
      debugPrint("Could not read the system power mode: $error");
    } finally {
      _reading = false;
      _sinceRead
        ..reset()
        ..start();
    }
  }

  void dispose() {
    if (_listening) _channel.setMethodCallHandler(null);
    saving.dispose();
  }

  static Future<bool> _platformRead() async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>("isPowerSaveMode") ?? false;
    }
    if (Platform.isLinux) return linuxPowerSaving();
    if (Platform.isWindows) return _windowsEnergySaver();
    if (Platform.isMacOS) return _macLowPowerMode();
    return false;
  }

  /// The firmware's platform profile, which power-profiles-daemon and
  /// tuned-ppd set to `low-power` for the power-saver profile; failing that,
  /// the daemon's own answer over D-Bus.
  @visibleForTesting
  static Future<bool> linuxPowerSaving({
    String profileFile = "/sys/firmware/acpi/platform_profile",
    Future<ProcessResult> Function(String, List<String>) run = Process.run,
  }) async {
    try {
      final profile = (await File(profileFile).readAsString()).trim();
      return profile == "low-power" || profile == "quiet";
    } on FileSystemException {
      // No ACPI platform profile on this machine.
    }
    for (final service in const [
      "org.freedesktop.UPower.PowerProfiles",
      "net.hadess.PowerProfiles",
    ]) {
      final path = "/${service.replaceAll(".", "/")}";
      try {
        final result = await run("gdbus", [
          "call",
          "--system",
          "--dest",
          service,
          "--object-path",
          path,
          "--method",
          "org.freedesktop.DBus.Properties.Get",
          service,
          "ActiveProfile",
        ]);
        if (result.exitCode == 0) {
          return "${result.stdout}".contains("power-saver");
        }
      } on ProcessException {
        return false;
      }
    }
    return false;
  }

  /// `SYSTEM_POWER_STATUS.SystemStatusFlag` is 1 while Energy Saver (Battery
  /// Saver before Windows 11) is on.
  static bool _windowsEnergySaver() {
    final kernel = DynamicLibrary.open("kernel32.dll");
    final getStatus = kernel
        .lookupFunction<
          Int32 Function(Pointer<Uint8>),
          int Function(Pointer<Uint8>)
        >("GetSystemPowerStatus");
    // ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag, then
    // two DWORDs: 12 bytes.
    final status = _calloc(12);
    try {
      if (getStatus(status) == 0) return false;
      return status[3] == 1;
    } finally {
      _free(status);
    }
  }

  /// `pmset` names Low Power Mode `lowpowermode` (`powermode` on newer
  /// releases, where 1 is low power).
  static Future<bool> _macLowPowerMode() async {
    final result = await Process.run("pmset", ["-g"]);
    if (result.exitCode != 0) return false;
    return RegExp(
      r"^\s*(lowpowermode|powermode)\s+1\s*$",
      multiLine: true,
    ).hasMatch("${result.stdout}");
  }
}

final _msvcrt = Platform.isWindows ? DynamicLibrary.open("msvcrt.dll") : null;

Pointer<Uint8> _calloc(int bytes) =>
    _msvcrt!.lookupFunction<
      Pointer<Uint8> Function(IntPtr, IntPtr),
      Pointer<Uint8> Function(int, int)
    >("calloc")(1, bytes);

void _free(Pointer<Uint8> pointer) =>
    _msvcrt!.lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >("free")(pointer);
