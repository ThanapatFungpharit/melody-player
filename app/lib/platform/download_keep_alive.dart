import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Tells Android how many downloads are running, so it keeps Melody alive for
/// them while it is off screen. Other platforms leave a background app running.
abstract final class DownloadKeepAlive {
  static const _channel = MethodChannel("melody/downloads");

  static int _reported = 0;
  static Future<void> _pending = Future.value();

  static void report(int active) {
    if (active == _reported || !Platform.isAndroid) return;
    _reported = active;
    _pending = _pending.then((_) => _send(active));
  }

  static Future<void> _send(int active) async {
    try {
      await _channel.invokeMethod<bool>("setActive", active);
    } on Object catch (error) {
      // The downloads themselves carry on for as long as Android allows.
      debugPrint("Could not report active downloads: $error");
    }
  }
}
