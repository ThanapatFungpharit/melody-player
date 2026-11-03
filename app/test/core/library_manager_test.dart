import "../support/temp.dart";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
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
    root = await createTestDirectory("melody-manager");
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

    test("adding to and moving between playlists", () async {
      final a = await add("a.mp3");
      final b = await add("b.mp3");
      final first = manager.createPlaylist("First");
      final second = manager.createPlaylist("Second");
      manager.addTracksToPlaylist(first, [a, b]);

      expect(manager.addToPlaylist(second, a), isTrue);
      expect(manager.addToPlaylist(second, a), isFalse);
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
    test("search matches titles, never links or file names", () async {
      await add("one.mp3", title: "Blue Song");
      await add("two.mp3", title: "Blue Note");
      await add("three.mp3", title: "Red", source: "https://example.com/blue");
      await add("blue-four.mp3", title: "Green");

      final found = manager.searchTracks("  BLUE ");

      expect(found.map((track) => track.title), ["Blue Note", "Blue Song"]);
      final page = manager.searchTracks("blue", offset: 1, limit: 1);
      expect(page.single.title, "Blue Song");
      expect(manager.searchTracks("blue", limit: 0), isEmpty);
      expect(manager.searchTracks("https"), isEmpty);
      expect(manager.searchTracks("mp3"), isEmpty);
    });

    test("search falls back to a track's file name for its title", () async {
      await add("untitled-demo.mp3");
      expect(manager.searchTracks("demo"), hasLength(1));
    });

    test("search also matches the artist it is given", () async {
      final adele = await add("hello.mp3", title: "Hello");
      await add("other.mp3", title: "Other");
      final found = manager.searchTracks(
        "adele",
        artist: (id) => id == adele ? "Adele" : "Someone",
      );
      expect(found.single.id, adele);
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
        expect(
          manager.getTrack(id).contentHash,
          await sha256File(manager.trackPath(id)),
        );
        expect((await reopen()).getPlaylist(playlist).trackIds, [id]);
      },
    );

    test("files outside the music folder are refused", () async {
      final outside = File(p.join(root.path, "outside.mp3"))
        ..writeAsStringSync("audio");

      expect(() => manager.addTrack(outside.path), throwsArgumentError);
      expect(() => manager.addTrack("../outside.mp3"), throwsArgumentError);
    });

    test(
      "file checks report missing and empty files, not edited ones",
      () async {
        final missing = await add("missing.mp3");
        final empty = await add("empty.mp3");
        final edited = await add("edited.mp3");
        File(p.join(music, "missing.mp3")).deleteSync();
        File(p.join(music, "empty.mp3")).writeAsBytesSync(const []);
        File(
          p.join(music, "edited.mp3"),
        ).writeAsStringSync("new tags, same song");

        expect((await manager.checkTrackFile(missing))?.kind, "missing");
        expect((await manager.checkTrackFile(empty))?.kind, "empty");
        expect(await manager.checkTrackFile(edited), isNull);
      },
    );
  });

  group("IDs", () {
    test("canonical IDs pass through and others are normalized", () {
      const id = "1b4e28ba-2fa1-11d2-883f-0016d3cca427";
      expect(normalizeUuid(id), id);
      expect(normalizeUuid(id.toUpperCase()), id);
      expect(normalizeUuid(" $id "), id);
      for (final bad in ["", "not-a-uuid", "${id}0", id.replaceAll("-", "_")]) {
        expect(normalizeUuid(bad), isNull, reason: bad);
      }
    });

    test("formatting an ID's bytes round-trips", () {
      const id = "00ff10ab-2fa1-11d2-883f-0016d3cca427";
      expect(uuidString(uuidBytes(id)), id);
    });

    test("tracks can be found by an uppercase ID", () async {
      final id = await add("a.mp3");
      expect(manager.hasTrack(id.toUpperCase()), isTrue);
      expect(manager.getTrack(id.toUpperCase()).id, id);
    });

    test("IDs and content hashes survive a reopen", () async {
      final id = await add("a.mp3");
      final hash = manager.getTrack(id).contentHash;
      expect(hash, matches(RegExp(r"^[0-9a-f]{64}$")));
      await reopen();
      expect(manager.getTrack(id).contentHash, hash);
    });
  });

  group("sorted pages", () {
    List<String> titles(String sort, {String query = ""}) => [
      for (final track in manager.searchTracks(query, sort: sort)) track.title,
    ];

    test("follow every change to the tracks", () async {
      final b = await add("b.mp3", title: "Bravo");
      final a = await add("a.mp3", title: "alpha");
      expect(titles("title"), ["alpha", "Bravo"]);
      expect(titles("oldest"), ["Bravo", "alpha"]);
      expect(titles("recent"), ["alpha", "Bravo"]);

      manager.updateTrack(a, title: "Zulu");
      expect(titles("title"), ["Bravo", "Zulu"]);

      final c = await add("c.mp3", title: "Charlie");
      expect(titles("title"), ["Bravo", "Charlie", "Zulu"]);
      expect(titles("oldest"), ["Bravo", "Zulu", "Charlie"]);

      manager.deleteTrack(b);
      expect(titles("title"), ["Charlie", "Zulu"]);
      expect(titles("oldest"), ["Zulu", "Charlie"]);
      expect(manager.trackIds, unorderedEquals([a, c]));
    });

    test("filter in sort order and keep ties newest first", () async {
      await add("a.mp3", title: "Same");
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final newer = await add("b.mp3", title: "same");
      await add("c.mp3", title: "Other");
      expect(manager.searchTracks("", sort: "title")[1].id, newer);
      expect(titles("title", query: "sam"), ["same", "Same"]);
      expect(
        manager.searchTracks("", sort: "title", offset: 1, limit: 1).single.id,
        newer,
      );
    });
  });
}
