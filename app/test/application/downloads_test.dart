import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/lyrics.dart";
import "package:melody/application/models.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/core/artwork.dart";
import "package:melody/core/downloader/downloader.dart";
import "package:melody/core/downloader/receipts.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

import "../support/fake_worker.dart";

const _url = "https://music.youtube.com/watch?v=abcdefghijk";

SearchResult _result({
  String url = _url,
  String thumbnail = "https://i.ytimg.com/vi/abcdefghijk/hq.jpg",
}) => SearchResult(
  id: "abcdefghijk",
  title: "Search title",
  uploader: "Uploader",
  duration: 200,
  thumbnail: thumbnail,
  url: url,
  source: "YouTube Music",
);

void main() {
  late Directory root;
  late String music;
  late MusicManager manager;
  late ApplicationStore store;
  late FakeWorkerTransport transport;
  late WorkerClient worker;
  late ThumbnailCache thumbnails;
  final published = <String>{};

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-downloads");
    music = p.join(root.path, "music");
    manager = MusicManager.open(p.join(root.path, "library.db"), music);
    store = ApplicationStore.open(
      p.join(root.path, "state.db"),
      defaultDownloadDirectory: music,
    );
    transport = FakeWorkerTransport();
    worker = WorkerClient(transport);
    thumbnails = ThumbnailCache(p.join(root.path, "thumbnails"));
  });

  tearDown(() async {
    manager.close();
    store.close();
    await worker.close();
    await root.delete(recursive: true);
  });

  Future<DownloadCoordinator> open() => DownloadCoordinator.open(
    manager,
    store,
    store.settings,
    worker,
    thumbnails: thumbnails,
  );

  /// Waits for the published terminal record, which follows every
  /// completion side effect (registration, cache, receipt acknowledgement).
  Future<DownloadRecord> terminal(
    DownloadCoordinator coordinator,
    String task,
  ) {
    final existing = coordinator.get(task);
    if (existing != null &&
        existing.status.isFinished &&
        published.contains(task)) {
      return Future.value(existing);
    }
    final completer = Completer<DownloadRecord>();
    coordinator.onRecord = (record) {
      published.add(record.id);
      if (record.id == task &&
          record.status.isFinished &&
          !completer.isCompleted) {
        completer.complete(record);
      }
    };
    return completer.future.timeout(const Duration(seconds: 10));
  }

  test(
    "a completed download is verified, registered, and acknowledged",
    () async {
      final coordinator = await open();
      final request = await coordinator.request(_result());
      expect(request.started, isTrue);

      final task = request.task!;
      final record = await terminal(coordinator, task);
      expect(record.status, DownloadStatus.completed);
      expect(record.trackIds, hasLength(1));
      final track = manager.getTrack(record.trackIds.single);
      expect(track.title, "Search title");
      expect(track.source, _url);
      expect(File(manager.trackPath(track.id)).existsSync(), isTrue);
      expect(
        p.dirname(manager.trackPath(track.id)),
        p.normalize(p.absolute(music)),
      );
      final details = store.trackDetails(track.id);
      expect(details.uploader, "Uploader");
      expect(details.duration, 200);
      // The cache is derived from the verified embedded cover.
      expect(thumbnails.cachedPath(_result().thumbnail), isNotNull);
      expect(File(receiptPath(music, task)).existsSync(), isFalse);
      expect(coordinator.activeCount(), 0);
      // No staging directory survives.
      expect(
        Directory(music).listSync().where(
          (item) => p.basename(item.path).startsWith(".melody-download-"),
        ),
        isEmpty,
      );
      // The intact track is reused instead of downloading again.
      final reused = await coordinator.request(_result());
      expect(reused.task, isNull);
      expect(reused.track?.id, track.id);
    },
  );

  test("a second request joins the active download", () async {
    transport.downloadGate = Completer();
    final coordinator = await open();
    final first = await coordinator.request(_result());
    final second = await coordinator.request(
      _result(url: "https://www.youtube.com/watch?v=abcdefghijk"),
    );
    expect(second.task, first.task);
    expect(first.started, isTrue);
    expect(second.started, isFalse);
    transport.downloadGate!.complete();
    expect(
      (await terminal(coordinator, first.task!)).status,
      DownloadStatus.completed,
    );
    expect(
      transport.sent.where((frame) => frame["op"] == "download"),
      hasLength(1),
    );
  });

  test("a new folder applies to the next download and the library", () async {
    final coordinator = await open();
    final moved = p.join(root.path, "moved");
    await coordinator.changeDirectory(moved);
    expect(manager.musicFolder, moved);

    final record = await terminal(
      coordinator,
      (await coordinator.request(_result())).task!,
    );
    expect(record.status, DownloadStatus.completed);
    final path = manager.trackPath(record.trackIds.single);
    expect(p.dirname(path), p.normalize(p.absolute(moved)));
    expect(File(path).existsSync(), isTrue);
    expect(manager.getTrack(record.trackIds.single).filename, p.basename(path));
    // The library now has a track recorded relative to the folder.
    await expectLater(
      coordinator.changeDirectory(music),
      throwsA(isA<FormatException>()),
    );
    expect(manager.musicFolder, moved);
  });

  test("the folder cannot change while a download is active", () async {
    transport.downloadGate = Completer();
    final coordinator = await open();
    final task = (await coordinator.request(_result())).task!;
    await expectLater(
      coordinator.changeDirectory(p.join(root.path, "moved")),
      throwsA(isA<FormatException>()),
    );
    expect(manager.musicFolder, music);
    transport.downloadGate!.complete();
    final record = await terminal(coordinator, task);
    expect(
      p.dirname(manager.trackPath(record.trackIds.single)),
      p.normalize(p.absolute(music)),
    );
  });

  test("missing embedded artwork fails before the file is committed", () async {
    // yt-dlp retained a thumbnail sidecar, but the audio has no cover.
    transport.audioFixture = "test/fixtures/artwork/no_cover.mp3";
    final coordinator = await open();
    final record = await terminal(
      coordinator,
      (await coordinator.request(_result())).task!,
    );
    expect(record.status, DownloadStatus.failed);
    expect(record.errorKind, "postprocessing");
    expect(manager.counts().$1, 0);
    expect(
      Directory(
        music,
      ).listSync().whereType<File>().where((f) => f.path.endsWith(".mp3")),
      isEmpty,
    );
  });

  test("audio without any thumbnail needs no artwork", () async {
    transport.audioFixture = "test/fixtures/artwork/no_cover.mp3";
    transport.writeThumbnail = false;
    final coordinator = await open();
    final record = await terminal(
      coordinator,
      (await coordinator.request(_result(thumbnail: ""))).task!,
    );
    expect(record.status, DownloadStatus.completed);
  });

  test("cancelling a running download keeps nothing", () async {
    transport.downloadGate = Completer();
    final coordinator = await open();
    final task = (await coordinator.request(_result())).task!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(coordinator.cancel(task), isTrue);
    transport.downloadGate!.complete();
    final record = await terminal(coordinator, task);
    expect(record.status, DownloadStatus.cancelled);
    expect(manager.counts().$1, 0);
    expect(File(receiptPath(music, task)).existsSync(), isFalse);
  });

  test("worker failures are classified", () async {
    final coordinator = await open();
    transport.audioFixture = "missing-file.mp3";
    final record = await terminal(
      coordinator,
      (await coordinator.request(_result())).task!,
    );
    expect(record.status, DownloadStatus.failed);
    expect(record.error, isNotEmpty);
  });

  test(
    "startup replays a verified receipt and fails interrupted jobs",
    () async {
      await Directory(music).create(recursive: true);
      final file = p.join(music, "Recovered.mp3");
      await File("test/fixtures/artwork/cover.mp3").copy(file);
      const task = "11111111-1111-4111-8111-111111111111";
      await writeReceipt(music, task, _url, [
        {"filename": "Recovered.mp3", "sha256": await sha256File(file)},
      ]);
      store.saveDownloads([
        DownloadRecord(
          id: "22222222-2222-4222-8222-222222222222",
          url: "https://youtu.be/zzzzzzzzzzz",
          title: "Stuck",
          status: DownloadStatus.downloading,
        ),
      ]);
      final coordinator = await open();
      final recovered = coordinator.get(task)!;
      expect(recovered.status, DownloadStatus.completed);
      expect(manager.getTrack(recovered.trackIds.single).source, _url);
      expect(File(receiptPath(music, task)).existsSync(), isFalse);
      final stuck = coordinator.get("22222222-2222-4222-8222-222222222222")!;
      expect(stuck.status, DownloadStatus.failed);
      expect(stuck.error, contains("closed before"));
    },
  );

  test("a receipt whose file changed is retired, keeping the file", () async {
    await Directory(music).create(recursive: true);
    await File(p.join(music, "Other.mp3")).writeAsString("audio");
    const task = "33333333-3333-4333-8333-333333333333";
    await writeReceipt(music, task, _url, [
      {"filename": "Other.mp3", "sha256": "0" * 64},
    ]);
    await open();
    // Not provably the download's any more: neither adopted nor deleted.
    expect(manager.counts().$1, 0);
    expect(File(p.join(music, "Other.mp3")).readAsStringSync(), "audio");
    expect(File(receiptPath(music, task)).existsSync(), isFalse);
  });

  group("disk cleanup", () {
    List<String> leftovers() => [
      for (final entity in Directory(music).listSync())
        if (p.basename(entity.path).startsWith(".")) p.basename(entity.path),
    ];

    List<String> audioFiles() => [
      for (final entity in Directory(music).listSync())
        if (entity is File && entity.path.endsWith(".mp3"))
          p.basename(entity.path),
    ];

    /// A staging directory as a download leaves it when its process dies.
    Future<Directory> abandonedStaging({bool locked = true}) async {
      final staging = await Directory(music).createTemp(".melody-download-");
      if (locked) {
        await File(p.join(staging.path, ".melody-staging.lock")).create();
      }
      await File(
        p.join(staging.path, "Song.webm.part"),
      ).writeAsBytes(List.filled(4096, 1));
      await File(p.join(staging.path, "Song.webp")).writeAsBytes([1, 2]);
      return staging;
    }

    test("a failed download leaves no staging or partial files", () async {
      final coordinator = await open();
      transport.audioFixture = "missing-file.mp3";
      final record = await terminal(
        coordinator,
        (await coordinator.request(_result())).task!,
      );
      expect(record.status, DownloadStatus.failed);
      expect(leftovers(), isEmpty);
      expect(audioFiles(), isEmpty);
    });

    test("a cancelled download leaves no staging or partial files", () async {
      transport.downloadGate = Completer();
      final coordinator = await open();
      final task = (await coordinator.request(_result())).task!;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The partial stream exists while the download runs.
      expect(leftovers(), hasLength(1));
      coordinator.cancel(task);
      transport.downloadGate!.complete();
      expect(
        (await terminal(coordinator, task)).status,
        DownloadStatus.cancelled,
      );
      expect(leftovers(), isEmpty);
      expect(audioFiles(), isEmpty);
    });

    test(
      "a cancellation after the worker finished removes its output",
      () async {
        // MP3 lyrics are awaited after the worker finishes, so the job is
        // cancelled with converted audio in staging, before the move.
        final lyrics = Completer<String?>();
        final downloader = Downloader(worker, music);
        final done = Completer<DownloadResult>();
        final task = downloader.start(
          _url,
          lyrics: () => lyrics.future,
          onComplete: done.complete,
        );
        while (!transport.sent.any((frame) => frame["op"] == "download")) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        downloader.cancel(task);
        lyrics.complete(null);
        final result = await done.future.timeout(const Duration(seconds: 10));
        expect(result.status, DownloadStatus.cancelled);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(leftovers(), isEmpty);
        expect(audioFiles(), isEmpty);
      },
    );

    test("startup removes staging an earlier process abandoned", () async {
      await Directory(music).create(recursive: true);
      await abandonedStaging();
      await abandonedStaging();
      await File(p.join(music, "Mine.mp3")).writeAsString("user audio");
      await open();
      expect(leftovers(), isEmpty);
      // Files outside staging, including unregistered audio, stay.
      expect(audioFiles(), ["Mine.mp3"]);
    });

    test("unlocked staging is removed only once it goes quiet", () async {
      await Directory(music).create(recursive: true);
      final recent = await abandonedStaging(locked: false);
      final downloader = Downloader(worker, music);
      expect(await downloader.removeAbandonedStaging(), 0);
      expect(recent.existsSync(), isTrue);
      final later = DateTime.now().add(const Duration(hours: 2));
      expect(await downloader.removeAbandonedStaging(now: later), 1);
      expect(recent.existsSync(), isFalse);
    });

    test("a running download's staging is never swept", () async {
      transport.downloadGate = Completer();
      final downloader = Downloader(worker, music);
      final done = Completer<DownloadResult>();
      downloader.start(_url, onComplete: done.complete);
      while (leftovers().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final later = DateTime.now().add(const Duration(hours: 2));
      expect(await downloader.removeAbandonedStaging(now: later), 0);
      transport.downloadGate!.complete();
      expect((await done.future).status, DownloadStatus.completed);
      expect(leftovers(), hasLength(1)); // The receipt, until registration.
    });

    test(
      "staging another process holds is kept",
      () async {
        await Directory(music).create(recursive: true);
        final staging = await abandonedStaging();
        // Windows locks exclude other handles, as another process would be.
        final held = await File(
          p.join(staging.path, ".melody-staging.lock"),
        ).open(mode: FileMode.append);
        await held.lock(FileLock.exclusive);
        try {
          expect(await Downloader(worker, music).removeAbandonedStaging(), 0);
          expect(staging.existsSync(), isTrue);
        } finally {
          await held.close();
        }
        expect(await Downloader(worker, music).removeAbandonedStaging(), 1);
      },
      skip: Platform.isWindows
          ? false
          : "POSIX record locks never exclude their own process",
    );

    test("a receipt whose file never left staging is retired", () async {
      await Directory(music).create(recursive: true);
      const task = "66666666-6666-4666-8666-666666666666";
      await writeReceipt(music, task, _url, [
        {"filename": "Song.mp3", "sha256": "1" * 64},
      ]);
      await open();
      expect(File(receiptPath(music, task)).existsSync(), isFalse);
      expect(manager.counts().$1, 0);
    });

    test("an unreadable receipt is discarded without touching files", () async {
      await Directory(music).create(recursive: true);
      await File(p.join(music, "Song.mp3")).writeAsString("user audio");
      const task = "77777777-7777-4777-8777-777777777777";
      await File(receiptPath(music, task)).writeAsString("{not json");
      await open();
      expect(File(receiptPath(music, task)).existsSync(), isFalse);
      expect(File(p.join(music, "Song.mp3")).readAsStringSync(), "user audio");
    });

    test("repeated failed, cancelled, and interrupted downloads do not "
        "accumulate files", () async {
      Future<int> diskUsage() async {
        var total = 0;
        await for (final entity in Directory(music).list(recursive: true)) {
          if (entity is File) total += await entity.length();
        }
        return total;
      }

      // A distinct song per attempt, so none is answered from the library.
      SearchResult song(String letter, int round) => _result(
        url: "https://music.youtube.com/watch?v=${letter * 10}$round",
      );

      await Directory(music).create(recursive: true);
      for (var round = 0; round < 4; round++) {
        // A launch that was closed mid-download...
        await abandonedStaging();
        final coordinator = await open();
        // ...then a failure, a cancellation, and a success in this one.
        transport.audioFixture = "missing-file.mp3";
        await terminal(
          coordinator,
          (await coordinator.request(song("f", round))).task!,
        );
        transport
          ..audioFixture = "test/fixtures/artwork/cover.mp3"
          ..downloadGate = Completer();
        final cancelled = (await coordinator.request(song("c", round))).task!;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        coordinator.cancel(cancelled);
        transport.downloadGate!.complete();
        transport.downloadGate = null;
        await terminal(coordinator, cancelled);
        final record = await terminal(
          coordinator,
          (await coordinator.request(song("s", round))).task!,
        );
        expect(record.status, DownloadStatus.completed);
        // Every success has the same bytes, so the library keeps one file;
        // nothing else survives.
        expect(leftovers(), isEmpty);
        expect(audioFiles(), hasLength(1));
      }
      final usage = await diskUsage();
      await abandonedStaging();
      await open();
      expect(await diskUsage(), usage);
    });
  });

  test("batches deduplicate by media identity", () async {
    final coordinator = await open();
    final batch = await coordinator.startUrls([
      _url,
      "https://youtu.be/abcdefghijk",
      "https://music.youtube.com/watch?v=lmnopqrstuv",
    ]);
    expect(batch.size, 2);
    expect(batch.tasks, hasLength(2));
    final records = coordinator.list();
    expect(records.map((record) => record.batchPosition), [1, 2]);
    expect(records.map((record) => record.title), [
      "Song 1 of 2",
      "Song 2 of 2",
    ]);
    for (final task in batch.tasks) {
      final record = await terminal(coordinator, task);
      // Batch songs adopt the title yt-dlp resolved, in the library too.
      expect(record.title, "Resolved title");
      expect(manager.getTrack(record.trackIds.single).title, "Resolved title");
    }
    expect(
      () => coordinator.startUrls(["https://example.com/song"]),
      throwsArgumentError,
    );
  });

  test("retrying a batch song still resolves its placeholder title", () async {
    // Scheduling failed, so yt-dlp never reported the song's title.
    store.saveDownloads([
      DownloadRecord(
        id: "44444444-4444-4444-8444-444444444444",
        url: _url,
        title: "Song 1 of 3",
        status: DownloadStatus.failed,
        batchId: "55555555-5555-4555-8555-555555555555",
        batchPosition: 1,
        batchSize: 3,
      ),
    ]);
    final coordinator = await open();
    final task = await coordinator.retry(
      "44444444-4444-4444-8444-444444444444",
    );
    final record = await terminal(coordinator, task);
    expect(record.status, DownloadStatus.completed);
    expect(record.title, "Resolved title");
    expect(manager.getTrack(record.trackIds.single).title, "Resolved title");
  });

  test("URL extraction keeps order and strips punctuation", () {
    expect(
      extractDownloadUrls(
        "- https://youtu.be/a1, and https://youtu.be/b2.\nhttps://youtu.be/a1",
      ),
      ["https://youtu.be/a1", "https://youtu.be/b2"],
    );
  });

  test("URL extraction drops brackets the URL did not open", () {
    expect(
      extractDownloadUrls(
        "see (https://youtu.be/a1), [https://youtu.be/b2] and "
        "https://example.test/wiki/Song_(band)",
      ),
      [
        "https://youtu.be/a1",
        "https://youtu.be/b2",
        "https://example.test/wiki/Song_(band)",
      ],
    );
  });

  group("lyrics", () {
    const lyrics = Lyrics([
      LyricLine("Hello", startMs: 0),
      LyricLine("World", startMs: 1500),
    ]);

    Future<DownloadCoordinator> openWithLyrics(
      Future<Lyrics?> Function(String videoId) fetch,
    ) => DownloadCoordinator.open(
      manager,
      store,
      store.settings,
      worker,
      thumbnails: thumbnails,
      lyrics: LyricsLibrary(p.join(root.path, "lyrics"), fetch),
    );

    test("are embedded in MP3s before verification and hashing", () async {
      final coordinator = await openWithLyrics((_) async => lyrics);
      final task = (await coordinator.request(_result())).task!;
      final record = await terminal(coordinator, task);

      expect(record.status, DownloadStatus.completed);
      final id = record.trackIds.single;
      final path = manager.trackPath(id);
      expect(readEmbeddedLyricsSync(path), "[00:00.00]Hello\n[00:01.50]World");
      expect(readEmbeddedArtworkSync(path), isNotEmpty);
      expect(await manager.checkTrackIntegrity(id), isNull);
      final download = transport.sent.singleWhere(
        (frame) => frame["op"] == "download",
      );
      expect(download.containsKey("metadata"), isFalse);
    });

    test("are handed to FFmpeg for other formats", () async {
      store.saveSettings(store.settings..audioFormat = "m4a");
      transport
        ..audioFixture = "test/fixtures/artwork/cover.m4a"
        ..downloadedName = "Song.m4a";
      final coordinator = await openWithLyrics((_) async => lyrics);
      final task = (await coordinator.request(_result())).task!;
      expect(
        (await terminal(coordinator, task)).status,
        DownloadStatus.completed,
      );
      final download = transport.sent.singleWhere(
        (frame) => frame["op"] == "download",
      );
      expect(download["metadata"], {
        "lyrics": "[00:00.00]Hello\n[00:01.50]World",
      });
    });

    test("never fail a download", () async {
      final coordinator = await openWithLyrics(
        (_) async => throw StateError("lyrics service down"),
      );
      final task = (await coordinator.request(_result())).task!;
      final record = await terminal(coordinator, task);
      expect(record.status, DownloadStatus.completed);
      expect(
        readEmbeddedLyricsSync(manager.trackPath(record.trackIds.single)),
        "",
      );
    });
  });

  group("download formats", () {
    Map<String, Object?> extractAudio(AppSettings settings) =>
        (downloadOptions(settings, const {})["postprocessors"]! as List).first
            as Map<String, Object?>;

    test("lossless codecs ignore the bitrate", () {
      final settings = AppSettings(downloadDirectory: music)
        ..audioFormat = "flac"
        ..audioQuality = "192";
      expect(extractAudio(settings), containsPair("preferredcodec", "flac"));
      expect(extractAudio(settings), containsPair("preferredquality", "0"));
      settings.audioFormat = "vorbis";
      expect(extractAudio(settings), containsPair("preferredquality", "192"));
    });

    test("codecs map to the extension yt-dlp writes", () {
      expect(DownloadFormat.parse("vorbis").extension, ".ogg");
      expect(DownloadFormat.parse("alac").extension, ".m4a");
    });

    test("an unknown saved format falls back to MP3", () {
      final settings = AppSettings.fromJson({
        "audio_format": "wma",
      }, defaultDownloadDirectory: music);
      expect(settings.audioFormat, "mp3");
    });
  });
}
