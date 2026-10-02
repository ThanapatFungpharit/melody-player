import "dart:async";
import "dart:io";

import "package:melody/worker/worker_client.dart";
import "package:path/path.dart" as p;

/// Answers worker frames in-process. Downloads copy [audioFixture] into the
/// staging directory, like yt-dlp writing its final file.
class FakeWorkerTransport implements WorkerTransport {
  FakeWorkerTransport({
    this.audioFixture = "test/fixtures/artwork/cover.mp3",
    this.extractResult,
  }) {
    scheduleMicrotask(() => _frames.add({
      "event": "ready",
      "status": {"active_version": "2026.8.19", "active_source": "bundled", "errors": []},
    }));
  }

  final StreamController<Map<String, Object?>> _frames = StreamController.broadcast();
  String audioFixture;
  Map<String, Object?>? extractResult;
  Map<String, Object?>? extractError;
  final List<Map<String, Object?>> sent = [];

  /// Downloads wait on this gate when set.
  Completer<void>? downloadGate;
  final Set<String> _cancelled = {};
  String downloadedName = "Song.mp3";

  /// Leave a thumbnail sidecar in staging, as yt-dlp does with
  /// `writethumbnail` and `already_have_thumbnail`.
  bool writeThumbnail = true;

  @override
  Stream<Map<String, Object?>> get frames => _frames.stream;

  @override
  void send(Map<String, Object?> frame) {
    sent.add(frame);
    unawaited(
      _handle(frame).catchError((Object error) {
        _frames.add({
          "id": frame["id"],
          "ok": false,
          "error": {"message": "$error", "types": [error.runtimeType.toString()]},
        });
      }),
    );
  }

  Future<void> _handle(Map<String, Object?> frame) async {
    final id = frame["id"];
    switch (frame["op"]) {
      case "extract":
        if (extractError != null) {
          _frames.add({"id": id, "ok": false, "error": extractError});
        } else {
          _frames.add({"id": id, "ok": true, "result": extractResult});
        }
      case "cancel":
        _cancelled.add("${frame["task"]}");
        _frames.add({"id": id, "ok": true, "result": true});
      case "download":
        final task = "${frame["task"]}";
        _frames.add({
          "event": "progress",
          "task": task,
          "status": "downloading",
          "downloaded_bytes": 5,
          "total_bytes": 10,
          "title": "Resolved title",
          "uploader": "Resolved artist",
        });
        await downloadGate?.future;
        if (_cancelled.contains(task)) {
          _frames.add({"id": id, "ok": true, "result": {"cancelled": true}});
          return;
        }
        final directory = "${frame["directory"]}";
        await File(audioFixture).copy(p.join(directory, downloadedName));
        if (writeThumbnail) {
          await File(p.join(directory, "Song.jpg")).writeAsBytes([0xff, 0xd8, 0xff, 0xe0, 1]);
        }
        _frames.add({"event": "progress", "task": task, "status": "processing"});
        _frames.add({"id": id, "ok": true, "result": {"cancelled": false}});
      case "status":
        _frames.add({"id": id, "ok": true, "result": {"active_version": "2026.8.19"}});
      case "latest_release":
        _frames.add({"id": id, "ok": true, "result": {"version": "2026.9.1"}});
    }
  }

  @override
  Future<void> close() => _frames.close();
}
