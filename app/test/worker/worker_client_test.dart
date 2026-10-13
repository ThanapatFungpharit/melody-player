import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/errors.dart";
import "package:melody/worker/transport.dart";
import "package:melody/worker/worker_client.dart";

import "../support/fake_worker.dart";

void main() {
  test("the ready event carries a typed runtime status", () async {
    final worker = WorkerClient(FakeWorkerTransport());
    final status = await worker.ready;
    expect(status.ytDlp.available, isTrue);
    expect(status.ytDlp.activeVersion, "2026.8.19");
    expect(status.ytDlp.bundled, isTrue);
    expect(status.ytMusic.available, isTrue);
    expect(status.ytMusic.activeVersion, "1.12.3");
    await worker.close();
  });

  test(
    "a worker that stops fails waiting requests instead of hanging",
    () async {
      final transport = FakeWorkerTransport()..downloadGate = Completer();
      final worker = WorkerClient(transport);
      await worker.ready;
      final download = worker.download(
        task: "t",
        url: "https://music.youtube.com/watch?v=abcdefghijk",
        directory: ".",
        options: const {},
        onProgress: (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      transport.crash("Python could not start: missing main.py");

      await expectLater(
        download,
        throwsA(
          isA<WorkerFailure>().having(
            (e) => e.message,
            "message",
            contains("main.py"),
          ),
        ),
      );
      await expectLater(
        worker.extract("query", const {}),
        throwsA(isA<WorkerFailure>()),
      );
      expect(
        transport.sent,
        hasLength(1),
        reason: "a stopped worker receives no frames",
      );
      await worker.close();
    },
  );

  test("a worker that never starts reports itself unavailable", () async {
    final worker = WorkerClient(
      UnavailableTransport("Python could not start: no bridge"),
    );
    final status = await worker.ready;
    expect(status.ytDlp.available, isFalse);
    expect(status.ytMusic.available, isFalse);
    expect(status.ytDlp.errors, ["Python could not start: no bridge"]);
    await expectLater(
      worker.latestReleaseVersion(ytDlpPackage),
      throwsA(isA<WorkerFailure>()),
    );
  });

  test("malformed replies still complete their requests", () async {
    final transport = _ScriptedTransport();
    final worker = WorkerClient(transport);
    final progress = <WorkerProgress>[];
    final download = worker.download(
      task: "t",
      url: "https://music.youtube.com/watch?v=abcdefghijk",
      directory: ".",
      options: const {},
      onProgress: progress.add,
    );
    final latest = worker.latestReleaseVersion(ytDlpPackage);
    transport
      ..reply({"event": "ready", "status": "not an object"})
      ..reply({
        "event": "progress",
        "task": "t",
        "downloaded_bytes": "5",
        "total_bytes": 10.5,
        "title": 7,
      })
      ..reply({"id": 1, "ok": false, "error": "boom"})
      ..reply({
        "id": 2,
        "ok": true,
        "result": {"version": 3},
      });
    expect((await worker.ready).ytDlp.available, isFalse);
    expect(progress.single.downloadedBytes, 0);
    expect(progress.single.totalBytes, 10);
    expect(progress.single.title, "");
    await expectLater(
      download,
      throwsA(
        isA<WorkerFailure>().having(
          (e) => e.message,
          "message",
          "The worker failed",
        ),
      ),
    );
    expect(await latest, isNull);
    await worker.close();
  });

  test("a request that cannot be sent fails instead of hanging", () async {
    final worker = WorkerClient(_ScriptedTransport()..failSends = true);
    await expectLater(
      worker.extract("query", const {}),
      throwsA(isA<WorkerFailure>()),
    );
    await worker.close();
  });
}

class _ScriptedTransport implements WorkerTransport {
  final _frames = StreamController<Map<String, Object?>>(sync: true);
  final _stopped = Completer<String?>();
  bool failSends = false;

  void reply(Map<String, Object?> frame) => _frames.add(frame);

  @override
  Stream<Map<String, Object?>> get frames => _frames.stream;

  @override
  Future<String?> get stopped => _stopped.future;

  @override
  void send(Map<String, Object?> frame) {
    if (failSends) throw StateError("StreamSink is closed");
  }

  @override
  Future<void> close() async {
    if (!_stopped.isCompleted) _stopped.complete(null);
    await _frames.close();
  }
}
