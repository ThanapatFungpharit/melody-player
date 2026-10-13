import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/application/lyrics_embedding.dart";
import "package:melody/application/store.dart";
import "package:melody/core/artwork.dart";
import "package:melody/core/errors.dart";
import "package:melody/core/library/manager.dart";
import "package:path/path.dart" as p;

const _source = "https://music.youtube.com/watch?v=abcdefghijk";

const _lyrics = Lyrics([
  LyricLine("Hello", startMs: 0, endMs: 900),
  LyricLine("World", startMs: 900, endMs: 2000),
]);

void main() {
  late Directory root;
  late String music;
  late MusicManager manager;
  late ApplicationStore store;
  late LyricsLibrary lyrics;
  late List<String> fetched;
  late List<String> copied;
  late TagCopier copier;

  LyricsEmbedder embedder() =>
      LyricsEmbedder(manager, lyrics, store, (source, target, tags) {
        copied.add(p.basename(source));
        return copier(source, target, tags);
      });

  Future<String> track(
    String name, {
    String fixture = "test/fixtures/artwork/cover.mp3",
    String source = _source,
  }) async {
    final path = p.join(music, name);
    await File(fixture).copy(path);
    return manager.addTrack(path, source: source, title: name);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-embed");
    music = p.join(root.path, "music");
    await Directory(music).create();
    manager = MusicManager.open(p.join(root.path, "library.db"), music);
    store = ApplicationStore.open(
      p.join(root.path, "state.db"),
      defaultDownloadDirectory: music,
    );
    fetched = [];
    copied = [];
    copier = (source, target, tags) async =>
        throw Exception("FFmpeg could not copy this file");
    lyrics = LyricsLibrary(p.join(root.path, "lyrics"), (videoId) async {
      fetched.add(videoId);
      return _lyrics;
    });
  });

  tearDown(() async {
    await manager.close();
    await store.close();
    await root.delete(recursive: true);
  });

  test("puts lyrics inside an MP3 and keeps the library intact", () async {
    final id = await track("Song.mp3");
    final path = manager.trackPath(id);
    final before = manager.getTrack(id).contentHash;
    final artwork = await readEmbeddedArtwork(path);

    final embedding = embedder()..embed([id]);
    await embedding.idle;

    final embedded = Lyrics.parse(await readEmbeddedLyrics(path));
    expect(embedded.synced, isTrue);
    expect(embedded.lines.map((line) => line.text), ["Hello", "World"]);
    expect(await readEmbeddedArtwork(path), artwork);
    expect(manager.getTrack(id).contentHash, isNot(before));
    expect(await manager.checkTrackIntegrity(id), isNull);
    expect(Directory(music).listSync().map((entry) => p.basename(entry.path)), [
      "Song.mp3",
    ]);

    // Already embedded: nothing is fetched or rewritten again.
    final hash = manager.getTrack(id).contentHash;
    embedding.embed([id]);
    await embedding.idle;
    expect(fetched, hasLength(1));
    expect(manager.getTrack(id).contentHash, hash);
  });

  test("replaces Melody's .lrc but never a user's", () async {
    final mine = await track("Mine.mp3");
    final theirs = await track(
      "Theirs.mp3",
      source: "https://music.youtube.com/watch?v=bbbbbbbbbbb",
    );
    final mineLrc = File(LyricsLibrary.sidecarPath(manager.trackPath(mine)));
    final theirsLrc = File(
      LyricsLibrary.sidecarPath(manager.trackPath(theirs)),
    );
    await mineLrc.writeAsString("[re:Melody]\n[00:00.00]Hello\n");
    await theirsLrc.writeAsString("My words");

    final embedding = embedder()..embed([mine, theirs]);
    await embedding.idle;

    expect(mineLrc.existsSync(), isFalse);
    expect(await theirsLrc.readAsString(), "My words");
    expect(await readEmbeddedLyrics(manager.trackPath(theirs)), isNotEmpty);
  });

  test("waits for a playing track to stop", () async {
    final id = await track("Song.mp3");
    var playing = true;
    final embedding = embedder()..isPlaying = (trackId) => playing;

    embedding.embed([id]);
    await embedding.idle;
    expect(await readEmbeddedLyrics(manager.trackPath(id)), isEmpty);
    // The lyrics are saved, so they still show while it plays.
    expect((await lyrics.saved(_source))?.lyrics, isNotNull);

    playing = false;
    embedding.retryDeferred();
    await embedding.idle;
    expect(await readEmbeddedLyrics(manager.trackPath(id)), isNotEmpty);
  });

  test("leaves local files and tracks without lyrics alone", () async {
    final local = await track("Local.mp3", source: "");
    lyrics = LyricsLibrary(p.join(root.path, "lyrics"), (videoId) async {
      fetched.add(videoId);
      return null;
    });
    final none = await track("Instrumental.mp3");
    final hashes = [
      for (final id in [local, none]) manager.getTrack(id).contentHash,
    ];

    final embedding = embedder()..embed([local, none]);
    await embedding.idle;

    expect(fetched, ["abcdefghijk"]);
    expect([
      for (final id in [local, none]) manager.getTrack(id).contentHash,
    ], hashes);
  });

  test("a file FFmpeg cannot copy is left alone and not retried", () async {
    final id = await track(
      "Song.opus",
      fixture: "test/fixtures/artwork/cover.opus",
    );
    final hash = manager.getTrack(id).contentHash;

    await (embedder()..embed([id])).idle;
    expect(copied, ["Song.opus"]);
    expect(manager.getTrack(id).contentHash, hash);
    expect(await manager.checkTrackIntegrity(id), isNull);

    // Remembered across launches while the file stays the same.
    await (embedder()..embed([id])).idle;
    expect(copied, ["Song.opus"]);
    expect(Directory(music).listSync().map((entry) => p.basename(entry.path)), [
      "Song.opus",
    ]);
  });

  test("a stopped worker is retried, not remembered as unsupported", () async {
    final id = await track(
      "Song.opus",
      fixture: "test/fixtures/artwork/cover.opus",
    );
    copier = (source, target, tags) async =>
        throw WorkerFailure("The Python worker has stopped.");

    await (embedder()..embed([id])).idle;
    await (embedder()..embed([id])).idle;
    expect(copied, ["Song.opus", "Song.opus"]);

    // FFmpeg itself refusing the file is remembered.
    copier = (source, target, tags) async => throw WorkerFailure(
      "Conversion failed!",
      types: ["FFmpegPostProcessorError"],
    );
    await (embedder()..embed([id])).idle;
    await (embedder()..embed([id])).idle;
    expect(copied, ["Song.opus", "Song.opus", "Song.opus"]);
  });

  test("the whole library is queued at launch", () async {
    final first = await track("First.mp3");
    final second = await track(
      "Second.mp3",
      fixture: "test/fixtures/artwork/cover_v24.mp3",
    );

    final embedding = embedder()..embedLibrary();
    await embedding.idle;

    for (final id in [first, second]) {
      expect(await readEmbeddedLyrics(manager.trackPath(id)), isNotEmpty);
    }
    // Only the audio files: the rewrites' copies are gone.
    expect(Directory(music).listSync(), hasLength(2));
  });

  test(
    "other formats are copied by FFmpeg with a lyrics tag",
    () async {
      copier = (source, target, tags) async {
        final result = await Process.run("ffmpeg", [
          ...["-v", "error", "-nostdin", "-y", "-i", source],
          ...["-map", "0", "-dn", "-c", "copy", "-map_metadata", "0"],
          ...["-metadata", "lyrics=${tags["lyrics"]}", target],
        ]);
        if (result.exitCode != 0) throw Exception(result.stderr);
      };
      final id = await track(
        "Song.m4a",
        fixture: "test/fixtures/artwork/cover.m4a",
      );
      final path = manager.trackPath(id);
      final artwork = await readEmbeddedArtwork(path);

      await (embedder()..embed([id])).idle;

      final embedded = Lyrics.parse(await readEmbeddedLyrics(path));
      expect(embedded.lines.map((line) => line.startMs), [0, 900]);
      expect(await readEmbeddedArtwork(path), artwork);
      expect(await manager.checkTrackIntegrity(id), isNull);
    },
    skip: _hasFfmpeg() ? false : "needs FFmpeg on PATH",
  );
}

bool _hasFfmpeg() {
  try {
    return Process.runSync("ffmpeg", ["-version"]).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
