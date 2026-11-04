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

import "../core/library/manager.dart" show trackIdAsText;
import "../core/storage.dart";
import "../platform/paths.dart";
import "store.dart" show applicationStateSchema;

/// Earlier releases kept the application's state in a database of its own.
String _stateDatabase(AppPaths paths) =>
    p.join(paths.dataDirectory, "state.db");

/// What the merge leaves of it, until a later launch.
String _mergedStateDatabase(AppPaths paths) =>
    "${_stateDatabase(paths)}.merged";

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
  if (exists(_stateDatabase(paths)) || exists(paths.database)) return;
  if (exists(p.join(paths.dataDirectory, "state.json")) ||
      exists(p.join(paths.dataDirectory, "library.mmdb"))) {
    throw const UnsupportedDataFolder();
  }
}

/// Removes what earlier releases wrote and no release reads any more. Runs
/// before anything opens the data folder.
Future<void> removeRetiredFiles(AppPaths paths) async {
  await deleteQuietly(_mergedStateDatabase(paths));
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

/// Moves `state.db` into the library's database, in one transaction: on any
/// failure both files stay as they were, and it throws. Runs before anything opens
/// either. The old file then waits one launch, and if it cannot be renamed the
/// next launch merges again, which keeps what has changed since.
void mergeStateDatabase(AppPaths paths) {
  final earlier = _stateDatabase(paths);
  if (!File(earlier).existsSync()) return;
  final db = SqliteStore.open(paths.database);
  try {
    db.query("ATTACH DATABASE ? AS earlier", [earlier]);
    final check = db.query("PRAGMA earlier.quick_check").first.values.first;
    if (check != "ok") {
      throw FormatException("$earlier is not a valid database: $check");
    }
    final hasTracks = db.hasTable("tracks");
    bool earlierHas(String table) => db.query(
      "SELECT 1 FROM earlier.sqlite_schema WHERE type = 'table' AND name = ?",
      [table],
    ).isNotEmpty;
    final hasState = earlierHas("state");
    final hasDetails = earlierHas("track_details");
    db.transaction((main) {
      main.execute(applicationStateSchema);
      if (hasState) {
        main.execute(
          "INSERT OR IGNORE INTO main.state (key, value) "
          "SELECT key, value FROM earlier.state ORDER BY rowid",
        );
      }
      if (hasDetails) {
        main.execute(
          "INSERT OR IGNORE INTO main.track_details (track_id, value) "
          "SELECT track_id, value FROM earlier.track_details ORDER BY rowid",
        );
      }
      // Details of tracks removed long ago, which nothing could ever read.
      if (hasTracks) {
        main.execute(
          "DELETE FROM main.track_details WHERE track_id NOT IN "
          "(SELECT ${trackIdAsText("id")} FROM main.tracks)",
        );
      }
    });
    db.query("DETACH DATABASE earlier");
  } finally {
    // Closing releases the attached file too, if detaching never happened.
    db.close();
  }
  try {
    File(earlier).renameSync(_mergedStateDatabase(paths));
  } on FileSystemException catch (error) {
    debugPrint("Merged the settings, but could not rename $earlier: $error");
    return;
  }
  for (final sidecar in ["$earlier-wal", "$earlier-shm"]) {
    try {
      File(sidecar).deleteSync();
    } on FileSystemException {
      // Usually not there; closing removes them.
    }
  }
}
