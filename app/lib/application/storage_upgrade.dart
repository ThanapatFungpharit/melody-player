/// Brings data written by earlier releases into the current layout
/// ([AppPaths]). Every name an earlier release used lives here and nowhere
/// else.
///
/// Melody upgrades from 1.0.2, the first release with SQLite and this layout.
/// Each step is idempotent and best effort: a step that fails leaves the old
/// data where it was and runs again at the next launch.
library;

import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/storage.dart";
import "../platform/paths.dart";

/// The data folder is from a release too old to upgrade from directly.
class UnsupportedDataFolder implements Exception {
  const UnsupportedDataFolder();

  String get message =>
      "This library was made by Melody 1.0.1 or earlier, which this version "
      "can't read. Install Melody 1.0.3 and open it once to bring your library "
      "across, then update again. Nothing has been changed.";

  @override
  String toString() => message;
}

/// Refuses a data folder from before 1.0.2, instead of starting an empty
/// library beside it, which 1.0.3 could then no longer import from.
void requireSupportedDataFolder(AppPaths paths) {
  bool exists(String path) => File(path).existsSync();
  if (exists(paths.stateDatabase) || exists(paths.libraryDatabase)) return;
  if (exists(p.join(paths.dataDirectory, "state.json")) ||
      exists(p.join(paths.dataDirectory, "library.mmdb"))) {
    throw const UnsupportedDataFolder();
  }
}

/// Removes what earlier releases wrote and no release reads any more. Runs
/// before anything opens the data folder.
Future<void> removeRetiredFiles(AppPaths paths) async {
  // What the lyrics pass that ran at each launch remembered.
  await deleteQuietly(p.join(paths.cache, "lyrics-embedded.json"));
  await deleteQuietly(p.join(paths.lyrics, "not_embedded.json"));
  // Checksums of downloads not yet registered. A next launch carries those on,
  // and their files, if any, are listed as not in the library.
  try {
    await Directory(
      p.join(paths.dataDirectory, "downloads", "receipts"),
    ).delete(recursive: true);
  } on PathNotFoundException {
    // Already gone.
  } on FileSystemException catch (error) {
    debugPrint("Could not remove the download receipts: $error");
  }
}
