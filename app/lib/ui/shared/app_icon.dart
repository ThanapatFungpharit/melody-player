import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "theme.dart";

/// Keeps Android's launcher icon for Melody in the saved accent color.
///
/// Android switches the launcher entry to the matching prebuilt icon the next
/// time Melody leaves the screen (`LauncherIcon` in the Android runner). Other
/// platforms keep the bundled violet icon.
abstract final class AppIcon {
  static const _channel = MethodChannel("melody/app_icon");

  static String? _applied;
  static Future<void> _pending = Future.value();

  static void apply(String accent) {
    // The theme draws an unknown saved accent (a hand-edited or newer
    // settings file) as violet; the icon follows it. Android has no launcher
    // entry for such an accent and would keep the previous one.
    if (!themePalettes.containsKey(accent)) accent = "violet";
    if (accent == _applied || !_supported) return;
    _applied = accent;
    _pending = _pending.then((_) => _send(accent));
  }

  static bool get _supported =>
      !kIsWeb &&
      Platform.isAndroid &&
      !Platform.environment.containsKey("FLUTTER_TEST");

  static Future<void> _send(String accent) async {
    try {
      await _channel.invokeMethod<void>("setAccent", accent);
    } on MissingPluginException {
      // A runner without the channel keeps its bundled icon.
    } catch (error) {
      // Later accents still get their turn: a failure must not break the
      // [_pending] chain.
      debugPrint("Could not update the app icon: $error");
    }
  }
}
