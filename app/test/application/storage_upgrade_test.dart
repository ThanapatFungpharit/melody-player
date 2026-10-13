import "../support/temp.dart";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/storage_upgrade.dart";
import "package:melody/application/store.dart";
import "package:melody/core/downloader/receipts.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
import "package:melody/platform/paths.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;
  late String music;
  late AppPaths paths;
  late LegacyLayout legacy;

  setUp(() async {
    root = await createTestDirectory("melody-upgrade");
    music = p.join(root.path, "Music");
    paths = AppPaths(dataDirectory: root.path, defaultMusicDirectory: music);
    legacy = LegacyLayout(paths);
  });

  tearDown(() => root.delete(recursive: true));

  File write(String path, [String contents = "x"]) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  group("relocateLegacyFolders", () {
    test("moves each folder to its place in the current layout", () async {
      write(p.join(root.path, "thumbnails", "${"a" * 64}.thumb"));
      write(p.join(root.path, "yt-dlp-runtime", "state.json"));
      write(p.join(root.path, "ytmusicapi-runtime", "state.json"));
      write(p.join(root.path, "yt-dlp-cache", "youtube-sigfuncs", "x.json"));

      await relocateLegacyFolders(legacy);

      expect(
        File(p.join(paths.artworkCache, "${"a" * 64}.thumb")).existsSync(),
        isTrue,
      );
      for (final package in ["yt-dlp", "ytmusicapi"]) {
        expect(
          File(p.join(paths.runtime(package), "state.json")).existsSync(),
          isTrue,
        );
      }
      expect(
        File(
          p.join(paths.ytDlpCache, "youtube-sigfuncs", "x.json"),
        ).existsSync(),
        isTrue,
      );
      for (final name in [
        "thumbnails",
        "yt-dlp-runtime",
        "ytmusicapi-runtime",
        "yt-dlp-cache",
      ]) {
        expect(Directory(p.join(root.path, name)).existsSync(), isFalse);
      }
    });

    test("drops a legacy folder once the new one is in use", () async {
      write(p.join(root.path, "thumbnails", "old.thumb"));
      write(p.join(paths.artworkCache, "new.thumb"));

      await relocateLegacyFolders(legacy);

      expect(Directory(p.join(root.path, "thumbnails")).existsSync(), isFalse);
      expect(Directory(paths.artworkCache).listSync(), hasLength(1));
    });

    test("removes files no release reads", () async {
      final saved = write(p.join(paths.lyrics, "youtube_abc.json"));
      write(p.join(paths.lyrics, "not_embedded.json"), "{}");

      await relocateLegacyFolders(legacy);

      expect(Directory(paths.lyrics).listSync().map((e) => e.path), [
        saved.path,
      ]);
    });
  });

  group("upgradeLegacyState", () {
    late ApplicationStore store;
    late MusicManager manager;

    setUp(() {
      store = ApplicationStore.open(
        paths.stateDatabase,
        defaultDownloadDirectory: music,
      );
      manager = MusicManager.open(paths.libraryDatabase, music);
    });

    tearDown(() async {
      await manager.close();
      await store.close();
    });

    void saveCookieSetting(String value) => store.set("settings", {
      ...(store.get("settings") as Map).cast<String, Object?>(),
      "cookie_file": value,
    });

    test("the cookie file replaces the cookie setting", () async {
      write(paths.cookieFile);
      saveCookieSetting(paths.cookieFile);

      await upgradeLegacyState(legacy, store, manager, storesExisted: true);

      expect(File(paths.cookieFile).existsSync(), isTrue);
      expect(store.get("settings") as Map, isNot(contains("cookie_file")));
    });

    test("cookies removed in the settings stay removed", () async {
      write(paths.cookieFile);
      saveCookieSetting("");

      await upgradeLegacyState(legacy, store, manager, storesExisted: true);

      expect(File(paths.cookieFile).existsSync(), isFalse);
      expect(store.get("settings") as Map, isNot(contains("cookie_file")));
      // Only once: a later upload is not removed again.
      write(paths.cookieFile);
      await upgradeLegacyState(legacy, store, manager, storesExisted: true);
      expect(File(paths.cookieFile).existsSync(), isTrue);
    });

    test("receipts beside the music move to the receipts folder", () async {
      final song = write(p.join(music, "Song.mp3"), "audio");
      const task = "11111111-1111-4111-8111-111111111111";
      // As the Python releases wrote it: no folder, files beside it.
      write(
        p.join(music, ".melody-download-$task.json"),
        jsonEncode({
          "schema": 1,
          "task_id": task,
          "url": "https://youtu.be/abcdefghijk",
          "files": [
            {"filename": "Song.mp3", "sha256": await sha256File(song.path)},
          ],
        }),
      );
      write(p.join(music, ".melody-download-bad.json"), "{not json");

      await upgradeLegacyState(legacy, store, manager, storesExisted: true);

      final receipt = await readReceipt(
        receiptPath(paths.downloadReceipts, task),
      );
      expect(receipt.files, [p.absolute(song.path)]);
      expect(Directory(music).listSync().map((e) => e.path), [song.path]);
    });

    test("import backups go once the databases have been used", () async {
      final backups = [for (final path in legacy.importedBackups) write(path)];

      // Imported during this launch: kept for now.
      await upgradeLegacyState(legacy, store, manager, storesExisted: false);
      expect(backups.every((file) => file.existsSync()), isTrue);

      await upgradeLegacyState(legacy, store, manager, storesExisted: true);
      expect(backups.any((file) => file.existsSync()), isFalse);
    });

    test("the old staging folder goes with everything in it", () async {
      final private = Directory(legacy.downloadStaging);
      write(p.join(private.path, ".melody-download-x.json.0123abcd.tmp"));
      write(p.join(private.path, "stray.part"));

      await upgradeLegacyState(legacy, store, manager, storesExisted: true);

      expect(private.existsSync(), isFalse);
    });

    test("staging beside the music is removed once abandoned", () async {
      final mine = write(p.join(music, "Mine.mp3"));
      final staging = Directory(p.join(music, ".melody-download-abc"));
      write(p.join(staging.path, ".melody-staging.lock"), "");
      write(p.join(staging.path, "Song.webm.part"));
      final unrelated = Directory(p.join(music, "Album"))..createSync();
      final private = Directory(legacy.downloadStaging)..createSync();

      await upgradeLegacyState(legacy, store, manager, storesExisted: true);

      expect(staging.existsSync(), isFalse);
      expect(mine.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
      expect(private.existsSync(), isFalse);
    });
  });
}
