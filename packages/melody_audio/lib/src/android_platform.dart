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

  /// Whether Melody may see audio files other apps (or an earlier install)
  /// put in the Music folder. Without it Android shows only the files this
  /// install created. Always true off Android.
  static Future<bool> hasAudioAccess() async {
    if (!_android) return true;
    return await _channel.invokeMethod<bool>("hasAudioAccess") ?? false;
  }

  /// Asks for audio access, showing the system prompt unless Android already
  /// decided. Returns whether it is granted. Always true off Android.
  static Future<bool> requestAudioAccess() async {
    if (!_android) return true;
    return await _channel.invokeMethod<bool>("requestAudioAccess") ?? false;
  }

  /// Asks the user to confirm deleting audio files that [paths] name and
  /// Melody did not create, which Android 11+ does not let an app delete
  /// itself. Returns whether the user allowed it; files Android's media
  /// index does not know are skipped, so check which are gone.
  static Future<bool> deleteMediaFiles(List<String> paths) async {
    if (!_android) return false;
    return await _channel.invokeMethod<bool>("deleteMediaFiles", {
          "paths": paths,
        }) ??
        false;
  }
}
