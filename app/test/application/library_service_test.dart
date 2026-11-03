import "../support/temp.dart";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/library_service.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/application/models.dart";
import "package:melody/application/owned_files.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
import "package:path/path.dart" as p;

const _thumbnail = "https://i.ytimg.com/vi/abcdefghijk/hq.jpg";
const _source = "https://music.youtube.com/watch?v=abcdefghijk";
final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
]);

void main() {
  late Directory root;
  late String music;
  late MusicManager manager;
  late ApplicationStore store;
  late ThumbnailCache thumbnails;
  late LyricsLibrary lyrics;
  late LibraryService library;

  setUp(() async {
    root = await createTestDirectory("melody-library");
    music = p.join(root.path, "music");
    manager = MusicManager.open(p.join(root.path, "library.db"), music);
    store = ApplicationStore.open(
      p.join(root.path, "state.db"),
      defaultDownloadDirectory: music,
    );
    thumbnails = ThumbnailCache(p.join(root.path, "thumbnails"));
    lyrics = LyricsLibrary(
      p.join(root.path, "lyrics"),
      (_) async => const Lyrics([LyricLine("Hello")]),
    );
    library = LibraryService(
      manager,
      store,
      thumbnails: thumbnails,
      lyrics: lyrics,
    );
  });

  tearDown(() async {
    manager.close();
    store.close();
    await root.delete(recursive: true);
  });

  Future<String> downloaded(String name, {String source = _source}) async {
    final path = p.join(music, name);
    await File(path).writeAsString(name);
    final id = await manager.addTrack(path, source: source, title: name);
    store.saveTrackDetails(id, TrackDetails(thumbnail: _thumbnail));
    await thumbnails.store(id, _png);
    await lyrics.load(source);
    return id;
  }

  Future<bool> lyricsSaved() async => await lyrics.saved(_source) != null;

  test("deleting a track removes its file, artwork, and lyrics", () async {
    final id = await downloaded("song.mp3");
    final path = manager.trackPath(id);
    expect(thumbnails.cachedPath(id), isNotNull);
    expect(await lyricsSaved(), isTrue);

    await library.deleteTrack(id);

    expect(manager.hasTrack(id), isFalse);
    expect(await File(path).exists(), isFalse);
    expect(thumbnails.cachedPath(id), isNull);
    expect(await lyricsSaved(), isFalse);
  });

  test("a downloaded track's lyrics file goes with it", () async {
    final id = await downloaded("song.mp3");
    final lrc = File(p.join(music, "song.lrc"))..writeAsStringSync("[00:01]Hi");

    await library.deleteTrack(id);

    expect(lrc.existsSync(), isFalse);
  });

  test("a deletion a crash interrupted finishes at the next launch", () async {
    final id = await downloaded("song.mp3");
    final path = manager.trackPath(id);
    // The entry went, but the process ended before the file did.
    OwnedFiles(store, manager).mark([path]);
    manager.deleteTrack(id);
    store.removeTrackDetails(id);
    expect(File(path).existsSync(), isTrue);

    await library.releasePendingFiles();

    expect(File(path).existsSync(), isFalse);
    expect(store.get("pending_file_deletions"), isEmpty);
  });

  test(
    "a file another program holds open is deleted once it is free",
    () async {
      final id = await downloaded("song.mp3");
      final path = manager.trackPath(id);
      final held = await File(path).open();
      try {
        await library.deleteTrack(id);
        expect(manager.hasTrack(id), isFalse);
        expect(File(path).existsSync(), isTrue);
      } finally {
        await held.close();
      }

      await library.releasePendingFiles();

      expect(File(path).existsSync(), isFalse);
    },
    skip: Platform.isWindows
        ? false
        : "Only Windows refuses to delete open files",
  );

  test("a file whose entry survived a crash is kept", () async {
    final id = await downloaded("song.mp3");
    final path = manager.trackPath(id);
    // The process ended after recording the deletion, before the entry went.
    OwnedFiles(store, manager).mark([path]);

    await library.releasePendingFiles();

    expect(manager.hasTrack(id), isTrue);
    expect(File(path).existsSync(), isTrue);
    expect(store.get("pending_file_deletions"), isEmpty);
  });

  test("what another track still uses is kept", () async {
    final first = await downloaded("first.mp3");
    final second = await downloaded(
      "second.mp3",
      source: "https://youtu.be/abcdefghijk",
    );

    await library.deleteTrack(first);

    expect(thumbnails.cachedPath(first), isNull);
    expect(thumbnails.cachedPath(second), isNotNull);
    expect(await lyricsSaved(), isTrue);
  });

  test("deleting an imported track keeps its file", () async {
    final path = p.join(music, "mine.mp3");
    await File(path).writeAsString("mine");
    await File(LyricsLibrary.sidecarPath(path)).writeAsString("[00:01]Mine");
    final id = await manager.addTrack(
      path,
      source: Uri.file(p.join(root.path, "original.mp3")).toString(),
    );

    await library.deleteTrack(id);

    expect(manager.hasTrack(id), isFalse);
    expect(await File(path).exists(), isTrue);
    expect(await File(LyricsLibrary.sidecarPath(path)).exists(), isTrue);
  });

  test("clearing the library deletes only downloaded files", () async {
    final song = await downloaded("song.mp3");
    final songPath = manager.trackPath(song);
    final mine = p.join(music, "mine.mp3");
    await File(mine).writeAsString("mine");
    await manager.addTrack(mine);

    expect(await library.clearLibrary(), (2, 0));

    expect(manager.listTracks(), isEmpty);
    expect(await File(songPath).exists(), isFalse);
    expect(await File(mine).exists(), isTrue);
    expect(thumbnails.cachedPath(song), isNull);
    expect(await lyricsSaved(), isFalse);
  });

  test("a full reset deletes imported files too", () async {
    final song = await downloaded("song.mp3");
    final songPath = manager.trackPath(song);
    final mine = p.join(music, "mine.mp3");
    await File(mine).writeAsString("mine");
    await File(LyricsLibrary.sidecarPath(mine)).writeAsString("[00:01]Mine");
    await manager.addTrack(mine);

    expect(await library.clearLibrary(deleteImported: true), (2, 0));

    expect(await File(songPath).exists(), isFalse);
    expect(await File(mine).exists(), isFalse);
    expect(await File(LyricsLibrary.sidecarPath(mine)).exists(), isFalse);
  });

  test("stray files can be added to the library in place", () async {
    await downloaded("song.mp3");
    final stray = p.join(music, "stray.mp3");
    final copy = p.join(music, "copy.mp3");
    await File(stray).writeAsString("stray");
    await File(copy).writeAsString("song.mp3");

    final report = await library.reconcile();
    expect(report.unregisteredFiles, unorderedEquals([stray, copy]));

    final outcome = await library.addStrayFiles(report.unregisteredFiles);
    expect(outcome.done, 1);
    expect(outcome.failures.single, contains("already in the library"));
    final added = manager.listTracks().singleWhere((t) => t.title == "stray");
    expect(manager.trackPath(added.id), stray);
    expect(LibraryService.ownsFile(added), isFalse);
    expect((await library.reconcile()).unregisteredFiles, [copy]);
  });

  test("a music folder reached through a link has no stray tracks", () async {
    final real = p.join(root.path, "real music");
    await Directory(real).create();
    final linked = p.join(root.path, "linked music");
    await Link(linked).create(real);
    final other = MusicManager.open(p.join(root.path, "linked.db"), linked);
    addTearDown(other.close);
    final service = LibraryService(other, store);
    final song = p.join(linked, "song.mp3");
    await File(song).writeAsString("song");
    await other.addTrack(song, title: "Song");
    final stray = p.join(linked, "stray.mp3");
    await File(stray).writeAsString("stray");

    final report = await service.reconcile();
    expect(report.missingTrackIds, isEmpty);
    expect(report.unregisteredFiles, [stray]);
    // The reported path is accepted by the cleanup actions.
    final outcome = await service.deleteStrayFiles(report.unregisteredFiles);
    expect(outcome.failures, isEmpty);
    expect(await File(stray).exists(), isFalse);
    expect(await File(song).exists(), isTrue);
  });

  test("deleting stray files keeps library files", () async {
    final id = await downloaded("song.mp3");
    final stray = p.join(music, "stray.mp3");
    await File(stray).writeAsString("stray");
    await File(LyricsLibrary.sidecarPath(stray)).writeAsString("[00:01]Hi");
    final outside = p.join(root.path, "outside.mp3");
    await File(outside).writeAsString("outside");

    final outcome = await library.deleteStrayFiles([
      stray,
      manager.trackPath(id),
      outside,
    ]);

    expect(outcome.done, 1);
    expect(outcome.failures, hasLength(2));
    expect(await File(stray).exists(), isFalse);
    expect(await File(LyricsLibrary.sidecarPath(stray)).exists(), isFalse);
    expect(await File(manager.trackPath(id)).exists(), isTrue);
    expect(await File(outside).exists(), isTrue);
  });

  test("a missing imported file is restored from its original", () async {
    final original = p.join(root.path, "original.mp3");
    await File(original).writeAsString("original");
    final id = await library.importLocalFile(original);
    final path = manager.trackPath(id);
    await File(path).delete();
    expect((await library.reconcile()).missingTrackIds, [id]);

    expect(await library.canRestoreLocalFile(id), isTrue);
    await library.restoreLocalFile(id);

    expect(await File(path).readAsString(), "original");
    expect(manager.getTrack(id).contentHash, await sha256File(path));
    expect((await library.reconcile()).missingTrackIds, isEmpty);

    await File(path).delete();
    await File(original).delete();
    expect(await library.canRestoreLocalFile(id), isFalse);
  });

  test("unused artwork and lyrics are removed at startup", () async {
    final id = await downloaded("song.mp3");
    const orphan = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
    await thumbnails.store(orphan, _png);
    final unrelated = File(p.join(thumbnails.directory, "notes.txt"))
      ..writeAsStringSync("kept");
    // Lyrics saved for a download that failed.
    const failed = "https://music.youtube.com/watch?v=zzzzzzzzzzz";
    await lyrics.load(failed);

    expect(await library.removeUnusedCaches(), 2);
    expect(thumbnails.cachedPath(id), isNotNull);
    expect(thumbnails.cachedPath(orphan), isNull);
    expect(unrelated.existsSync(), isTrue);
    expect(await lyricsSaved(), isTrue);
    expect(await lyrics.saved(failed), isNull);
    // Idempotent.
    expect(await library.removeUnusedCaches(), 0);
  });

  test("favoriting a track that left the library changes nothing", () async {
    final id = await downloaded("song.mp3");
    await library.deleteTrack(id);
    expect(() => library.toggleFavorite(id), throwsArgumentError);
    expect(store.hasTrackDetails(id), isFalse);
  });

  test("the Favorites playlist follows favorites, newest first", () async {
    final first = await downloaded("first.mp3");
    final second = await downloaded(
      "second.mp3",
      source: "https://music.youtube.com/watch?v=bbbbbbbbbbb",
    );
    final third = await downloaded(
      "third.mp3",
      source: "https://music.youtube.com/watch?v=ccccccccccc",
    );
    expect(library.favoritesPlaylist().trackIds, isEmpty);

    library
      ..toggleFavorite(third)
      ..toggleFavorite(first)
      ..toggleFavorite(second);
    final favorites = library.favoritesPlaylist();
    expect(favorites.id, favoritesPlaylistId);
    expect(favorites.name, "Favorites");
    expect(favorites.trackIds, [third, second, first]);
    // It is never stored with the user's playlists.
    expect(manager.listPlaylists(), isEmpty);
    expect(manager.hasPlaylist(favoritesPlaylistId), isFalse);

    library.toggleFavorite(second);
    expect(library.favoritesPlaylist().trackIds, [third, first]);
    await library.deleteTrack(third);
    expect(library.favoritesPlaylist().trackIds, [first]);

    final m3u8 = String.fromCharCodes(
      library.exportPlaylistM3u8(favoritesPlaylistId),
    );
    expect(m3u8, contains("#EXTINF:-1,first.mp3"));
    expect(m3u8, isNot(contains("second.mp3")));
  });

  test("Favorites keeps a dragged order and appends new favorites", () async {
    final first = await downloaded("first.mp3");
    final second = await downloaded(
      "second.mp3",
      source: "https://music.youtube.com/watch?v=bbbbbbbbbbb",
    );
    final third = await downloaded(
      "third.mp3",
      source: "https://music.youtube.com/watch?v=ccccccccccc",
    );
    library
      ..toggleFavorite(first)
      ..toggleFavorite(second);
    expect(library.favoritesPlaylist().trackIds, [second, first]);

    library.reorderFavorites([first, second]);
    expect(library.favoritesPlaylist().trackIds, [first, second]);
    // A new favorite follows the saved order.
    library.toggleFavorite(third);
    expect(library.favoritesPlaylist().trackIds, [first, second, third]);
    // Unfavoriting drops a track; favoriting it again appends it.
    library
      ..toggleFavorite(first)
      ..toggleFavorite(first);
    expect(library.favoritesPlaylist().trackIds, [second, third, first]);
  });

  test("an exported playlist imports back in order", () async {
    final first = await downloaded("first.mp3");
    final second = await downloaded(
      "second.mp3",
      source: "https://music.youtube.com/watch?v=bbbbbbbbbbb",
    );
    final source = manager.createPlaylist("Road trip");
    manager.addTracksToPlaylist(source, [second, first]);

    final result = await library.importPlaylistM3u(
      library.exportPlaylistM3u8(source),
      fallbackName: "Road trip",
    );
    expect(result.name, "Road trip");
    expect(result.added, 2);
    expect(result.skipped, 0);
    expect(manager.getPlaylist(result.playlistId).trackIds, [second, first]);
  });

  test("playlist files match by relative path, URL, and file name", () async {
    final first = await downloaded("first.mp3");
    final second = await downloaded(
      "second.mp3",
      source: "https://music.youtube.com/watch?v=bbbbbbbbbbb",
    );
    final third = await downloaded(
      "third.mp3",
      source: "https://music.youtube.com/watch?v=ccccccccccc",
    );
    final m3u = [
      "\uFEFF#EXTM3U",
      "#PLAYLIST:Mixed",
      "#EXTINF:-1,Third",
      r"C:\Users\someone\Music\THIRD.mp3",
      "https://music.youtube.com/watch?v=bbbbbbbbbbb",
      "first.mp3",
      "first.mp3",
      "missing.mp3",
      "https://example.com/stream.mp3",
    ].join("\r\n");

    final result = await library.importPlaylistM3u(
      utf8.encode(m3u),
      fallbackName: "ignored",
      baseDirectory: music,
    );
    expect(result.name, "Mixed");
    expect(result.added, 3);
    expect(result.skipped, 2);
    expect(manager.getPlaylist(result.playlistId).trackIds, [
      third,
      second,
      first,
    ]);
  });

  test("an exported playlist lists links, or files without one", () async {
    final linked = await downloaded("linked.mp3");
    final localPath = p.join(music, "local.mp3");
    await File(localPath).writeAsString("local");
    final local = await manager.addTrack(localPath, title: "local.mp3");
    final source = manager.createPlaylist("Mixed");
    manager.addTracksToPlaylist(source, [linked, local]);

    final m3u8 = utf8.decode(library.exportPlaylistM3u8(source));
    expect(m3u8.split("\n"), [
      "#EXTM3U",
      "#EXTINF:-1,linked.mp3",
      _source,
      "#EXTINF:-1,local.mp3",
      Uri.file(manager.trackPath(local)).toString(),
      "",
    ]);
  });

  test(
    "an export leaves out what a stored link picked up when pasted",
    () async {
      final id = await downloaded(
        "pasted.mp3",
        source: "https://youtu.be/abcdefghijk?si=tracking&list=PLabc",
      );
      final playlist = manager.createPlaylist("Pasted");
      manager.addToPlaylist(playlist, id);

      final m3u8 = utf8.decode(library.exportPlaylistM3u8(playlist));

      expect(m3u8, contains(_source));
      expect(m3u8, isNot(contains("tracking")));
      expect(m3u8, isNot(contains("list=")));
    },
  );

  test(
    "a playlist link in a playlist file is skipped, not downloaded",
    () async {
      final first = await downloaded("first.mp3");
      final match = await library.matchPlaylistM3u(
        utf8.encode(
          "#EXTM3U\n$_source\nhttps://music.youtube.com/playlist?list=PLabc\n",
        ),
        fallbackName: "Mixed",
      );

      expect(match.trackIds, [first]);
      expect(match.entries.last.url, isNull);
      expect(match.skipped, 1);
    },
  );

  test("searching finds artists, and nothing in a track's link", () async {
    final id = await downloaded("hello.mp3");
    await downloaded(
      "other.mp3",
      source: "https://music.youtube.com/watch?v=lmnopqrstuv",
    );
    store.saveTrackDetails(id, TrackDetails(uploader: "Adele"));

    expect(library.trackIds(query: "ADELE"), [id]);
    expect(library.trackIds(query: "  hello "), [id]);
    expect(library.trackIds(query: "music"), isEmpty);
    expect(library.trackIds(query: "watch"), isEmpty);
    expect(library.trackIds(query: "abcdefghijk"), isEmpty);
    expect(library.matches(id, "adele"), isTrue);
    expect(library.matches(id, ""), isTrue);
    expect(library.matches(id, "someone"), isFalse);
  });

  group("sorting the library", () {
    late String ana, bob, ben, nobody;

    Future<String> tagged(
      String title, {
      String artist = "",
      double duration = 0,
      int plays = 0,
      double lastPlayed = 0,
    }) async {
      final path = p.join(music, "$title.mp3");
      await File(path).writeAsString(title);
      final id = await manager.addTrack(path, title: title);
      store.saveTrackDetails(
        id,
        TrackDetails(
          uploader: artist,
          duration: duration,
          playCount: plays,
          lastPlayed: lastPlayed,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      return id;
    }

    setUp(() async {
      ana = await tagged("Zebra", artist: "ana", duration: 100, plays: 1);
      bob = await tagged("Bee", artist: "Bob", duration: 300, plays: 5);
      ben = await tagged(
        "Ant",
        artist: "Bob",
        duration: 200,
        plays: 5,
        lastPlayed: 9,
      );
      nobody = await tagged("Moth");
    });

    test("by artist, with a track's title within one", () {
      expect(library.trackIds(sort: "artist"), [ana, ben, bob, nobody]);
    });

    test("longest first", () {
      expect(library.trackIds(sort: "longest"), [bob, ben, ana, nobody]);
    });

    test("most played first, the latest played among equals", () {
      expect(library.trackIds(sort: "played"), [ben, bob, ana, nobody]);
    });

    test("keeps its order when filtered", () {
      expect(library.trackIds(query: "bob", sort: "longest"), [bob, ben]);
    });

    test("does not change the order it starts from", () {
      library.trackIds(sort: "longest");
      expect(library.trackIds(), [nobody, ben, bob, ana]);
    });
  });

  test("an artist can be set, and cleared", () async {
    final id = await downloaded("song.mp3");
    library.setArtist(id, "  Someone ");
    expect(library.details(id).uploader, "Someone");
    library.setArtist(id, "");
    expect(library.details(id).uploader, isEmpty);
    expect(library.details(id).thumbnail, _thumbnail);
  });

  group("what a file says about itself", () {
    const tagged = "test/fixtures/tags/tagged.mp3";
    const covered = "test/fixtures/artwork/cover.mp3";
    const uncovered = "test/fixtures/artwork/no_cover.mp3";

    test("names an imported track and shows its cover", () async {
      final id = await library.importLocalFile(tagged);
      expect(manager.getTrack(id).title, "Tagged Títle ปั้น");
      expect(library.details(id).uploader, "Tagged Ártist");
      expect(library.details(id).sourceName, "Local file");

      final withCover = await library.importLocalFile(covered);
      expect(manager.getTrack(withCover).title, "cover");
      expect(library.artwork(withCover), thumbnails.cachedPath(withCover));
      expect(library.artwork(withCover), isNotEmpty);
    });

    test("names a stray file added in place", () async {
      final stray = p.join(music, "stray.mp3");
      await File(tagged).copy(stray);
      expect((await library.addStrayFiles([stray])).done, 1);
      final track = manager.listTracks().single;
      expect(track.title, "Tagged Títle ปั้น");
      expect(library.details(track.id).uploader, "Tagged Ártist");
    });

    test("fills in what earlier imports left out, once", () async {
      // As earlier releases imported them: file names and nothing else.
      Future<String> imported(String fixture, String name) async {
        final path = p.join(music, name);
        await File(fixture).copy(path);
        final id = await manager.addTrack(
          path,
          source: Uri.file(p.join(root.path, name)).toString(),
          title: p.basenameWithoutExtension(name),
        );
        store.saveTrackDetails(id, TrackDetails(sourceName: "Local file"));
        return id;
      }

      final named = await imported(tagged, "named.mp3");
      final renamed = await imported(tagged, "renamed.mp3");
      manager.updateTrack(renamed, title: "My own title");
      final cover = await imported(covered, "covered.mp3");
      final plain = await imported(uncovered, "plain.mp3");
      var changes = 0;

      await library.readMissingMetadata(onChanged: () => changes++);

      expect(changes, greaterThan(0));
      expect(manager.getTrack(named).title, "Tagged Títle ปั้น");
      expect(library.details(named).uploader, "Tagged Ártist");
      // A title the user chose stays.
      expect(manager.getTrack(renamed).title, "My own title");
      expect(library.details(renamed).uploader, "Tagged Ártist");
      expect(thumbnails.cachedPath(cover), isNotNull);
      expect(thumbnails.cachedPath(plain), isNull);

      // Everything is known now, covers or not: nothing is read again.
      await File(manager.trackPath(plain)).delete();
      changes = 0;
      await library.readMissingMetadata(onChanged: () => changes++);
      expect(changes, 0);
    });

    test("a download's tags never replace what was listed for it", () async {
      final path = p.join(music, "song.mp3");
      await File(tagged).copy(path);
      final id = await manager.addTrack(path, source: _source, title: "Listed");
      store.saveTrackDetails(id, TrackDetails(uploader: "Listed artist"));

      await library.readMissingMetadata();

      expect(manager.getTrack(id).title, "Listed");
      expect(library.details(id).uploader, "Listed artist");
    });

    test("a missing file is read once it is back", () async {
      final path = p.join(music, "song.mp3");
      await File(covered).copy(path);
      final id = await manager.addTrack(path, title: "Song");
      final moved = "$path.moved";
      await File(path).rename(moved);

      await library.readMissingMetadata();
      expect(thumbnails.known(id), isFalse);

      await File(moved).rename(path);
      await library.readMissingMetadata();
      expect(thumbnails.cachedPath(id), isNotNull);
    });

    test("cancelling stops before the next batch", () async {
      final path = p.join(music, "song.mp3");
      await File(covered).copy(path);
      final id = await manager.addTrack(path, title: "Song");
      await library.readMissingMetadata(cancelled: () => true);
      expect(thumbnails.known(id), isFalse);
    });

    test("a remote cover shows until the track's own is cached", () async {
      final path = p.join(music, "song.mp3");
      await File(covered).copy(path);
      final id = await manager.addTrack(path, source: _source, title: "Song");
      store.saveTrackDetails(id, TrackDetails(thumbnail: _thumbnail));
      expect(library.artwork(id), _thumbnail);
      expect(library.artworkUri(id), _thumbnail);

      await library.readMissingMetadata();

      expect(library.artwork(id), thumbnails.cachedPath(id));
      expect(library.artworkUri(id), startsWith("file:"));
    });

    test("a length is not remembered for a track the library lacks", () {
      const id = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
      library.rememberDuration(id, 10);
      expect(store.hasTrackDetails(id), isFalse);
    });
  });

  test("linked tracks missing from the library are left to download", () async {
    final first = await downloaded("first.mp3");
    final m3u = [
      "#EXTM3U",
      "#EXTINF:-1,First",
      _source,
      "#EXTINF:123,Artist - Missing song",
      "https://music.youtube.com/watch?v=zzzzzzzzzzz",
      "https://example.com/stream.mp3",
    ].join("\n");

    final match = await library.matchPlaylistM3u(
      utf8.encode(m3u),
      fallbackName: "Linked",
    );
    expect(match.name, "Linked");
    expect(match.trackIds, [first]);
    expect(match.skipped, 1);
    final download = match.entries[1];
    expect(download.url, "https://music.youtube.com/watch?v=zzzzzzzzzzz");
    expect(download.title, "Artist - Missing song");

    // Without downloading, only the library track is imported.
    final result = await library.importPlaylistM3u(
      utf8.encode(m3u),
      fallbackName: "Linked",
    );
    expect(result.added, 1);
    expect(result.skipped, 2);
  });

  test("a playlist file of only missing links still matches", () async {
    final match = await library.matchPlaylistM3u(
      utf8.encode("#EXTM3U\nhttps://youtu.be/zzzzzzzzzzz\n"),
      fallbackName: "New",
    );
    expect(match.trackIds, isEmpty);
    expect(match.entries.single.url, "https://youtu.be/zzzzzzzzzzz");
    expect(match.entries.single.title, "https://youtu.be/zzzzzzzzzzz");
  });

  test("a playlist file with no library tracks creates no playlist", () async {
    await downloaded("first.mp3");
    await expectLater(
      library.importPlaylistM3u(
        utf8.encode("#EXTM3U\n/nowhere/else.mp3\n"),
        fallbackName: "Nothing",
      ),
      throwsFormatException,
    );
    await expectLater(
      library.importPlaylistM3u(utf8.encode("#EXTM3U\n"), fallbackName: "x"),
      throwsFormatException,
    );
    expect(manager.listPlaylists(), isEmpty);
  });
}
