import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Android-only services implemented by the plugin's Kotlin side.
class MelodyNative {
  MelodyNative._();

  static const MethodChannel _channel = MethodChannel(
    "com.melodyplayer.melody_audio/native",
  );

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Copies a staged track into the public `Music/<relativePath>` collection
  /// and returns the published absolute path.
  static Future<String> publishAudio(
    String source, {
    String relativePath = "Melody",
  }) async {
    if (!_android) {
      throw UnsupportedError("Shared audio publishing is Android-only");
    }
    final result = await _channel.invokeMapMethod<String, Object?>(
      "publishAudio",
      {"source": source, "relativePath": relativePath},
    );
    final path = result?["path"];
    if (path is! String || path.isEmpty) {
      throw StateError("Android did not return the published music path");
    }
    return path;
  }

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
