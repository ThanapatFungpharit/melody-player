import "dart:io";

import "package:melody_audio/melody_audio.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

/// Where Melody keeps its data, music, and bundled media tools.
///
/// Everything Melody owns lives under [dataDirectory]:
///
/// ```text
/// library.db              tracks and playlists (MusicManager)
/// state.db                settings, history, queue (ApplicationStore)
/// cookies.txt             uploaded cookies; present means they are used
/// music-move.json         a music folder move in progress (MusicManager)
/// lyrics/                 saved lyrics, one JSON file per song
/// downloads/staging/      one locked folder per running download
/// downloads/receipts/     completed downloads not yet registered
/// runtime/<package>/      ytmusicapi and yt-dlp updates (the worker's)
/// cache/artwork/          artwork copied out of downloaded files
/// cache/yt-dlp/           yt-dlp's player and signature cache
/// cache/notification-artwork/  cropped media-session artwork
/// cache/loudness.json     loudness measurements for normalization
/// ```
///
/// `cache/` is safe to delete while Melody is closed. The music folder
/// holds audio only: Melody writes there through a `.melody-tmp-*` file
/// renamed into place, and never keeps its own state there. Older layouts
/// are upgraded at launch (`application/storage_upgrade.dart`).
class AppPaths {
  const AppPaths({
    required this.dataDirectory,
    required this.defaultMusicDirectory,
    this.publicMusicRoot,
    this.ffmpegLocation,
  });

  /// Private per-user application data. The same folder in every release,
  /// so installs upgrade in place.
  final String dataDirectory;

  /// The default folder for downloaded audio.
  final String defaultMusicDirectory;

  /// Android only: the public Music folder. The music folder must be inside
  /// it.
  final String? publicMusicRoot;

  /// yt-dlp's `ffmpeg_location`: a directory of FFmpeg/FFprobe on desktop,
  /// or the exact `libffmpeg.so` path on Android.
  final String? ffmpegLocation;

  String _data(String relative) => p.join(dataDirectory, relative);

  String get libraryDatabase => _data("library.db");
  String get stateDatabase => _data("state.db");
  String get cookieFile => _data("cookies.txt");
  String get musicMoveJournal => _data("music-move.json");

  /// Saved lyrics, so they show without a connection.
  String get lyrics => _data("lyrics");

  String get downloadStaging => _data(p.join("downloads", "staging"));
  String get downloadReceipts => _data(p.join("downloads", "receipts"));

  /// The worker's folder for runtime updates of a Python [package]
  /// (`yt-dlp`, `ytmusicapi`), separate from the bundled copy.
  String runtime(String package) => _data(p.join("runtime", package));

  /// Disposable data Melody can rebuild or fetch again.
  String get cache => _data("cache");
  String get artworkCache => p.join(cache, "artwork");

  /// yt-dlp's `cachedir`. Without it yt-dlp writes to `~/.cache/yt-dlp`,
  /// outside Melody's data.
  String get ytDlpCache => p.join(cache, "yt-dlp");

  /// Square crops for the system media controls; the 64 most recently used
  /// are kept (melody_audio).
  String get notificationArtworkCache => p.join(cache, "notification-artwork");

  /// Loudness measurements of library tracks (LoudnessNormalizer).
  String get loudnessCache => p.join(cache, "loudness.json");

  /// Folders holding files Melody writes atomically, where a crash can
  /// leave a temporary file behind.
  List<String> get atomicWriteFolders => [
    dataDirectory,
    lyrics,
    downloadReceipts,
    artworkCache,
    cache,
  ];

  static Future<AppPaths> resolve() async {
    final environment = Platform.environment;
    final home = environment["HOME"] ?? environment["USERPROFILE"] ?? ".";
    if (Platform.isAndroid) {
      // Earlier releases stored data in "<application support>/data"; keep
      // it so installs upgrade in place.
      final support = await getApplicationSupportDirectory();
      final data = p.join(support.path, "data");
      await Directory(data).create(recursive: true);
      final music = await AndroidPlatform.publicMusicDirectory();
      return AppPaths(
        dataDirectory: data,
        defaultMusicDirectory: p.join(music, "Melody"),
        publicMusicRoot: music,
        ffmpegLocation: p.join(
          await AndroidPlatform.nativeLibraryDirectory(),
          "libffmpeg.so",
        ),
      );
    }
    // Development and tests: keep all state and music in one throwaway folder.
    final isolated = environment["MELODY_DATA_DIR"];
    if (isolated != null && isolated.isNotEmpty) {
      final data = p.normalize(p.absolute(isolated));
      await Directory(data).create(recursive: true);
      return AppPaths(
        dataDirectory: data,
        defaultMusicDirectory: p.join(data, "Music"),
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
