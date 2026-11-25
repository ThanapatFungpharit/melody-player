/// A small client for the ListenBrainz API: validating a user token and
/// submitting listens. It holds no queue or retry policy; failures are
/// classified so the caller can decide (`application/scrobbling.dart`).
library;

import "dart:async";
import "dart:convert";
import "dart:io";

/// Why a submission failed.
enum ScrobbleFailureKind {
  /// The token is wrong or was revoked: nothing will work until the
  /// listener connects again.
  auth,

  /// Too many requests; try again after [ScrobbleFailure.retryAfter].
  rateLimited,

  /// The service refused these listens as invalid; sending them again
  /// will not help.
  rejected,

  /// No connection, a timeout, or a server error: try again later.
  unavailable,
}

class ScrobbleFailure implements Exception {
  const ScrobbleFailure(this.kind, this.message, {this.retryAfter});

  final ScrobbleFailureKind kind;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

/// A scrobbling service.
abstract class ScrobbleService {
  /// The name stored with queued listens.
  String get id;
  String get label;

  /// The user name [token] belongs to; throws a [ScrobbleFailure].
  Future<String> validate(String token);

  /// Submits [listens], in the service's own form; throws a
  /// [ScrobbleFailure].
  Future<void> submit(String token, List<Map<String, Object?>> listens);
}

/// ListenBrainz (<https://listenbrainz.org>), authenticated with the user
/// token from the listener's ListenBrainz settings.
class ListenBrainzClient implements ScrobbleService {
  ListenBrainzClient({
    Uri? base,
    HttpClient Function()? client,
    this.timeout = const Duration(seconds: 20),
  }) : base = base ?? Uri.https("api.listenbrainz.org"),
       _client = client ?? HttpClient.new;

  final Uri base;
  final HttpClient Function() _client;
  final Duration timeout;

  /// The most listens ListenBrainz takes in one request.
  static const maxBatch = 1000;

  @override
  String get id => "listenbrainz";

  @override
  String get label => "ListenBrainz";

  @override
  Future<String> validate(String token) async {
    final reply = await _request("GET", "/1/validate-token", token);
    final body = reply.body;
    if (body is Map && body["valid"] == true) {
      final name = body["user_name"];
      if (name is String && name.isNotEmpty) return name;
    }
    throw const ScrobbleFailure(
      ScrobbleFailureKind.auth,
      "ListenBrainz did not accept that token.",
    );
  }

  @override
  Future<void> submit(String token, List<Map<String, Object?>> listens) async {
    if (listens.isEmpty) return;
    if (listens.length > maxBatch) {
      throw ArgumentError("At most $maxBatch listens per request");
    }
    await _request(
      "POST",
      "/1/submit-listens",
      token,
      body: {
        // "single" is one listen as it happens; batches are imports.
        "listen_type": listens.length == 1 ? "single" : "import",
        "payload": listens,
      },
    );
  }

  Future<({int status, Object? body})> _request(
    String method,
    String path,
    String token, {
    Object? body,
  }) async {
    final client = _client()..connectionTimeout = timeout;
    try {
      final request = await client
          .openUrl(method, base.replace(path: path))
          .timeout(timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, "Token $token")
        ..set(HttpHeaders.acceptHeader, "application/json");
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      Object? decoded;
      try {
        decoded = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) return (status: status, body: decoded);
      throw _failure(status, decoded, response.headers);
    } on ScrobbleFailure {
      rethrow;
    } on TimeoutException {
      throw const ScrobbleFailure(
        ScrobbleFailureKind.unavailable,
        "ListenBrainz did not answer in time.",
      );
    } on IOException catch (error) {
      // SocketException, HandshakeException, HttpException.
      throw ScrobbleFailure(
        ScrobbleFailureKind.unavailable,
        "ListenBrainz could not be reached: $error",
      );
    } finally {
      client.close(force: true);
    }
  }

  static ScrobbleFailure _failure(
    int status,
    Object? body,
    HttpHeaders headers,
  ) {
    final detail = body is Map && body["error"] is String
        ? body["error"] as String
        : "HTTP $status";
    return switch (status) {
      401 || 403 => ScrobbleFailure(
        ScrobbleFailureKind.auth,
        "ListenBrainz refused the token: $detail",
      ),
      429 => ScrobbleFailure(
        ScrobbleFailureKind.rateLimited,
        "ListenBrainz asked Melody to slow down.",
        retryAfter: Duration(
          seconds:
              int.tryParse(headers.value("x-ratelimit-reset-in") ?? "") ?? 60,
        ),
      ),
      400 || 413 => ScrobbleFailure(
        ScrobbleFailureKind.rejected,
        "ListenBrainz rejected the listens: $detail",
      ),
      _ => ScrobbleFailure(
        ScrobbleFailureKind.unavailable,
        "ListenBrainz is unavailable: $detail",
      ),
    };
  }
}
