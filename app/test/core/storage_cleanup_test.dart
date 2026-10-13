import "../support/temp.dart";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/storage.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await createTestDirectory("melody-storage");
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
      file(".melody-tmp-0123456789abcdef.tmp", age: old);
      file(".melody-tmp-0123456789abcdef.mp3", age: old);
      // Left by the Python releases.
      file(".state.json.k2j4_x9a.tmp", age: old);
      file(".melody-import-ab3_9zq0.tmp", age: old);
      // A write in progress keeps its file fresh.
      file(".melody-tmp-fedcba9876543210.json");
      // Not Melody's naming: never touched, however old.
      file("notes.tmp", age: old);
      file(".hidden.tmp", age: old);
      file(".melody-tmp-notes.mp3", age: old);
      file("Song.mp3", age: old);

      expect(await removeStaleTemporaries(root.path), 4);
      expect(names(), [
        ".hidden.tmp",
        ".melody-tmp-fedcba9876543210.json",
        ".melody-tmp-notes.mp3",
        "Song.mp3",
        "notes.tmp",
      ]);
    });

    test("temporary files keep the destination's extension", () {
      final mp3 = temporarySibling(p.join(root.path, "Song.MP3"));
      expect(p.dirname(mp3), root.path);
      expect(p.basename(mp3), matches(r"^\.melody-tmp-[0-9a-f]{16}\.mp3$"));
      expect(temporarySibling(p.join(root.path, "cookies")), endsWith(".tmp"));
      expect(isTemporaryFile(p.basename(mp3)), isTrue);
    });

    test("an interrupted atomic write is recognised", () async {
      final target = p.join(root.path, "receipt.json");
      await atomicWrite(target, [1, 2, 3]);
      // atomicWrite cleans up after itself; a crash would leave this name.
      final leftover = file(
        p.basename(temporarySibling(target)),
        age: const Duration(hours: 3),
      );
      expect(isTemporaryFile(p.basename(leftover.path)), isTrue);
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
