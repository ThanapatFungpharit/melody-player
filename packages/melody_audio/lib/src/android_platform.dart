import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Android services implemented by the plugin's Kotlin side: the
/// directories Melody needs from the OS and opening the Music folder.
class AndroidPlatform {
  AndroidPlatform._();

  static const MethodChannel _channel = MethodChannel(
    "com.melodyplayer.melody_audio/native",
  );

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The read-only directory where Android installed bundled executables
  /// (FFmpeg is packaged as `libffmpeg.so`).
  static Future<String> nativeLibraryDirectory() async {
    if (!_android) {
      throw UnsupportedError("The native library directory is Android-only");
    }
    final path = await _channel.invokeMethod<String>("nativeLibraryDir");
    if (path == null || path.isEmpty) {
      throw StateError("Android did not report its native library directory");
    }
    return path;
  }

  /// Shows `Music/<relativePath>` in the system Files app, or the storage
  /// root when Files cannot open that folder directly. Returns false when
  /// no app can show either.
  static Future<bool> openMusicFolder(String relativePath) async {
    if (!_android) {
      throw UnsupportedError("Opening the Music folder is Android-only");
    }
    return await _channel.invokeMethod<bool>("openMusicFolder", {
          "relativePath": relativePath,
        }) ??
        false;
  }

  /// The public Music folder root, normally `/storage/emulated/0/Music`.
  static Future<String> publicMusicDirectory() async {
    if (!_android) {
      throw UnsupportedError("The public Music folder is Android-only");
    }
    final path = await _channel.invokeMethod<String>("publicMusicDir");
    if (path == null || path.isEmpty) {
      throw StateError("Android did not report its Music folder");
    }
    return path;
  }
}
