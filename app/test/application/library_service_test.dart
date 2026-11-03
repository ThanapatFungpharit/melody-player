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
    await thumbnails.storeBytes(_thumbnail, _png);
    await lyrics.load(source);
    return id;
  }

  Future<bool> lyricsSaved() async => await lyrics.saved(_source) != null;

  test("deleting a track removes its file, artwork, and lyrics", () async {
    final id = await downloaded("song.mp3");
    final path = manager.trackPath(id);
    expect(thumbnails.cachedPath(_thumbnail), isNotNull);
    expect(await lyricsSaved(), isTrue);

    await library.deleteTrack(id);

    expect(manager.hasTrack(id), isFalse);
    expect(await File(path).exists(), isFalse);
    expect(thumbnails.cachedPath(_thumbnail), isNull);
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

  test("caches another track still uses are kept", () async {
    final first = await downloaded("first.mp3");
    await downloaded("second.mp3", source: "https://youtu.be/abcdefghijk");

    await library.deleteTrack(first);

    expect(thumbnails.cachedPath(_thumbnail), isNotNull);
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
    expect(thumbnails.cachedPath(_thumbnail), isNull);
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
    expect(await manager.checkTrackIntegrity(id), isNull);
    expect((await library.reconcile()).missingTrackIds, isEmpty);

    await File(path).delete();
    await File(original).delete();
    expect(await library.canRestoreLocalFile(id), isFalse);
  });

  test("unused artwork and lyrics are removed at startup", () async {
    await downloaded("song.mp3");
    const orphan = "https://i.ytimg.com/vi/zzzzzzzzzzz/hq.jpg";
    await thumbnails.storeBytes(orphan, _png);
    final unrelated = File(p.join(thumbnails.directory, "notes.txt"))
      ..writeAsStringSync("kept");
    // Lyrics saved for a preview, or for a download that failed.
    const preview = "https://music.youtube.com/watch?v=zzzzzzzzzzz";
    await lyrics.load(preview);

    expect(await library.removeUnusedCaches(), 2);
    expect(thumbnails.cachedPath(_thumbnail), isNotNull);
    expect(thumbnails.cachedPath(orphan), isNull);
    expect(unrelated.existsSync(), isTrue);
    expect(await lyricsSaved(), isTrue);
    expect(await lyrics.saved(preview), isNull);
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

    store.saveTrackDetails(linked, TrackDetails(duration: 201.6));

    final m3u8 = utf8.decode(library.exportPlaylistM3u8(source));
    expect(m3u8.split("\n"), [
      "#EXTM3U",
      "#PLAYLIST:Mixed",
      "#EXTINF:202,linked.mp3",
      "#MELODY-SHA256:${manager.getTrack(linked).contentHash}",
      _source,
      "#EXTINF:-1,local.mp3",
      "#MELODY-SHA256:${manager.getTrack(local).contentHash}",
      // Relative to the music folder, never this device's absolute path.
      "local.mp3",
      "",
    ]);

    // Saved elsewhere, a local file is listed relative to the playlist.
    final elsewhere = p.join(root.path, "exports");
    final relative = utf8.decode(
      library.exportPlaylistM3u8(source, directory: elsewhere),
    );
    expect(relative, contains("\n../music/local.mp3\n"));
  });

  test("an exported playlist finds its files on another device", () async {
    final localPath = p.join(music, "local.mp3");
    await File(localPath).writeAsString("local");
    final local = await manager.addTrack(localPath, title: "Local song");
    final hash = manager.getTrack(local).contentHash;
    final nested = p.join(music, "Artist", "nested.mp3");
    await Directory(p.dirname(nested)).create();
    await File(nested).writeAsString("nested");
    final inFolder = await manager.addTrack(nested, title: "Nested");
    final titledPath = p.join(music, "titled.mp3");
    await File(titledPath).writeAsString("titled");
    final titled = await manager.addTrack(titledPath, title: "Only title");
    store.saveTrackDetails(titled, TrackDetails(duration: 180));

    final m3u = [
      "#EXTM3U",
      "#PLAYLIST:From the laptop",
      // The same audio under another name: matched by its contents.
      "#EXTINF:-1,Renamed",
      "#MELODY-SHA256:${hash.toUpperCase()}",
      r"D:\Old Music\renamed.mp3",
      // Relative to the other device's music folder.
      "Artist/nested.mp3",
      // Only the title is known, and the duration agrees.
      "#EXTINF:181,Only title",
      "elsewhere/unknown.mp3",
      // The title matches but the duration does not.
      "#EXTINF:30,Only title",
      "elsewhere/short.mp3",
      "#EXTINF:-1,Never seen",
      "gone/never.flac",
    ].join("\n");
    final match = await library.matchPlaylistM3u(
      utf8.encode(m3u),
      fallbackName: "x",
      baseDirectory: p.join(root.path, "Downloads"),
    );
    expect(match.name, "From the laptop");
    expect(match.trackIds, [local, inFolder, titled]);
    expect(match.skipped, 2);
    final missing = [
      for (final entry in match.entries)
        if (entry.isMissing) (entry.title, entry.location),
    ];
    expect(missing, [
      ("Only title", "elsewhere/short.mp3"),
      ("Never seen", "gone/never.flac"),
    ]);
  });

  test("a located file joins the library once", () async {
    final existing = await downloaded("first.mp3");
    expect(await library.trackForFile(manager.trackPath(existing)), existing);

    final outside = p.join(root.path, "elsewhere", "found.mp3");
    await Directory(p.dirname(outside)).create();
    await File(outside).writeAsString("found");
    final imported = await library.trackForFile(outside);
    expect(imported, isNot(existing));
    expect(await library.trackForFile(outside), imported);
    expect(manager.listTracks(), hasLength(2));
  });

  test("a missing track is relinked to a located file", () async {
    final path = p.join(music, "moved.mp3");
    await File(path).writeAsString("moved");
    final id = await manager.addTrack(path, title: "Moved");
    final playlist = manager.createPlaylist("Kept");
    manager.addTracksToPlaylist(playlist, [id]);
    await File(path).delete();
    expect(await manager.checkTrackIntegrity(id), isNotNull);

    final located = p.join(root.path, "new place", "moved.mp3");
    await Directory(p.dirname(located)).create();
    await File(located).writeAsString("moved, re-encoded");
    await library.relinkTrack(id, located);

    expect(await manager.checkTrackIntegrity(id), isNull);
    // The file goes back where the track's file was.
    expect(manager.trackPath(id), path);
    expect(
      await File(manager.trackPath(id)).readAsString(),
      "moved, re-encoded",
    );
    expect(manager.getTrack(id).source, Uri.file(located).toString());
    expect(manager.getPlaylist(playlist).trackIds, [id]);
    expect(await library.canRestoreLocalFile(id), isTrue);
    await expectLater(
      library.relinkTrack(id, p.join(root.path, "notes.txt")),
      throwsFormatException,
    );
  });

  test("playlist entries keep their duration and content hash", () {
    final hash = "a" * 64;
    final (title, entries) = parseM3u(
      utf8.encode(
        [
          "#EXTM3U",
          "#EXTINF:215 tvg-id=\"x\",Song",
          "#MELODY-SHA256:$hash",
          "song.mp3",
          "#MELODY-SHA256:not-a-hash",
          "#EXTINF:-1,",
          "other.mp3",
        ].join("\n"),
      ),
    );
    expect(title, isNull);
    expect(entries, [
      (location: "song.mp3", title: "Song", duration: 215, hash: hash),
      (location: "other.mp3", title: null, duration: null, hash: null),
    ]);
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
