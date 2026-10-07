import "dart:io";

import "package:melody_audio/melody_audio.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

/// Where Melody keeps its data, music, and bundled media tools.
class AppPaths {
  const AppPaths({
    required this.dataDirectory,
    required this.defaultMusicDirectory,
    this.publicMusicDirectory,
    this.ffmpegLocation,
  });

  /// Private per-user application data (databases, caches, cookies).
  final String dataDirectory;

  /// The default folder for downloaded audio.
  final String defaultMusicDirectory;

  /// Android only: the public folder completed tracks are published to.
  final String? publicMusicDirectory;

  /// yt-dlp's `ffmpeg_location`: a directory of FFmpeg/FFprobe on desktop,
  /// or the exact `libffmpeg.so` path on Android.
  final String? ffmpegLocation;

  String get stateDatabase => p.join(dataDirectory, "state.db");
  String get libraryDatabase => p.join(dataDirectory, "library.db");
  String get legacyState => p.join(dataDirectory, "state.json");
  String get legacyLibrary => p.join(dataDirectory, "library.mmdb");
  String get thumbnails => p.join(dataDirectory, "thumbnails");
  String get ytDlpRuntime => p.join(dataDirectory, "yt-dlp-runtime");
  String get ytMusicRuntime => p.join(dataDirectory, "ytmusicapi-runtime");

  /// yt-dlp's `cachedir` (YouTube player code and signature data). Without
  /// it yt-dlp writes to `~/.cache/yt-dlp`, outside Melody's data.
  String get ytDlpCache => p.join(dataDirectory, "yt-dlp-cache");

  /// Saved lyrics, so they show without a connection.
  String get lyrics => p.join(dataDirectory, "lyrics");
  String get cookieFile => p.join(dataDirectory, "cookies.txt");

  static Future<AppPaths> resolve() async {
    final environment = Platform.environment;
    final home = environment["HOME"] ?? environment["USERPROFILE"] ?? ".";
    if (Platform.isAndroid) {
      // Earlier releases stored data in "<application support>/data"; keep
      // it so installs upgrade in place.
      final support = await getApplicationSupportDirectory();
      final data = p.join(support.path, "data");
      await Directory(data).create(recursive: true);
      return AppPaths(
        dataDirectory: data,
        defaultMusicDirectory: p.join(data, "Music"),
        publicMusicDirectory: p.join(
          await AndroidPlatform.publicMusicDirectory(),
          "Melody",
        ),
        ffmpegLocation: p.join(
          await AndroidPlatform.nativeLibraryDirectory(),
          "libffmpeg.so",
        ),
      );
    }
    // Development and tests: keep all state and music in one throwaway folder.
    final isolated = environment["MELODY_DATA_DIR"];
    if (isolated != null && isolated.isNotEmpty) {
      await Directory(isolated).create(recursive: true);
      return AppPaths(
        dataDirectory: isolated,
        defaultMusicDirectory: p.join(isolated, "Music"),
        ffmpegLocation: _desktopFfmpegDirectory(),
      );
    }
    final String data;
    if (Platform.isWindows) {
      final local = environment["LOCALAPPDATA"];
      data = p.join(local ?? p.join(home, "AppData", "Local"), "MelodyPlayer");
    } else if (Platform.isMacOS) {
      data = p.join(home, "Library", "Application Support", "MelodyPlayer");
    } else {
      final xdg = environment["XDG_DATA_HOME"];
      data = p.join(xdg ?? p.join(home, ".local", "share"), "MelodyPlayer");
    }
    await Directory(data).create(recursive: true);
    return AppPaths(
      dataDirectory: data,
      defaultMusicDirectory: p.join(home, "Music", "Melody"),
      ffmpegLocation: _desktopFfmpegDirectory(),
    );
  }

  static String? _desktopFfmpegDirectory() {
    final override = Platform.environment["MELODY_FFMPEG_DIR"];
    if (override != null && override.isNotEmpty) return override;
    final executable = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? "ffmpeg.exe" : "ffmpeg";
    final candidates = [
      p.join(executable, "ffmpeg"),
      // macOS app bundles keep resources beside the executable's folder.
      p.normalize(p.join(executable, "..", "Resources", "ffmpeg")),
    ];
    for (final directory in candidates) {
      if (File(p.join(directory, name)).existsSync()) return directory;
    }
    return null;
  }
}
