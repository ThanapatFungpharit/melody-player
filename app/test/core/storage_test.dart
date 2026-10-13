import "../support/temp.dart";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await createTestDirectory("melody-storage");
  });

  tearDown(() => root.delete(recursive: true));

  int rows(String path) {
    final store = SqliteStore.open(path);
    try {
      return store.query("SELECT count(*) AS n FROM t").first["n"] as int;
    } finally {
      store.close();
    }
  }

  group("background flushing", () {
    test("commits stay atomic and survive reopening", () async {
      final path = p.join(root.path, "flush.db");
      final store = SqliteStore.open(path, syncInBackground: true);
      store.transaction((db) => db.execute("CREATE TABLE t (v INTEGER)"));
      for (var i = 0; i < 50; i++) {
        store.transaction((db) => db.execute("INSERT INTO t VALUES (?)", [i]));
      }
      expect(
        () => store.transaction((db) {
          db.execute("INSERT INTO t VALUES (-1)");
          throw StateError("abandoned");
        }),
        throwsStateError,
      );
      await store.flushed();
      await store.close();
      expect(rows(path), 50);
    });

    test("bursts of commits are flushed once the isolate is ready", () async {
      final path = p.join(root.path, "burst.db");
      final store = SqliteStore.open(path, syncInBackground: true);
      // Commits made before the isolate reported ready are flushed too.
      store.transaction((db) => db.execute("CREATE TABLE t (v INTEGER)"));
      await store.flushed();
      for (var i = 0; i < 200; i++) {
        store.transaction((db) => db.execute("INSERT INTO t VALUES (?)", [i]));
      }
      await store.flushed().timeout(const Duration(seconds: 10));
      await store.close();
      expect(rows(path), 200);
    });

    test("close waits for the isolate and releases every file", () async {
      final path = p.join(root.path, "nested", "close.db");
      final store = SqliteStore.open(path, syncInBackground: true);
      store.transaction((db) => db.execute("CREATE TABLE t (v INTEGER)"));
      await store.close();
      expect(
        () => store.transaction((db) => db.execute("SELECT 1")),
        throwsA(isA<DatabaseFailure>()),
      );
      await store.flushed();
      // Windows refuses to delete a file that is still open.
      await Directory(p.dirname(path)).delete(recursive: true);
      // Closing twice is harmless.
      await store.close();
    });

    test("a commit never waits for the disk once flushing is ready", () async {
      final path = p.join(root.path, "latency.db");
      final store = SqliteStore.open(path, syncInBackground: true);
      store.transaction((db) => db.execute("CREATE TABLE t (v TEXT)"));
      await store.flushed();
      // Give the start-up callback a turn to switch the commit mode.
      await Future<void>.delayed(Duration.zero);
      final mode = store.query("PRAGMA synchronous").first.values.first;
      // 1 is NORMAL: no flush inside COMMIT; FULL (2) would wait for it.
      expect(mode, 1);
      await store.close();
    });

    test("stores without it keep FULL commits", () async {
      final store = SqliteStore.open(p.join(root.path, "full.db"));
      expect(store.query("PRAGMA synchronous").first.values.first, 2);
      await store.flushed();
      await store.close();
    });

    test("the library flushes in the background", () async {
      final manager = MusicManager.open(
        p.join(root.path, "library.db"),
        p.join(root.path, "Music"),
        syncInBackground: true,
      );
      final id = manager.createPlaylist("Road trip");
      manager.renamePlaylist(id, "Road trip 2");
      await manager.flushed();
      await manager.close();
      final reopened = MusicManager.open(
        p.join(root.path, "library.db"),
        p.join(root.path, "Music"),
      );
      expect(reopened.getPlaylist(id).name, "Road trip 2");
      await reopened.close();
    });
  });

  group("existingFiles", () {
    test("reports regular files, optionally only non-empty ones", () async {
      final full = File(p.join(root.path, "a.mp3"))..writeAsBytesSync([1]);
      final empty = File(p.join(root.path, "b.mp3"))..createSync();
      final folder = Directory(p.join(root.path, "c.mp3"))..createSync();
      final missing = p.join(root.path, "d.mp3");
      final paths = [full.path, empty.path, folder.path, missing, full.path];
      expect(await existingFiles(paths), {full.path, empty.path});
      expect(await existingFiles(paths, nonEmpty: true), {full.path});
      expect(await existingFiles(const []), isEmpty);
    });
  });

  test("availablePath avoids reserved names differing only in case", () {
    final directory = Directory.systemTemp.createTempSync("melody_names");
    addTearDown(() => directory.deleteSync(recursive: true));
    final reserved = {p.join(directory.path, "song.mp3")};
    final path = availablePath(directory.path, "Song.mp3", reserved: reserved);
    final caseInsensitive = Platform.isWindows || Platform.isMacOS;
    expect(p.basename(path), caseInsensitive ? "Song (2).mp3" : "Song.mp3");
  });
}
