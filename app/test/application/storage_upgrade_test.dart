import "../support/temp.dart";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/storage_upgrade.dart";
import "package:melody/platform/paths.dart";
import "package:melody/ui/startup.dart";
import "package:path/path.dart" as p;
import "package:flutter/material.dart";

void main() {
  late Directory root;
  late AppPaths paths;

  File write(String path, [String contents = "x"]) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  setUp(() async {
    root = await createTestDirectory("melody-upgrade");
    paths = AppPaths(
      dataDirectory: root.path,
      defaultMusicDirectory: p.join(root.path, "Music"),
    );
  });

  tearDown(() => root.delete(recursive: true));

  group("requireSupportedDataFolder", () {
    test("a first launch is fine", () {
      requireSupportedDataFolder(paths);
    });

    test("a folder from 1.0.2 or later is fine", () {
      write(paths.libraryDatabase);
      write(paths.stateDatabase);
      // What the import of older files left, once they were read.
      write(p.join(root.path, "state.json.migrated"));
      write(p.join(root.path, "library.mmdb.migrated"));
      requireSupportedDataFolder(paths);
    });

    for (final name in ["state.json", "library.mmdb"]) {
      test("older data in $name is refused, and left alone", () {
        final old = write(p.join(root.path, name), "old");
        expect(
          () => requireSupportedDataFolder(paths),
          throwsA(isA<UnsupportedDataFolder>()),
        );
        expect(old.readAsStringSync(), "old");
        expect(File(paths.libraryDatabase).existsSync(), isFalse);
        expect(File(paths.stateDatabase).existsSync(), isFalse);
      });
    }

    test("older files beside the databases are not a reason to stop", () {
      write(paths.stateDatabase);
      write(p.join(root.path, "state.json"));
      requireSupportedDataFolder(paths);
    });

    testWidgets("the startup screen says what to do", (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: StartupError(error: UnsupportedDataFolder())),
      );
      expect(find.textContaining("Install Melody 1.0.3"), findsOneWidget);
      expect(find.textContaining("Restart Melody"), findsNothing);
    });
  });

  group("removeRetiredFiles", () {
    test("removes what no release reads, and nothing else", () async {
      final saved = write(p.join(paths.lyrics, "youtube_abc.json"));
      final kept = write(p.join(paths.cache, "loudness.json"));
      final staged = write(p.join(paths.downloadStaging, "job-x", "Song.part"));
      final retired = [
        write(p.join(paths.lyrics, "not_embedded.json"), "{}"),
        write(p.join(paths.cache, "lyrics-embedded.json"), "[]"),
        write(p.join(root.path, "downloads", "receipts", "task.json"), "{}"),
      ];

      await removeRetiredFiles(paths);

      for (final file in retired) {
        expect(file.existsSync(), isFalse, reason: file.path);
      }
      expect(saved.existsSync(), isTrue);
      expect(kept.existsSync(), isTrue);
      expect(staged.existsSync(), isTrue);
    });

    test("is fine with nothing to remove", () async {
      await removeRetiredFiles(paths);
    });
  });
}
