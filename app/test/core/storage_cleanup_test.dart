import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/storage.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-storage");
  });

  tearDown(() => root.delete(recursive: true));

  File file(String name, {int size = 1, Duration age = Duration.zero}) {
    final file = File(p.join(root.path, name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(size, 0));
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  List<String> names() => [
    for (final entity in root.listSync(recursive: true))
      if (entity is File) p.relative(entity.path, from: root.path),
  ]..sort();

  group("removeStaleTemporaries", () {
    test("removes only abandoned atomic temporaries", () async {
      const old = Duration(hours: 2);
      file(".state.json.0123456789abcdef.tmp", age: old);
      file(".melody-import-0123456789abcdef.tmp", age: old);
      // A write in progress keeps its file fresh.
      file(".cookies.txt.fedcba9876543210.tmp");
      // Not Melody's naming: never touched, however old.
      file("notes.tmp", age: old);
      file(".hidden.tmp", age: old);
      file("Song.mp3", age: old);

      expect(await removeStaleTemporaries(root.path), 2);
      expect(names(), [
        ".cookies.txt.fedcba9876543210.tmp",
        ".hidden.tmp",
        "Song.mp3",
        "notes.tmp",
      ]);
    });

    test("an interrupted atomic write is recognised", () async {
      final target = p.join(root.path, "receipt.json");
      await atomicWrite(target, [1, 2, 3]);
      // atomicWrite cleans up after itself; a crash would leave this name.
      final leftover = file(
        ".receipt.json.0011223344556677.tmp",
        age: const Duration(hours: 3),
      );
      expect(isAtomicTemporary(p.basename(leftover.path)), isTrue);
      expect(await removeStaleTemporaries(root.path), 1);
      expect(names(), ["receipt.json"]);
    });

    test("a missing folder is not an error", () async {
      expect(await removeStaleTemporaries(p.join(root.path, "absent")), 0);
    });
  });

  group("pruneCacheDirectory", () {
    test("expires old entries and abandoned temporaries", () async {
      file("youtube-nsig/old.json", age: const Duration(days: 40));
      file("youtube-nsig/new.json", age: const Duration(days: 2));
      file(
        "challenge-solver/player.json.abc.tmp",
        age: const Duration(hours: 2),
      );
      file("challenge-solver/writing.json.def.tmp");

      final removed = await pruneCacheDirectory(
        root.path,
        maxAge: const Duration(days: 30),
        maxBytes: 1 << 20,
      );
      expect(removed, 2);
      expect(names(), [
        p.join("challenge-solver", "writing.json.def.tmp"),
        p.join("youtube-nsig", "new.json"),
      ]);
    });

    test("removes the least recently modified beyond the size limit", () async {
      file("a.json", size: 400, age: const Duration(days: 3));
      file("b.json", size: 400, age: const Duration(days: 2));
      file("c.json", size: 400, age: const Duration(days: 1));

      final removed = await pruneCacheDirectory(
        root.path,
        maxAge: const Duration(days: 30),
        maxBytes: 900,
      );
      expect(removed, 1);
      expect(names(), ["b.json", "c.json"]);
    });

    test("repeated pruning keeps the folder bounded", () async {
      for (var day = 0; day < 60; day++) {
        // One new player release a day, as yt-dlp would cache it.
        file(
          "challenge-solver/player-$day.json",
          size: 100,
          age: Duration(days: 60 - day),
        );
        await pruneCacheDirectory(
          root.path,
          maxAge: const Duration(days: 30),
          maxBytes: 2000,
        );
      }
      final total = [
        for (final entity in root.listSync(recursive: true))
          if (entity is File) entity.lengthSync(),
      ].fold<int>(0, (sum, size) => sum + size);
      expect(total, lessThanOrEqualTo(2000));
    });

    test("a missing folder is not an error", () async {
      expect(
        await pruneCacheDirectory(
          p.join(root.path, "absent"),
          maxAge: const Duration(days: 1),
          maxBytes: 0,
        ),
        0,
      );
    });
  });
}
