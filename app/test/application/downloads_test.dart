import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/models.dart";
import "package:melody/application/store.dart";
import "package:melody/application/thumbnails.dart";
import "package:melody/core/downloader/receipts.dart";
import "package:melody/core/library/manager.dart";
import "package:melody/core/storage.dart";
import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

import "../support/fake_worker.dart";

const _url = "https://music.youtube.com/watch?v=abcdefghijk";

SearchResult _result({String url = _url, String thumbnail = "https://i.ytimg.com/vi/abcdefghijk/hq.jpg"}) =>
    SearchResult(
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
    store = ApplicationStore.open(p.join(root.path, "state.db"), defaultDownloadDirectory: music);
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
  Future<DownloadRecord> terminal(DownloadCoordinator coordinator, String task) {
    const statuses = {"completed", "failed", "cancelled"};
    final existing = coordinator.get(task);
    if (existing != null && statuses.contains(existing.status) && published.contains(task)) {
      return Future.value(existing);
    }
    final completer = Completer<DownloadRecord>();
    coordinator.onRecord = (record) {
      published.add(record.id);
      if (record.id == task && statuses.contains(record.status) && !completer.isCompleted) {
        completer.complete(record);
      }
    };
    return completer.future.timeout(const Duration(seconds: 10));
  }

  test("a completed download is verified, registered, and acknowledged", () async {
    final coordinator = await open();
    final task = await coordinator.request(_result());
    expect(task, isNotNull);
    expect(coordinator.isSourceActive("https://youtu.be/abcdefghijk"), isTrue);

    final record = await terminal(coordinator, task!);
    expect(record.status, "completed");
    expect(record.trackIds, hasLength(1));
    final track = manager.getTrack(record.trackIds.single);
    expect(track.title, "Search title");
    expect(track.source, _url);
    expect(File(manager.trackPath(track.id)).existsSync(), isTrue);
    expect(p.dirname(manager.trackPath(track.id)), p.normalize(p.absolute(music)));
    final details = store.trackDetails(track.id);
    expect(details.uploader, "Uploader");
    expect(details.duration, 200);
    // The cache is derived from the verified embedded cover.
    expect(thumbnails.cachedPath(_result().thumbnail), isNotNull);
    expect(File(receiptPath(music, task)).existsSync(), isFalse);
    expect(coordinator.activeCount(), 0);
    // No staging directory survives.
    expect(
      Directory(music).listSync().where((item) => p.basename(item.path).startsWith(".melody-download-")),
      isEmpty,
    );
    // The intact track is reused instead of downloading again.
    expect(await coordinator.request(_result()), isNull);
  });

  test("a second request joins the active download", () async {
    transport.downloadGate = Completer();
    final coordinator = await open();
    final (first, firstOwned) = await coordinator.requestWithOwnership(_result());
    final (second, secondOwned) = await coordinator.requestWithOwnership(
      _result(url: "https://www.youtube.com/watch?v=abcdefghijk"),
    );
    expect(second, first);
    expect(firstOwned, isTrue);
    expect(secondOwned, isFalse);
    transport.downloadGate!.complete();
    expect((await terminal(coordinator, first!)).status, "completed");
    expect(transport.sent.where((frame) => frame["op"] == "download"), hasLength(1));
  });

  test("missing embedded artwork fails before the file is committed", () async {
    // yt-dlp retained a thumbnail sidecar, but the audio has no cover.
    transport.audioFixture = "test/fixtures/artwork/no_cover.mp3";
    final coordinator = await open();
    final record = await terminal(coordinator, (await coordinator.request(_result()))!);
    expect(record.status, "failed");
    expect(record.errorKind, "postprocessing");
    expect(manager.counts().$1, 0);
    expect(Directory(music).listSync().whereType<File>().where((f) => f.path.endsWith(".mp3")), isEmpty);
  });

  test("audio without any thumbnail needs no artwork", () async {
    transport.audioFixture = "test/fixtures/artwork/no_cover.mp3";
    transport.writeThumbnail = false;
    final coordinator = await open();
    final record = await terminal(
      coordinator,
      (await coordinator.request(_result(thumbnail: "")))!,
    );
    expect(record.status, "completed");
  });

  test("cancelling a running download keeps nothing", () async {
    transport.downloadGate = Completer();
    final coordinator = await open();
    final task = (await coordinator.request(_result()))!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(coordinator.cancel(task), isTrue);
    transport.downloadGate!.complete();
    final record = await terminal(coordinator, task);
    expect(record.status, "cancelled");
    expect(manager.counts().$1, 0);
    expect(File(receiptPath(music, task)).existsSync(), isFalse);
  });

  test("worker failures are classified", () async {
    final coordinator = await open();
    transport.audioFixture = "missing-file.mp3";
    final record = await terminal(coordinator, (await coordinator.request(_result()))!);
    expect(record.status, "failed");
    expect(record.error, isNotEmpty);
  });

  test("startup replays a verified receipt and fails interrupted jobs", () async {
    await Directory(music).create(recursive: true);
    final file = p.join(music, "Recovered.mp3");
    await File("test/fixtures/artwork/cover.mp3").copy(file);
    const task = "11111111-1111-4111-8111-111111111111";
    await writeReceipt(music, task, _url, [
      {"filename": "Recovered.mp3", "sha256": await sha256File(file)},
    ]);
    store.saveDownloads([
      DownloadRecord(id: "22222222-2222-4222-8222-222222222222", url: "https://youtu.be/zzzzzzzzzzz", title: "Stuck", status: "downloading"),
    ]);
    final coordinator = await open();
    final recovered = coordinator.get(task)!;
    expect(recovered.status, "completed");
    expect(manager.getTrack(recovered.trackIds.single).source, _url);
    expect(File(receiptPath(music, task)).existsSync(), isFalse);
    final stuck = coordinator.get("22222222-2222-4222-8222-222222222222")!;
    expect(stuck.status, "failed");
    expect(stuck.error, contains("closed before"));
  });

  test("a corrupt receipt is preserved for repair", () async {
    await Directory(music).create(recursive: true);
    await File(p.join(music, "Other.mp3")).writeAsString("audio");
    const task = "33333333-3333-4333-8333-333333333333";
    await writeReceipt(music, task, _url, [
      {"filename": "Other.mp3", "sha256": "0" * 64},
    ]);
    await open();
    expect(manager.counts().$1, 0);
    expect(File(receiptPath(music, task)).existsSync(), isTrue);
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
    expect(records.map((record) => record.title), ["Song 1 of 2", "Song 2 of 2"]);
    for (final task in batch.tasks) {
      final record = await terminal(coordinator, task);
      // Batch songs adopt the title yt-dlp resolved.
      expect(record.title, "Resolved title");
    }
    expect(() => coordinator.startUrls(["https://example.com/song"]), throwsArgumentError);
  });

  test("URL extraction keeps order and strips punctuation", () {
    expect(
      extractDownloadUrls("- https://youtu.be/a1, and https://youtu.be/b2.\nhttps://youtu.be/a1"),
      ["https://youtu.be/a1", "https://youtu.be/b2"],
    );
  });
}
