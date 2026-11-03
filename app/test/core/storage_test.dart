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

  group("commits", () {
    test("stay atomic and survive reopening", () async {
      final path = p.join(root.path, "flush.db");
      final store = SqliteStore.open(path);
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
      await store.close();
      expect(rows(path), 50);
    });

    test("closing releases every file and refuses more", () async {
      final path = p.join(root.path, "nested", "close.db");
      final store = SqliteStore.open(path);
      store.transaction((db) => db.execute("CREATE TABLE t (v INTEGER)"));
      await store.close();
      expect(
        () => store.transaction((db) => db.execute("SELECT 1")),
        throwsA(isA<DatabaseFailure>()),
      );
      // Windows refuses to delete a file that is still open.
      await Directory(p.dirname(path)).delete(recursive: true);
      // Closing twice is harmless.
      await store.close();
    });

    test("wait for the disk unless asked not to", () async {
      final full = SqliteStore.open(p.join(root.path, "full.db"));
      // 2 is FULL, 1 is NORMAL.
      expect(full.query("PRAGMA synchronous").first.values.first, 2);
      await full.close();
      final normal = SqliteStore.open(
        p.join(root.path, "normal.db"),
        fullSync: false,
      );
      expect(normal.query("PRAGMA synchronous").first.values.first, 1);
      await normal.close();
    });

    test("of the library survive reopening", () async {
      final manager = MusicManager.open(
        p.join(root.path, "library.db"),
        p.join(root.path, "Music"),
      );
      final id = manager.createPlaylist("Road trip");
      manager.renamePlaylist(id, "Road trip 2");
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
