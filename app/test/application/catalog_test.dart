import "package:flutter_test/flutter_test.dart";
import "package:melody/application/catalog.dart";
import "package:melody/application/models.dart";
import "package:melody/core/errors.dart";
import "package:melody/worker/worker_client.dart";

import "../support/fake_worker.dart";

void main() {
  late FakeWorkerTransport transport;
  late WorkerClient worker;
  late MusicCatalog catalog;

  setUp(() {
    transport = FakeWorkerTransport();
    worker = WorkerClient(transport);
    catalog = MusicCatalog(worker, () => const {});
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
    final settings = AppSettings(downloadDirectory: "music");
    expect(
      sharedYtDlpOptions(settings, cacheDirectory: "data/yt-dlp-cache"),
      containsPair("cachedir", "data/yt-dlp-cache"),
    );
  });
}
