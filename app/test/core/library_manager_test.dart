import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/library/manager.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;
  late String music;
  late MusicManager manager;

  MusicManager open() =>
      MusicManager.open(p.join(root.path, "library.db"), music);

  /// Writes [name] with distinct bytes and registers it.
  Future<String> add(String name, {String title = "", String source = ""}) {
    File(p.join(music, name)).writeAsStringSync("audio of $name");
    return manager.addTrack(name, title: title, source: source);
  }

  Future<MusicManager> reopen() async {
    await manager.close();
    return manager = open();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-manager");
    music = p.join(root.path, "music");
    manager = open();
  });

  tearDown(() async {
    await manager.close();
    await root.delete(recursive: true);
  });

  group("music folder moves", () {
    late String journal;
    late String elsewhere;

    MusicManager openIn(String folder) => MusicManager.open(
      p.join(root.path, "library.db"),
      folder,
      moveJournal: journal,
    );

    setUp(() async {
      journal = p.join(root.path, "music-move.json");
      elsewhere = p.join(root.path, "elsewhere");
      await manager.close();
      manager = openIn(music);
    });

    test("a move the settings never recorded is undone at launch", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      await manager.moveMusicFolder(elsewhere);
      expect(File(journal).existsSync(), isTrue);
      // The process ends before the new folder is saved, and even before
      // the last file arrived.
      File(p.join(elsewhere, "b.mp3")).renameSync(p.join(music, "b.mp3"));
      await manager.close();

      manager = openIn(music);

      for (final id in [a, b]) {
        expect(File(manager.trackPath(id)).existsSync(), isTrue);
      }
      expect(Directory(elsewhere).listSync(), isEmpty);
      expect(File(journal).existsSync(), isFalse);
    });

    test("a completed move only drops its journal", () async {
      final a = await add("a.mp3");
      await manager.moveMusicFolder(elsewhere);
      await manager.close();

      manager = openIn(elsewhere);

      expect(p.dirname(manager.trackPath(a)), p.absolute(elsewhere));
      expect(File(manager.trackPath(a)).existsSync(), isTrue);
      expect(Directory(music).listSync(), isEmpty);
      expect(File(journal).existsSync(), isFalse);
    });
  });

  group("playlists", () {
    test("an explicit order is kept across launches", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final c = await add("c.mp3");
      final playlist = manager.createPlaylist("Mix");
      manager.addTracksToPlaylist(playlist, [a, b, c]);

      manager.reorderPlaylist(playlist, [c, a, b]);

      expect((await reopen()).getPlaylist(playlist).trackIds, [c, a, b]);
    });

    test("an order that drops or repeats a track is refused", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final playlist = manager.createPlaylist("Mix");
      manager.addTracksToPlaylist(playlist, [a, b]);

      expect(
        () => manager.reorderPlaylist(playlist, [a]),
        throwsFormatException,
      );
      expect(
        () => manager.reorderPlaylist(playlist, [a, a, b]),
        throwsFormatException,
      );
      expect(manager.getPlaylist(playlist).trackIds, [a, b]);
    });

    test("tracks added after a removal append in order", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final c = await add("c.mp3");
      final playlist = manager.createPlaylist("Mix");
      manager
        ..addToPlaylist(playlist, a)
        ..addToPlaylist(playlist, b)
        ..removeFromPlaylist(playlist, a)
        ..addToPlaylist(playlist, c)
        // Adding a member again changes nothing.
        ..addToPlaylist(playlist, b);

      expect((await reopen()).getPlaylist(playlist).trackIds, [b, c]);
    });

    test("moving and copying between playlists", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final first = manager.createPlaylist("First");
      final second = manager.createPlaylist("Second");
      manager.addTracksToPlaylist(first, [a, b]);

      manager.copyPlaylistTrack(first, second, a);
      manager.moveTrackBetweenPlaylists(first, second, b);

      final reopened = await reopen();
      expect(reopened.getPlaylist(first).trackIds, [a]);
      expect(reopened.getPlaylist(second).trackIds, [a, b]);
      expect(
        () => reopened.moveTrackBetweenPlaylists(first, second, b),
        throwsArgumentError,
      );
    });

    test("a merge puts the given tracks first and counts new ones", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final c = await add("c.mp3");
      final playlist = manager.createPlaylist("Import");
      manager.addTracksToPlaylist(playlist, [a, b]);

      expect(manager.mergeTracksIntoPlaylist(playlist, [c, b]), 1);
      expect(manager.getPlaylist(playlist).trackIds, [c, b, a]);
      // The same merge again changes nothing.
      expect(manager.mergeTracksIntoPlaylist(playlist, [c, b]), 0);
    });

    test("deleting a track removes it from every playlist", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final first = manager.createPlaylist("First");
      final second = manager.createPlaylist("Second");
      manager
        ..addTracksToPlaylist(first, [a, b])
        ..addTracksToPlaylist(second, [b]);

      manager.deleteTrack(b);

      final reopened = await reopen();
      expect(reopened.getPlaylist(first).trackIds, [a]);
      expect(reopened.getPlaylist(second).trackIds, isEmpty);
      expect(File(p.join(music, "b.mp3")).existsSync(), isTrue);
    });
  });

  group("tracks", () {
    test("search matches titles, filenames, and sources", () async {
      await add("one.mp3", title: "Blue Song");
      await add("two.mp3", title: "Red", source: "https://example.com/blue");
      await add("blue-three.mp3", title: "Green");
      await add("four.mp3", title: "Yellow");

      final found = manager.searchTracks("  BLUE ");

      expect(found.map((track) => track.title), ["Green", "Red", "Blue Song"]);
      final page = manager.searchTracks("blue", offset: 1, limit: 1);
      expect(page.single.title, "Red");
      expect(manager.searchTracks("blue", limit: 0), isEmpty);
    });

    test("sorting by title or age", () async {
      await add("b.mp3", title: "beta");
      await add("a.mp3", title: "Alpha");
      await add("untitled.mp3");

      expect(
        manager.searchTracks("", sort: "title").map((t) => t.displayTitle),
        ["Alpha", "beta", "untitled"],
      );
      expect(
        manager.searchTracks("", sort: "oldest").map((t) => t.displayTitle),
        ["beta", "Alpha", "untitled"],
      );
      expect(manager.listTracks().map((t) => t.displayTitle), [
        "untitled",
        "Alpha",
        "beta",
      ]);
    });

    test("tracks by id come newest first and skip unknown ids", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final c = await add("c.mp3");

      final selected = manager.tracksByIds([
        a,
        "not a uuid",
        c,
        "00000000-0000-4000-8000-000000000000",
        a.toUpperCase(),
      ]);

      expect(selected.map((track) => track.id), [c, a]);
      expect(manager.tracksByIds([a, b, c], limit: 2).map((t) => t.id), [c, b]);
    });

    test(
      "a replacement file keeps the identity and updates the hash",
      () async {
        final id = await add("old.mp3", source: "https://example.com/song");
        final playlist = manager.createPlaylist("Mix");
        manager.addToPlaylist(playlist, id);
        final replacement = File(p.join(music, "new.mp3"))
          ..writeAsStringSync("repaired audio");

        await manager.replaceTrackFile(id, replacement.path);

        expect(manager.getTrack(id).filename, "new.mp3");
        expect((await manager.findTrackByContent(replacement.path))?.id, id);
        expect(
          await manager.findTrackByContent(p.join(music, "old.mp3")),
          isNull,
        );
        expect(manager.isPathReferenced("new.mp3"), isTrue);
        expect(manager.isPathReferenced("new.mp3", excluding: id), isFalse);
        expect(manager.isPathReferenced("old.mp3"), isFalse);
        expect(await manager.checkTrackIntegrity(id), isNull);
        expect((await reopen()).getPlaylist(playlist).trackIds, [id]);
      },
    );

    test("files outside the music folder are refused", () async {
      final outside = File(p.join(root.path, "outside.mp3"))
        ..writeAsStringSync("audio");

      expect(() => manager.addTrack(outside.path), throwsArgumentError);
      expect(() => manager.addTrack("../outside.mp3"), throwsArgumentError);
    });

    test("integrity checks report missing and modified files", () async {
      final missing = await add("missing.mp3");
      final modified = await add("modified.mp3");
      File(p.join(music, "missing.mp3")).deleteSync();
      File(p.join(music, "modified.mp3")).writeAsStringSync("other bytes");

      expect((await manager.checkTrackIntegrity(missing))?.kind, "missing");
      expect((await manager.checkTrackIntegrity(modified))?.kind, "modified");
    });
  });
}
