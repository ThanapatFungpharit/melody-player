/// Brings data written by earlier releases into the current layout
/// ([AppPaths]). Every name an earlier release used lives here and nowhere
/// else. Each step is idempotent and best effort: a step that fails leaves
/// the old data where it was and runs again at the next launch.
library;

import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/downloader/downloader.dart" show removeAbandonedStagingIn;
import "../core/downloader/receipts.dart";
import "../core/library/manager.dart";
import "../core/storage.dart";
import "../platform/paths.dart";
import "../worker/transport.dart" show ytDlpPackage, ytMusicPackage;
import "store.dart";

/// Names of files and folders in earlier layouts.
class LegacyLayout {
  const LegacyLayout(this.paths);

  final AppPaths paths;

  String _data(String name) => p.join(paths.dataDirectory, name);

  /// Pre-SQLite settings, imported once by [ApplicationStore.open].
  String get stateJson => _data("state.json");

  /// Pre-SQLite library, imported once by [MusicManager.open].
  String get libraryMmdb => _data("library.mmdb");

  /// Android: the private music folder that releases before the public
  /// `Music` folder downloaded into.
  String get privateMusic => _data("Music");

  /// Staging and receipts outside `downloads/`.
  String get downloadStaging => _data("download-staging");

  /// The prefix of download staging folders and receipts that earlier
  /// releases kept in the music folder itself.
  static const downloadPrefix = ".melody-download-";

  /// Folders that moved, by their new location. Each holds only data
  /// Melody can rebuild or fetch again.
  Map<String, String> get movedFolders => {
    _data("thumbnails"): paths.artworkCache,
    _data("yt-dlp-cache"): paths.ytDlpCache,
    _data("yt-dlp-runtime"): paths.runtime(ytDlpPackage),
    _data("ytmusicapi-runtime"): paths.runtime(ytMusicPackage),
  };

  /// Files no release reads any more.
  List<String> get obsoleteFiles => [
    // Files that could not take lyrics; the embedder simply tries them once
    // more and records them in the state database.
    p.join(paths.lyrics, "not_embedded.json"),
  ];

  /// Folders no release uses any more, with everything in them.
  List<String> get obsoleteFolders => [
    // Media-session artwork, now in the cache folder.
    p.join(Directory.systemTemp.path, "melody-notification-artwork"),
  ];

  /// Copies of [stateJson] and [libraryMmdb] kept after their import.
  List<String> get importedBackups => [
    "$stateJson.migrated",
    "$libraryMmdb.migrated",
  ];
}

/// Moves folders of earlier layouts to their current place. Runs before
/// anything opens them (the worker uses the runtime folders).
Future<void> relocateLegacyFolders(LegacyLayout legacy) async {
  for (final MapEntry(key: from, value: to) in legacy.movedFolders.entries) {
    try {
      if (!await Directory(from).exists()) continue;
      if (await Directory(to).exists()) {
        // A launch already started over in the new place (the move failed
        // then, typically because another Melody held a file open). What
        // is left is disposable.
        await Directory(from).delete(recursive: true);
      } else {
        await Directory(p.dirname(to)).create(recursive: true);
        await Directory(from).rename(to);
      }
    } on FileSystemException catch (error) {
      debugPrint("Could not move $from to $to: $error");
    }
  }
  for (final path in legacy.obsoleteFiles) {
    await deleteQuietly(path);
  }
  for (final path in legacy.obsoleteFolders) {
    await _deleteFolder(path);
  }
}

Future<void> _deleteFolder(String path) async {
  try {
    await Directory(path).delete(recursive: true);
  } on PathNotFoundException {
    // Already gone.
  } on FileSystemException catch (error) {
    debugPrint("Could not remove $path: $error");
  }
}

/// Upgrades state that needs the stores: the cookie setting, download
/// handoffs kept beside the music, and Android's private music folder.
/// Runs before downloads open. [storesExisted] says whether both databases
/// were there before this launch opened them, so a pre-SQLite import is at
/// least one launch old and its backups can go.
Future<void> upgradeLegacyState(
  LegacyLayout legacy,
  ApplicationStore store,
  MusicManager manager, {
  required bool storesExisted,
}) async {
  await _dropCookieSetting(legacy.paths, store);
  await _moveOffPrivateStorage(legacy, store, manager);
  for (final folder in {manager.musicFolder, legacy.downloadStaging}) {
    await _adoptReceipts(folder, legacy.paths.downloadReceipts);
    await removeAbandonedStagingIn(folder, prefix: LegacyLayout.downloadPrefix);
  }
  // Everything left in the old staging folder is Melody's and unused, unless
  // a download of an older Melody that is still running holds its staging.
  if (!await _hasStaging(legacy.downloadStaging)) {
    await _deleteFolder(legacy.downloadStaging);
  }
  if (storesExisted) {
    for (final path in legacy.importedBackups) {
      await deleteQuietly(path);
    }
  }
}

Future<bool> _hasStaging(String folder) async {
  try {
    return await Directory(folder)
        .list(followLinks: false)
        .any(
          (entity) =>
              entity is Directory &&
              p.basename(entity.path).startsWith(LegacyLayout.downloadPrefix),
        );
  } on FileSystemException {
    return false;
  }
}

/// Earlier releases saved the cookie file's path in the settings; the file
/// itself was always `cookies.txt` in the data folder. Its presence now is
/// the setting. An empty path meant cookies were removed.
Future<void> _dropCookieSetting(AppPaths paths, ApplicationStore store) async {
  final settings = store.get("settings");
  if (settings is! Map || !settings.containsKey("cookie_file")) return;
  if (settings["cookie_file"] == "") await deleteQuietly(paths.cookieFile);
  try {
    store.set("settings", settings..remove("cookie_file"));
  } on Object catch (error) {
    debugPrint("Could not update the cookie setting: $error");
  }
}

/// Moves the receipts in [folder] (named with [LegacyLayout.downloadPrefix])
/// into [receipts], recording that their files are in [folder].
Future<void> _adoptReceipts(String folder, String receipts) async {
  final List<File> found;
  try {
    if (!await Directory(folder).exists()) return;
    found = [
      await for (final entity in Directory(folder).list(followLinks: false))
        if (entity is File &&
            p.basename(entity.path).startsWith(LegacyLayout.downloadPrefix) &&
            p.extension(entity.path) == ".json")
          entity,
    ];
  } on FileSystemException catch (error) {
    debugPrint("Could not look for download receipts in $folder: $error");
    return;
  }
  for (final file in found) {
    try {
      final Map<String, Object?> data;
      try {
        data = await readReceiptData(file.path);
      } on FormatException catch (error) {
        // It can vouch for no file, so it goes; the files it names stay.
        debugPrint("Discarding unreadable receipt ${file.path}: $error");
        await deleteQuietly(file.path);
        continue;
      }
      final taskId = data["task_id"] as String;
      final target = receiptPath(receipts, taskId);
      if (!p.equals(p.dirname(target), receipts)) {
        await deleteQuietly(file.path);
        continue;
      }
      data["directory"] ??= p.absolute(folder);
      await atomicWrite(target, utf8.encode(jsonEncode(data)));
      await file.delete();
    } on FileSystemException catch (error) {
      debugPrint("Could not move download receipt ${file.path}: $error");
    }
  }
}

/// Android: earlier releases downloaded into private storage and published
/// copies to Music. Moves the library's private tracks into the public
/// music folder once, makes that the music folder, and removes what is
/// left of the private one. A failure keeps everything where it is, to
/// retry at the next launch.
Future<void> _moveOffPrivateStorage(
  LegacyLayout legacy,
  ApplicationStore store,
  MusicManager manager,
) async {
  final publicRoot = legacy.paths.publicMusicRoot;
  final settings = store.settings;
  if (publicRoot == null ||
      p.isWithin(publicRoot, settings.downloadDirectory)) {
    return;
  }
  final target = legacy.paths.defaultMusicDirectory;
  try {
    final moved = await manager.mutation.run(
      () => manager.moveMusicFolder(target),
    );
    store.saveSettings(settings..downloadDirectory = target);
    debugPrint("Moved $moved track file(s) from private storage to $target");
  } on Object catch (error) {
    debugPrint("Could not move tracks out of private storage: $error");
    return;
  }
  try {
    await Directory(legacy.privateMusic).delete(recursive: true);
  } on PathNotFoundException {
    // Nothing was ever downloaded privately.
  } on FileSystemException catch (error) {
    debugPrint("Could not remove the old private music folder: $error");
  }
}
