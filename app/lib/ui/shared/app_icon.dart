import "dart:async";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "theme.dart";
import "widgets.dart";

/// Keeps the system's icon for Melody in the saved accent color.
///
/// Android switches the launcher entry to the matching prebuilt icon the next
/// time Melody leaves the screen. Desktop platforms take a [BrandMark] drawn
/// here for the window, taskbar, or dock while Melody runs; installed shortcuts
/// keep the bundled violet icon.
abstract final class AppIcon {
  static const _channel = MethodChannel("melody/app_icon");

  // Windows picks the closest of these for its small and large window icons.
  static const _windowsSizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];
  // Apple's icon grid: an 824-pixel body inside a 1024-pixel canvas.
  static const _macSize = 1024;
  static const _macInset = 100 / 1024;

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
      !Platform.environment.containsKey("FLUTTER_TEST") &&
      (Platform.isAndroid ||
          Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS);

  static Future<void> _send(String accent) async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>("setAccent", accent);
        return;
      }
      final scheme = buildTheme(accent, Brightness.light).colorScheme;
      final images = <int, Uint8List>{};
      if (Platform.isMacOS) {
        images[_macSize] = await _render(scheme, _macSize, inset: _macInset);
      } else if (Platform.isWindows) {
        for (final size in _windowsSizes) {
          images[size] = await _render(scheme, size);
        }
      } else {
        for (final size in const [32, 64, 128, 256]) {
          images[size] = await _render(scheme, size);
        }
      }
      await _channel.invokeMethod<void>("setImages", images);
    } on MissingPluginException {
      // A runner without the channel keeps its bundled icon.
    } catch (error) {
      // Rendering or the platform failed. Later accents still get their turn:
      // a failure must not break the [_pending] chain.
      debugPrint("Could not update the app icon: $error");
    }
  }

  /// [BrandMark] as a PNG, [inset] (a fraction of [size]) from each edge.
  static Future<Uint8List> _render(
    ColorScheme scheme,
    int size, {
    double inset = 0,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final body = size * (1 - 2 * inset);
    final rect = Rect.fromLTWH(size * inset, size * inset, body, body);
    final tile = RRect.fromRectAndRadius(
      rect,
      Radius.circular(body * brandMarkRadius),
    );
    if (inset > 0) {
      // macOS icons sit on a soft shadow inside their margin.
      canvas.drawRRect(
        tile.shift(Offset(0, body * 0.012)),
        Paint()
          ..color = const Color(0x59000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, body * 0.015),
      );
    }
    canvas.drawRRect(
      tile,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: brandMarkColors(scheme),
        ).createShader(rect),
    );
    final glyph = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(Icons.graphic_eq_rounded.codePoint),
        style: TextStyle(
          fontFamily: Icons.graphic_eq_rounded.fontFamily,
          fontSize: body * brandMarkGlyph,
          height: 1,
          color: scheme.onPrimary,
        ),
      ),
    )..layout();
    glyph.paint(
      canvas,
      rect.center - Offset(glyph.width / 2, glyph.height / 2),
    );
    glyph.dispose();
    final picture = recorder.endRecording();
    final ui.Image image;
    try {
      image = await picture.toImage(size, size);
    } finally {
      picture.dispose();
    }
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}
