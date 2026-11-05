import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/catalog.dart";
import "package:melody/core/errors.dart";
import "package:melody/core/media.dart";
import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

import "../support/fake_worker.dart";

void main() {
  late FakeWorkerTransport transport;
  late WorkerClient worker;
  late MusicCatalog catalog;

  setUp(() {
    transport = FakeWorkerTransport();
    worker = WorkerClient(transport);
    catalog = MusicCatalog(worker);
  });

  tearDown(() => worker.close());

  Map<String, Object?> lastCall() =>
      transport.sent.lastWhere((frame) => frame["op"] == "ytmusic");

  test("search asks YouTube Music for songs and maps them", () async {
    final results = await catalog.search("song", limit: 5);

    expect(lastCall()["method"], "search");
    expect(lastCall()["arguments"], {
      "query": "song",
      "filter": "songs",
      "limit": 5,
    });
    // The entry without a video is unavailable and skipped.
    expect(results, hasLength(1));
    final song = results.single;
    expect(song.url, "https://music.youtube.com/watch?v=abcdefghijk");
    expect(song.title, "Song");
    expect(song.uploader, "Artist, Guest");
    expect(song.duration, 185);
    expect(
      song.thumbnail,
      "https://lh3.googleusercontent.com/a=w544-h544-l90-rj",
    );
  });

  test("later pages skip the results already shown", () async {
    final results = await catalog.search("song", limit: 2, offset: 1);
    expect((lastCall()["arguments"] as Map)["limit"], 3);
    expect(results, isEmpty);
  });

  test("a pasted track URL resolves to that track", () async {
    final results = await catalog.search(
      "https://www.youtube.com/watch?v=abcdefghijk",
    );
    expect(lastCall()["method"], "get_watch_playlist");
    expect(results.single.duration, 185);
  });

  test(
    "recommendations come from the seed's radio, without the seed",
    () async {
      transport.ytMusicResults["get_watch_playlist"] = {
        "tracks": [
          {"videoId": "abcdefghijk", "title": "Seed"},
          {"videoId": "lmnopqrstuv", "title": "Next"},
        ],
      };
      final results = await catalog.recommendations(
        "https://music.youtube.com/watch?v=abcdefghijk",
        limit: 5,
      );
      expect((lastCall()["arguments"] as Map)["radio"], isTrue);
      expect(results.map((result) => result.title), ["Next"]);
    },
  );

  test("playlists import every available track under their title", () async {
    transport.ytMusicResults["get_playlist"] = {
      "title": "Road trip",
      "tracks": [
        {"videoId": "abcdefghijk", "title": "One", "duration": "1:02:03"},
        {"videoId": null, "title": "Removed"},
      ],
    };
    final playlist = await catalog.loadPlaylist(
      "https://music.youtube.com/playlist?list=PL123",
    );
    expect((lastCall()["arguments"] as Map)["playlistId"], "PL123");
    expect(playlist.title, "Road trip");
    expect(playlist.tracks.single.duration, 3723);
    expect(playlist.tracks.single.playlistTitle, "Road trip");
  });

  test("timed lyrics are read through the watch playlist", () async {
    final lyrics = await catalog.lyrics("abcdefghijk");
    expect(lastCall()["arguments"], {
      "browseId": "MPLYt_fake",
      "timestamps": true,
    });
    expect(lyrics!.synced, isTrue);
    expect(lyrics.source, "Source: Test");
    expect(lyrics.lineAt(1600), 1);
  });

  test("a track without lyrics has none", () async {
    transport.ytMusicResults["get_watch_playlist"] = {
      "tracks": <Object?>[],
      "lyrics": null,
    };
    expect(await catalog.lyrics("abcdefghijk"), isNull);
  });

  test("network failures read as YouTube Music being unreachable", () async {
    transport.offline = true;
    await expectLater(
      catalog.search("song"),
      throwsA(
        isA<ProviderError>().having(
          (error) => error.message,
          "message",
          contains("could not be reached"),
        ),
      ),
    );
  });

  test("yt-dlp keeps its cache in the folder Melody prunes", () {
    expect(
      sharedYtDlpOptions(cacheDirectory: "data/cache/yt-dlp"),
      containsPair("cachedir", "data/cache/yt-dlp"),
    );
  });

  test("cookies are passed only once a cookie file exists", () async {
    final root = await Directory.systemTemp.createTemp("melody-cookies");
    addTearDown(() => root.delete(recursive: true));
    final cookies = p.join(root.path, "cookies.txt");
    expect(
      sharedYtDlpOptions(cookieFile: cookies),
      isNot(contains("cookiefile")),
    );
    await File(cookies).writeAsString("# Netscape HTTP Cookie File\n");
    expect(
      sharedYtDlpOptions(cookieFile: cookies),
      containsPair("cookiefile", cookies),
    );
  });

  test("unusable durations read as unknown", () {
    double duration(Map<String, Object?> fields) => tracksFromYtMusic([
      {"videoId": "abcdefghijk", "title": "Song", ...fields},
    ]).single.duration;

    expect(duration({"duration_seconds": double.nan}), 0);
    expect(duration({"duration_seconds": -5}), 0);
    expect(duration({"duration": "1:-30"}), 0);
    expect(duration({"length": "live"}), 0);
    expect(duration({"duration": "1:02:03"}), 3723);
    // An unusable number falls back to the text form.
    expect(duration({"duration_seconds": -1, "duration": "3:05"}), 185);
  });

  group("with regular YouTube selected", () {
    Map<String, Object?> video(String id, {String? title, Object? live}) => {
      "id": id,
      "title": title ?? "Video $id",
      "channel": "Channel",
      "duration": 214,
      "live_status": live,
      "thumbnails": [
        {"url": "https://i.ytimg.com/small.jpg", "width": 360, "height": 202},
        {"url": "https://i.ytimg.com/large.jpg", "width": 720, "height": 404},
      ],
    };

    var source = MusicSource.youtube;
    final targets = <String>[];
    final options = <Map>[];

    setUp(() {
      source = MusicSource.youtube;
      targets.clear();
      options.clear();
      catalog = MusicCatalog(
        worker,
        source: () => source,
        ytDlpOptions: () => {"cookiefile": "cookies.txt"},
      );
      transport.onExtract = (target, sent) {
        targets.add(target);
        options.add(sent);
        return {
          "title": "Listing",
          "entries": [video("aaaaaaaaaaa"), video("bbbbbbbbbbb")],
        };
      };
    });

    test("search asks yt-dlp, and never YouTube Music", () async {
      final results = await catalog.search("song", limit: 5);

      expect(targets.single, "ytsearch5:song");
      expect(options.single["extract_flat"], "in_playlist");
      expect(options.single["cookiefile"], "cookies.txt");
      expect(
        transport.sent.where((frame) => frame["op"] == "ytmusic"),
        isEmpty,
      );
      final first = results.first;
      expect(first.url, "https://www.youtube.com/watch?v=aaaaaaaaaaa");
      expect(first.source, "YouTube");
      expect(first.uploader, "Channel");
      expect(first.duration, 214);
      expect(first.thumbnail, "https://i.ytimg.com/large.jpg");
      // The same video keeps its identity on either host.
      expect(first.identity, MediaIdentity(youtubeProviderId, "aaaaaaaaaaa"));
    });

    test("later pages skip the results already shown", () async {
      final results = await catalog.search("song", limit: 1, offset: 1);
      expect(targets.single, "ytsearch2:song");
      expect(results.single.id, "bbbbbbbbbbb");
    });

    test("the selection is read for every request", () async {
      await catalog.search("song");
      expect(targets, hasLength(1));
      source = MusicSource.youtubeMusic;
      final results = await catalog.search("song");
      expect(targets, hasLength(1));
      expect(lastCall()["method"], "search");
      expect(results.single.source, "YouTube Music");
    });

    test("entries that cannot be saved are skipped", () {
      final results = tracksFromYoutube([
        null,
        {"title": "No id"},
        video("deleted", title: "[Deleted video]"),
        video("private", title: "[Private video]"),
        video("live", live: "is_live"),
        video("soon", live: "is_upcoming"),
        video("kept", live: "not_live"),
      ]);
      expect(results.map((result) => result.id), ["kept"]);
    });

    test("thin details fall back rather than fail", () {
      final result = tracksFromYoutube([
        {"id": "aaaaaaaaaaa", "uploader": "Artist - Topic"},
        {"id": "bbbbbbbbbbb"},
      ]);
      expect(result[0].title, "Untitled video");
      expect(result[0].uploader, "Artist");
      expect(result[0].duration, 0);
      expect(result[0].thumbnail, "");
      expect(result[1].uploader, "Unknown channel");
    });

    test("a pasted link resolves that video on regular YouTube", () async {
      transport.onExtract = (target, sent) {
        targets.add(target);
        options.add(sent);
        return video("abcdefghijk");
      };
      final results = await catalog.search(
        "https://music.youtube.com/watch?v=abcdefghijk&si=tracking",
      );
      expect(targets.single, "https://www.youtube.com/watch?v=abcdefghijk");
      expect(options.single["noplaylist"], isTrue);
      expect(results.single.source, "YouTube");
    });

    test("a pasted live stream is refused with a reason", () async {
      transport.onExtract = (_, _) => video("abcdefghijk", live: "is_live");
      await expectLater(
        catalog.search("https://youtu.be/abcdefghijk"),
        throwsA(
          isA<ProviderError>().having(
            (error) => error.message,
            "message",
            contains("Live streams"),
          ),
        ),
      );
    });

    test("a link that reports nothing is a readable failure", () async {
      transport.onExtract = (_, _) => null;
      await expectLater(
        catalog.search("https://youtu.be/abcdefghijk"),
        throwsA(isA<ProviderError>()),
      );
    });

    for (final (reply, expected) in [
      ("ERROR: [youtube] x: Video unavailable", "not available"),
      ("ERROR: [youtube] x: This video is unavailable", "not available"),
      (
        "ERROR: [youtube] x: The uploader has not made this video available "
            "in your country",
        "not available",
      ),
      ("ERROR: [youtube] x: Private video", "private"),
      ("ERROR: Unable to download webpage", "YouTube could not be reached"),
      ("Read timed out.", "YouTube took too long"),
    ]) {
      test("the failure \"$reply\" is explained", () async {
        transport.onExtract = (_, _) => throw Exception(reply);
        await expectLater(
          catalog.search("https://youtu.be/abcdefghijk"),
          throwsA(
            isA<ProviderError>().having(
              (error) => error.message,
              "message",
              contains(expected),
            ),
          ),
        );
      });
    }

    test("recommendations come from the seed's YouTube mix", () async {
      transport.onExtract = (target, sent) {
        targets.add(target);
        options.add(sent);
        return {
          "entries": [video("abcdefghijk"), video("aaaaaaaaaaa")],
        };
      };
      final results = await catalog.recommendations(
        "https://music.youtube.com/watch?v=abcdefghijk",
        limit: 5,
      );
      expect(
        targets.single,
        "https://www.youtube.com/watch?v=abcdefghijk&list=RDabcdefghijk",
      );
      expect(options.single["playlistend"], 6);
      expect(results.map((result) => result.id), ["aaaaaaaaaaa"]);
    });

    test("playlists load through yt-dlp under their title", () async {
      final playlist = await catalog.loadPlaylist(
        "https://music.youtube.com/playlist?list=PL1",
      );
      expect(targets.single, "https://www.youtube.com/playlist?list=PL1");
      expect(playlist.title, "Listing");
      expect(playlist.tracks.first.playlistTitle, "Listing");
      expect(playlist.tracks.first.source, "YouTube");
    });

    test("mix links still open, through YouTube Music", () async {
      final playlist = await catalog.loadPlaylist(
        "https://www.youtube.com/watch?v=abcdefghijk&list=RDabcdefghijk",
      );
      expect(targets, isEmpty);
      expect(lastCall()["method"], "get_watch_playlist");
      expect(playlist.tracks.single.source, "YouTube Music");
    });

    test("lyrics still come from YouTube Music", () async {
      final lyrics = await catalog.lyrics("abcdefghijk");
      expect(targets, isEmpty);
      expect(lyrics?.lines, isNotEmpty);
    });

    test(
      "turning a pasted playlist's page after a switch reloads it",
      () async {
        const link = "https://www.youtube.com/playlist?list=PL1";
        await catalog.search(link, limit: 1);
        await catalog.search(link, limit: 1, offset: 1);
        expect(targets, hasLength(1));
        source = MusicSource.youtubeMusic;
        transport.ytMusicResults["get_playlist"] = {
          "title": "Music",
          "tracks": [],
        };
        await catalog.search(link, limit: 1, offset: 1);
        expect(lastCall()["method"], "get_playlist");
      },
    );
  });
}
