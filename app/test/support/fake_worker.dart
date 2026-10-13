import "dart:async";
import "dart:io";

import "package:melody/worker/transport.dart";
import "package:path/path.dart" as p;

/// Answers worker frames in-process. Downloads copy [audioFixture] into the
/// staging directory, like yt-dlp writing its final file; `ytmusic` calls
/// answer from [ytMusicResults], keyed by method name.
class FakeWorkerTransport implements WorkerTransport {
  FakeWorkerTransport({
    this.audioFixture = "test/fixtures/artwork/cover.mp3",
    this.extractResult,
    Map<String, Object?>? ytMusicResults,
  }) : ytMusicResults = ytMusicResults ?? defaultYtMusicResults() {
    scheduleMicrotask(
      () => _frames.add({
        "event": "ready",
        "status": {
          "packages": {
            "yt-dlp": {
              "available": true,
              "active_version": "2026.8.19",
              "active_source": "bundled",
              "errors": [],
            },
            "ytmusicapi": {
              "available": true,
              "active_version": "1.12.3",
              "active_source": "bundled",
              "errors": [],
            },
          },
        },
      }),
    );
  }

  /// A song search, a watch playlist whose track has lyrics, and timed
  /// lyrics.
  static Map<String, Object?> defaultYtMusicResults() => {
    "search": [
      {
        "videoId": "abcdefghijk",
        "title": "Song",
        "artists": [
          {"name": "Artist", "id": "UC1"},
          {"name": "Guest", "id": null},
        ],
        "duration_seconds": 185,
        "thumbnails": [
          {
            "url": "https://lh3.googleusercontent.com/a=w60-h60-l90-rj",
            "width": 60,
            "height": 60,
          },
          {
            "url": "https://lh3.googleusercontent.com/a=w120-h120-l90-rj",
            "width": 120,
            "height": 120,
          },
        ],
      },
      {"videoId": null, "title": "Unavailable"},
    ],
    "get_watch_playlist": {
      "tracks": [
        {
          "videoId": "abcdefghijk",
          "title": "Song",
          "artists": [
            {"name": "Artist"},
          ],
          "length": "3:05",
        },
      ],
      "lyrics": "MPLYt_fake",
    },
    "get_lyrics": {
      "lyrics": [
        {"text": "First line", "start_time": 0, "end_time": 1500, "id": 1},
        {"text": "Second line", "start_time": 1500, "end_time": 3000, "id": 2},
      ],
      "source": "Source: Test",
      "hasTimestamps": true,
    },
  };

  /// Replies to `ytmusic` calls; a missing method answers null.
  final Map<String, Object?> ytMusicResults;

  /// Makes every `ytmusic` call fail like an unreachable network.
  bool offline = false;

  final StreamController<Map<String, Object?>> _frames =
      StreamController.broadcast();
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

  final Completer<String?> _stopped = Completer();

  @override
  Stream<Map<String, Object?>> get frames => _frames.stream;

  @override
  Future<String?> get stopped => _stopped.future;

  /// Simulates the interpreter dying or never starting.
  void crash(String reason) {
    if (!_stopped.isCompleted) _stopped.complete(reason);
  }

  @override
  void send(Map<String, Object?> frame) {
    sent.add(frame);
    unawaited(
      _handle(frame).catchError((Object error) {
        _frames.add({
          "id": frame["id"],
          "ok": false,
          "error": {
            "message": "$error",
            "types": [error.runtimeType.toString()],
          },
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
        final directory = "${frame["directory"]}";
        // yt-dlp streams into a .part file before converting.
        if (p.basename(directory).startsWith("job-") &&
            await Directory(directory).exists()) {
          await File(
            p.join(directory, "$downloadedName.webm.part"),
          ).writeAsBytes(List.filled(1024, 7));
        }
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
          _frames.add({
            "id": id,
            "ok": true,
            "result": {"cancelled": true},
          });
          return;
        }
        await File(audioFixture).copy(p.join(directory, downloadedName));
        if (writeThumbnail) {
          await File(
            p.join(directory, "Song.jpg"),
          ).writeAsBytes([0xff, 0xd8, 0xff, 0xe0, 1]);
        }
        _frames.add({
          "event": "progress",
          "task": task,
          "status": "processing",
        });
        _frames.add({
          "id": id,
          "ok": true,
          "result": {"cancelled": false},
        });
      case "tag":
        await File("${frame["source"]}").copy("${frame["target"]}");
        _frames.add({"id": id, "ok": true, "result": null});
      case "ytmusic":
        if (offline) {
          _frames.add({
            "id": id,
            "ok": false,
            "error": {
              "message": "Max retries exceeded with url: /youtubei/v1/browse",
              "types": ["ConnectionError"],
            },
          });
        } else {
          _frames.add({
            "id": id,
            "ok": true,
            "result": ytMusicResults[frame["method"]],
          });
        }
      case "latest_release":
        _frames.add({
          "id": id,
          "ok": true,
          "result": {
            "version": frame["package"] == "ytmusicapi" ? "1.13.0" : "2026.9.1",
          },
        });
    }
  }

  @override
  Future<void> close() async {
    if (!_stopped.isCompleted) _stopped.complete(null);
    await _frames.close();
  }
}
