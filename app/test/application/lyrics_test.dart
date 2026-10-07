import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/core/errors.dart";
import "package:melody/core/id3_lyrics.dart";
import "package:path/path.dart" as p;

const _source = "https://music.youtube.com/watch?v=abcdefghijk";

void main() {
  late Directory root;
  late List<String> fetched;
  late Object? Function() reply;

  LyricsLibrary library({Duration recheckAfter = const Duration(days: 7)}) =>
      LyricsLibrary(p.join(root.path, "lyrics"), (videoId) async {
        fetched.add(videoId);
        final value = reply();
        if (value is Exception) throw value;
        return value as Lyrics?;
      }, recheckAfter: recheckAfter);

  Future<String> audio(String name) async {
    final path = p.join(root.path, name);
    await File("test/fixtures/artwork/cover.mp3").copy(path);
    return path;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-lyrics");
    fetched = [];
    reply = () => const Lyrics([
      LyricLine("Hello", startMs: 0, endMs: 900),
      LyricLine("World", startMs: 900, endMs: 2000),
    ], source: "Source: Test");
  });

  tearDown(() => root.delete(recursive: true));

  group("saved lyrics", () {
    test("are saved and then shown without a connection", () async {
      final first = await library().load(_source);
      expect(first!.synced, isTrue);

      reply = () => ProviderError("YouTube Music could not be reached.");
      final offline = await library().load(_source);

      expect(fetched, ["abcdefghijk"]);
      expect(offline!.lines.map((line) => line.text), ["Hello", "World"]);
      expect(offline.source, "Source: Test");
      expect(offline.lineAt(1000), 1);
    });

    test("are shared by every URL for the same video", () async {
      await library().load(_source);
      await library().load("https://youtu.be/abcdefghijk");
      expect(fetched, hasLength(1));
    });

    test("report that the network is needed when none are saved", () async {
      reply = () => ProviderError("YouTube Music could not be reached.");
      await expectLater(library().load(_source), throwsA(isA<ProviderError>()));
    });

    test("remember tracks without lyrics, then check again", () async {
      reply = () => null;
      expect(await library().load(_source), isNull);
      expect(await library().load(_source), isNull);
      expect(fetched, hasLength(1));

      await library(recheckAfter: Duration.zero).load(_source);
      expect(fetched, hasLength(2));
    });

    test("survive a failed refresh", () async {
      await library().load(_source);
      reply = () => ProviderError("offline");
      final refreshed = await library().load(_source, refresh: true);
      expect(fetched, hasLength(2));
      expect(refreshed!.lines.first.text, "Hello");
    });

    test("are prefetched once per track, ignoring failures", () async {
      final lyrics = library();
      lyrics.prefetch([
        (source: _source, path: ""),
        (source: "https://music.youtube.com/watch?v=lmnopqrstuv", path: ""),
      ]);
      await lyrics.idle;
      lyrics.prefetch([(source: _source, path: "")]);
      await lyrics.idle;
      expect(fetched, ["abcdefghijk", "lmnopqrstuv"]);

      reply = () => ProviderError("offline");
      lyrics.prefetch([
        (source: "https://music.youtube.com/watch?v=zzzzzzzzzzz", path: ""),
      ]);
      await lyrics.idle;
      expect(await lyrics.saved("https://youtu.be/zzzzzzzzzzz"), isNull);
    });

    test("are only fetched for YouTube Music sources", () async {
      await expectLater(
        library().load("file:///music/song.mp3"),
        throwsA(isA<LyricsUnavailable>()),
      );
    });
  });

  group("lyrics in files", () {
    test("a .lrc beside a local file is read, synced", () async {
      final path = await audio("Local.mp3");
      await File(
        p.join(root.path, "Local.lrc"),
      ).writeAsString("[ar:Someone]\n[00:01.50]First\n[00:03.00]Second\n");
      final lyrics = await library().forTrack((
        source: Uri.file(path).toString(),
        path: path,
      ));
      expect(lyrics!.synced, isTrue);
      expect(lyrics.lines.first.startMs, 1500);
      expect(lyrics.source, isEmpty);
      expect(fetched, isEmpty);
    });

    test("lyrics embedded in tags are read", () async {
      final path = await audio("Tagged.mp3");
      await writeId3Lyrics(path, "Line one\nLine two");
      final lyrics = await library().forTrack((source: "", path: path));
      expect(lyrics!.lines.map((line) => line.text), ["Line one", "Line two"]);
      expect(lyrics.source, isEmpty);
    });

    test("a file without lyrics has none", () async {
      final path = await audio("Bare.mp3");
      expect(await library().forTrack((source: "", path: path)), isNull);
    });

    test("YouTube Music tracks prefer the file, then fetch", () async {
      final path = await audio("Song.mp3");
      final lyrics = library();
      expect(
        (await lyrics.forTrack((source: _source, path: path)))!.source,
        "Source: Test",
      );
      await writeId3Lyrics(path, "[00:00.00]From the tag");
      final local = await lyrics.forTrack((source: _source, path: path));
      expect(local!.lines.single.text, "From the tag");
      expect(fetched, hasLength(1));
    });
  });

  group(".lrc files", () {
    test("Melody does not write one beside the audio", () async {
      final path = await audio("Song.mp3");
      final lyrics = await library().forTrack((source: _source, path: path));
      expect(lyrics!.lines, hasLength(2));
      expect(File(LyricsLibrary.sidecarPath(path)).existsSync(), isFalse);
    });

    test("only ones Melody wrote are cleaned up", () async {
      final mine = await audio("Mine.mp3");
      final theirs = await audio("Theirs.mp3");
      await File(
        LyricsLibrary.sidecarPath(mine),
      ).writeAsString("[re:Melody]\n[00:00.00]Hello\n");
      await File(LyricsLibrary.sidecarPath(theirs)).writeAsString("My words");
      await LyricsLibrary.removeMelodySidecar(mine);
      await LyricsLibrary.removeMelodySidecar(theirs);
      expect(File(LyricsLibrary.sidecarPath(mine)).existsSync(), isFalse);
      expect(
        await File(LyricsLibrary.sidecarPath(theirs)).readAsString(),
        "My words",
      );
    });

    test("are removed with their audio file", () async {
      final path = await audio("Song.mp3");
      await File(LyricsLibrary.sidecarPath(path)).writeAsString("x");
      await LyricsLibrary.deleteSidecar(path);
      expect(File(LyricsLibrary.sidecarPath(path)).existsSync(), isFalse);
    });
  });

  group("LRC", () {
    test("parses timestamps, repeats, and offsets", () {
      final lyrics = Lyrics.parse(
        "[ti:Song]\n[offset:500]\n[00:02.00][00:10.00]Chorus\n[00:05.5]Verse\n",
      );
      expect(lyrics.lines.map((line) => (line.startMs, line.text)), [
        (1500, "Chorus"),
        (5000, "Verse"),
        (9500, "Chorus"),
      ]);
      expect(lyrics.lines.first.endMs, 5000);
    });

    test("lines sharing a timestamp keep their file order", () {
      // More than 32 lines, where List.sort stops being stable; written out
      // of order so the sort has to move them.
      final text = StringBuffer();
      for (var second = 59; second >= 0; second--) {
        final stamp = "[00:${second.toString().padLeft(2, "0")}.00]";
        text
          ..writeln("${stamp}Line $second")
          ..writeln("${stamp}Translation $second");
      }
      final lines = Lyrics.parse(text.toString()).lines;
      expect(lines, hasLength(120));
      for (var second = 0; second < 60; second++) {
        expect(lines[second * 2].text, "Line $second");
        expect(lines[second * 2 + 1].text, "Translation $second");
      }
    });

    test("text without timestamps stays plain", () {
      final lyrics = Lyrics.parse("[re:Melody]\nOne\r\nTwo");
      expect(lyrics.synced, isFalse);
      expect(lyrics.lines.map((line) => line.text), ["One", "Two"]);
      expect(lyrics.toLrc(), "One\nTwo");
    });

    test("round-trips synced lyrics", () {
      const lyrics = Lyrics([
        LyricLine("A", startMs: 61230),
        LyricLine("B", startMs: 3723450),
      ]);
      expect(lyrics.toLrc(), "[01:01.23]A\n[62:03.45]B");
      expect(Lyrics.parse(lyrics.toLrc()).lines.map((line) => line.startMs), [
        61230,
        3723450,
      ]);
    });

    test("YouTube Music's plain lyrics keep their lines", () {
      final lyrics = Lyrics.fromYtMusic({
        "lyrics": "One\r\nTwo",
        "source": "Source: LyricFind",
        "hasTimestamps": false,
      })!;
      expect(lyrics.lines.map((line) => line.text), ["One", "Two"]);
      expect(lyrics.synced, isFalse);
      expect(lyrics.lineAt(5000), -1);
    });
  });
}
