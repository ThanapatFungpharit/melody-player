import "../support/temp.dart";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/scrobbling.dart";
import "package:melody/application/store.dart";
import "package:melody/core/listenbrainz.dart";
import "package:path/path.dart" as p;

/// A service whose answers the test sets.
class _FakeService implements ScrobbleService {
  final submitted = <List<Map<String, Object?>>>[];
  final accepted = <int>[];
  ScrobbleFailure? failure;

  /// Listens (by `listened_at`) refused as invalid.
  final refused = <int>{};
  String user = "listener";
  bool tokenValid = true;

  @override
  String get id => "listenbrainz";

  @override
  String get label => "ListenBrainz";

  @override
  Future<String> validate(String token) async {
    if (!tokenValid) {
      throw const ScrobbleFailure(ScrobbleFailureKind.auth, "bad token");
    }
    return user;
  }

  @override
  Future<void> submit(String token, List<Map<String, Object?>> listens) async {
    submitted.add(listens);
    if (failure case final failure?) throw failure;
    if (listens.any((listen) => refused.contains(listen["listened_at"]))) {
      throw const ScrobbleFailure(ScrobbleFailureKind.rejected, "invalid");
    }
    accepted.addAll([
      for (final listen in listens) listen["listened_at"]! as int,
    ]);
  }
}

Listen _listen(int second, {String artist = "Artist", String album = ""}) =>
    Listen(
      trackId: "t$second",
      startedAt: DateTime.fromMillisecondsSinceEpoch(second * 1000),
      listenedMs: 120000,
      durationMs: 200000,
      title: "Song $second",
      artist: artist,
      album: album,
      source: "https://music.youtube.com/watch?v=abcdefghijk",
    );

void main() {
  late Directory root;
  late ApplicationStore store;
  late _FakeService service;

  ApplicationStore open() => ApplicationStore.open(
    p.join(root.path, "library.db"),
    defaultDownloadDirectory: p.join(root.path, "music"),
  );

  Scrobbler scrobbler({Duration backoff = const Duration(hours: 1)}) =>
      Scrobbler(store, service, backoff: (_) => backoff, batchSize: 3);

  setUp(() async {
    root = await createTestDirectory("melody-scrobbling");
    store = open();
    service = _FakeService();
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test("the ListenBrainz form names the track, album, and source", () {
    final listen = listenBrainzListen(_listen(1000, album: "LP"))!;
    expect(listen["listened_at"], 1000);
    final metadata = listen["track_metadata"]! as Map;
    expect(metadata["artist_name"], "Artist");
    expect(metadata["track_name"], "Song 1000");
    expect(metadata["release_name"], "LP");
    final info = metadata["additional_info"]! as Map;
    expect(info["duration_ms"], 200000);
    expect(info["origin_url"], "https://music.youtube.com/watch?v=abcdefghijk");
    expect(listenBrainzListen(_listen(1, artist: "")), isNull);
    expect(listenBrainzListen(_listen(1, artist: "Unknown artist")), isNull);
  });

  test("nothing is queued until an account is connected", () async {
    final scrobbles = scrobbler()..add(_listen(1));
    await scrobbles.sendPending();
    expect(scrobbles.pending, 0);
    expect(service.submitted, isEmpty);
    scrobbles.dispose();
  });

  test("connecting checks the token and keeps it across a restart", () async {
    final scrobbles = scrobbler();
    service.tokenValid = false;
    await expectLater(
      scrobbles.connect("bad"),
      throwsA(isA<ScrobbleFailure>()),
    );
    expect(scrobbles.state, ScrobbleState.disconnected);
    await expectLater(scrobbles.connect("  "), throwsFormatException);

    service.tokenValid = true;
    await scrobbles.connect(" token ");
    expect(scrobbles.state, ScrobbleState.connected);
    expect(scrobbles.username, "listener");
    scrobbles.dispose();

    await store.close();
    store = open();
    final restored = scrobbler();
    expect(restored.state, ScrobbleState.connected);
    expect(restored.username, "listener");
    restored.dispose();
  });

  test("listens are sent in batches, oldest first, then removed", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.unavailable,
      "offline",
    );
    for (final second in [5, 1, 4, 2, 3]) {
      scrobbles.add(_listen(second));
    }
    await scrobbles.sendPending();
    expect(scrobbles.pending, 5);

    service.failure = null;
    service.submitted.clear();
    await scrobbles.sendPending();
    expect(service.submitted.map((batch) => batch.length), [3, 2]);
    expect(service.accepted, [1, 2, 3, 4, 5]);
    expect(scrobbles.pending, 0);
    expect(scrobbles.lastError, isNull);
    scrobbles.dispose();
  });

  test("while offline, listens wait across a restart and go once it is "
      "back", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.unavailable,
      "offline",
    );
    scrobbles.add(_listen(10));
    await scrobbles.sendPending();
    expect(scrobbles.waiting, isTrue);
    expect(scrobbles.lastError, "offline");
    expect(store.pendingScrobbles("listenbrainz").single.attempts, 1);
    scrobbles.dispose();

    await store.close();
    store = open();
    service.failure = null;
    final restored = scrobbler();
    expect(restored.pending, 1);
    await restored.sendPending();
    expect(service.accepted, [10]);
    expect(restored.pending, 0);
    restored.dispose();
  });

  test("a failed attempt is tried again after the backoff", () async {
    final scrobbles = scrobbler(backoff: const Duration(milliseconds: 20));
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.unavailable,
      "offline",
    );
    scrobbles.add(_listen(10));
    await scrobbles.sendPending();
    service.failure = null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.accepted, [10]);
    expect(scrobbles.waiting, isFalse);
    scrobbles.dispose();
  });

  test("Melody coming back on screen retries at once", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.rateLimited,
      "slow down",
      retryAfter: Duration(hours: 1),
    );
    scrobbles.add(_listen(10));
    await scrobbles.sendPending();
    expect(scrobbles.waiting, isTrue);
    service.failure = null;
    scrobbles.retryNow();
    await scrobbles.sendPending();
    expect(service.accepted, [10]);
    scrobbles.dispose();
  });

  test("the same listen is queued once", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.unavailable,
      "offline",
    );
    scrobbles
      ..add(_listen(10))
      ..add(_listen(10));
    await scrobbles.sendPending();
    expect(scrobbles.pending, 1);
    scrobbles.dispose();
  });

  test("a refused batch is split and only the bad listen dropped", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.unavailable,
      "offline",
    );
    for (final second in [1, 2, 3]) {
      scrobbles.add(_listen(second));
    }
    await scrobbles.sendPending();
    service
      ..failure = null
      ..refused.add(2);
    await scrobbles.sendPending();
    expect(service.accepted, [1, 3]);
    expect(scrobbles.pending, 0);
    scrobbles.dispose();
  });

  test("a revoked token stops sending but keeps the queue", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(ScrobbleFailureKind.auth, "nope");
    scrobbles.add(_listen(1));
    await scrobbles.sendPending();
    expect(scrobbles.state, ScrobbleState.needsSignIn);
    // Listens keep queueing meanwhile.
    scrobbles.add(_listen(2));
    expect(scrobbles.pending, 2);
    service.submitted.clear();
    await scrobbles.sendPending();
    expect(service.submitted, isEmpty);

    service.failure = null;
    await scrobbles.connect("new token");
    await scrobbles.sendPending();
    expect(service.accepted, [1, 2]);
    scrobbles.dispose();
  });

  test("disconnecting forgets the token and what was waiting", () async {
    final scrobbles = scrobbler();
    await scrobbles.connect("token");
    service.failure = const ScrobbleFailure(
      ScrobbleFailureKind.unavailable,
      "offline",
    );
    scrobbles.add(_listen(1));
    await scrobbles.sendPending();
    scrobbles.disconnect();
    expect(scrobbles.state, ScrobbleState.disconnected);
    expect(scrobbles.pending, 0);
    expect(store.get("scrobbling"), isNull);
    scrobbles.dispose();
  });

  test("the queue keeps only the newest listens", () {
    for (var second = 0; second < 5; second++) {
      store.enqueueScrobble("other", second, {"listened_at": second});
    }
    expect(store.enqueueScrobble("other", 4, const {}), isFalse);
    expect(store.pendingScrobbleCount("other"), 5);
    expect(ApplicationStore.maxQueuedScrobbles, greaterThan(1000));
  });

  group("ListenBrainzClient", () {
    late HttpServer server;
    late List<(String, String?, Object?)> requests;
    late Future<void> Function(HttpRequest request) reply;

    setUp(() async {
      requests = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add((
          "${request.method} ${request.uri.path}",
          request.headers.value(HttpHeaders.authorizationHeader),
          body.isEmpty ? null : jsonDecode(body),
        ));
        await reply(request);
      });
    });

    tearDown(() => server.close(force: true));

    ListenBrainzClient client() => ListenBrainzClient(
      base: Uri.http("127.0.0.1:${server.port}"),
      timeout: const Duration(seconds: 5),
    );

    Future<void> json(HttpRequest request, int status, Object body) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }

    test("validates a token and names its user", () async {
      reply = (request) =>
          json(request, 200, {"valid": true, "user_name": "someone"});
      expect(await client().validate("tok"), "someone");
      expect(requests.single.$1, "GET /1/validate-token");
      expect(requests.single.$2, "Token tok");
    });

    test("an invalid token is an authentication failure", () async {
      reply = (request) => json(request, 200, {"valid": false});
      await expectLater(
        client().validate("tok"),
        throwsA(
          isA<ScrobbleFailure>().having(
            (failure) => failure.kind,
            "kind",
            ScrobbleFailureKind.auth,
          ),
        ),
      );
    });

    test("submits one listen as single and several as an import", () async {
      reply = (request) => json(request, 200, {"status": "ok"});
      await client().submit("tok", [
        {"listened_at": 1},
      ]);
      await client().submit("tok", [
        {"listened_at": 1},
        {"listened_at": 2},
      ]);
      expect((requests[0].$3! as Map)["listen_type"], "single");
      expect((requests[1].$3! as Map)["listen_type"], "import");
      expect((requests[1].$3! as Map)["payload"], hasLength(2));
    });

    for (final (status, kind) in [
      (401, ScrobbleFailureKind.auth),
      (400, ScrobbleFailureKind.rejected),
      (429, ScrobbleFailureKind.rateLimited),
      (503, ScrobbleFailureKind.unavailable),
    ]) {
      test("HTTP $status is classified as ${kind.name}", () async {
        reply = (request) async {
          request.response.headers.set("X-RateLimit-Reset-In", "7");
          await json(request, status, {"error": "nope"});
        };
        try {
          await client().submit("tok", [
            {"listened_at": 1},
          ]);
          fail("Expected a failure");
        } on ScrobbleFailure catch (failure) {
          expect(failure.kind, kind);
          if (kind == ScrobbleFailureKind.rateLimited) {
            expect(failure.retryAfter, const Duration(seconds: 7));
          }
        }
      });
    }

    test("no connection is a temporary failure", () async {
      final port = server.port;
      await server.close(force: true);
      final unreachable = ListenBrainzClient(
        base: Uri.http("127.0.0.1:$port"),
        timeout: const Duration(seconds: 5),
      );
      await expectLater(
        unreachable.submit("tok", [
          {"listened_at": 1},
        ]),
        throwsA(
          isA<ScrobbleFailure>().having(
            (failure) => failure.kind,
            "kind",
            ScrobbleFailureKind.unavailable,
          ),
        ),
      );
    });
  });
}
