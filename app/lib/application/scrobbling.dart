/// Scrobbling: sends listens to ListenBrainz, queued in `library.db` so they
/// survive being offline, a failed request, and a restart.
///
/// It only ever receives finished [Listen]s (from `ListeningTracker`), so it
/// has no part in playback: a slow, failing, or disconnected service changes
/// nothing about what plays.
library;

import "dart:async";
import "dart:math";

import "package:flutter/foundation.dart";

import "../core/listenbrainz.dart";
import "../core/media.dart";
import "models.dart";
import "store.dart";

/// Where scrobbling stands.
enum ScrobbleState {
  /// No account connected; listens are not queued.
  disconnected,

  /// Connected; listens are queued and sent.
  connected,

  /// The service no longer accepts the token. Listens keep queueing until
  /// the listener connects again.
  needsSignIn,
}

/// The ListenBrainz form of [listen], or null when it lacks what the
/// service requires (an artist and a title).
Map<String, Object?>? listenBrainzListen(Listen listen) {
  final artist = listen.artist.trim();
  final title = listen.title.trim();
  // The catalog's placeholders are not names.
  if (artist.isEmpty ||
      title.isEmpty ||
      artist == "Unknown artist" ||
      artist == "Unknown channel") {
    return null;
  }
  final identity = MediaIdentity.fromUrl(listen.source);
  return {
    "listened_at": listen.startedAt.millisecondsSinceEpoch ~/ 1000,
    "track_metadata": {
      "artist_name": artist,
      "track_name": title,
      if (listen.album.trim().isNotEmpty) "release_name": listen.album.trim(),
      "additional_info": {
        "media_player": "Melody",
        "submission_client": "Melody",
        if (listen.durationMs > 0) "duration_ms": listen.durationMs,
        if (identity != null) ...{
          "origin_url": youtubeShareUrl(listen.source),
          "music_service": youtubeMusicHost,
        },
      },
    },
  };
}

/// Queues listens and sends them to a [ScrobbleService].
///
/// - **Offline and failures.** Each listen is queued in its own row before
///   any request. A request that fails for want of a connection or a working
///   server is tried again with growing delays (30 seconds to 30 minutes),
///   at the next listen, and when Melody comes back on screen ([retryNow]),
///   so the queue drains soon after a connection returns.
/// - **Duplicates.** A listen is queued once per service (keyed by the second
///   it began), and ListenBrainz ignores a listen it already has, so a reply
///   lost after the service accepted a batch does no harm when it is sent
///   again.
/// - **Rejections.** A refused batch is sent again one listen at a time; a
///   listen refused on its own is dropped, so it cannot block the rest.
/// - **Authentication.** A refused token stops sending, keeps the queue, and
///   asks the listener to connect again ([ScrobbleState.needsSignIn]).
class Scrobbler extends ChangeNotifier {
  Scrobbler(
    this._store,
    this.service, {
    Duration Function(int failures)? backoff,
    this.batchSize = 50,
  }) : _backoff = backoff ?? defaultBackoff {
    _load();
  }

  static const _stateKey = "scrobbling";

  /// 30 seconds, doubling with each failure, at most 30 minutes.
  static Duration defaultBackoff(int failures) =>
      Duration(seconds: min(30 * pow(2, max(0, failures - 1)).toInt(), 1800));

  final ApplicationStore _store;
  final ScrobbleService service;
  final Duration Function(int failures) _backoff;
  final int batchSize;

  ScrobbleState _state = ScrobbleState.disconnected;
  String _token = "";
  String _username = "";
  String? _lastError;
  DateTime? _lastSent;
  int _failures = 0;
  Timer? _retry;
  Future<void>? _sending;
  bool _sendAgain = false;
  bool _closed = false;

  ScrobbleState get state => _state;
  String get username => _username;

  /// Why the last attempt failed, until one succeeds.
  String? get lastError => _lastError;
  DateTime? get lastSent => _lastSent;

  /// Listens waiting to be sent.
  int get pending {
    try {
      return _store.pendingScrobbleCount(service.id);
    } on Object {
      return 0;
    }
  }

  /// Whether a retry is scheduled after a failure.
  bool get waiting => _retry?.isActive ?? false;

  void _load() {
    final saved = _store.get(_stateKey);
    if (saved is! Map || saved["service"] != service.id) return;
    final token = saved["token"];
    if (token is! String || token.isEmpty) return;
    _token = token;
    _username = saved["user"] is String ? saved["user"] as String : "";
    _state = saved["needs_sign_in"] == true
        ? ScrobbleState.needsSignIn
        : ScrobbleState.connected;
  }

  void _save() => _store.set(
    _stateKey,
    _state == ScrobbleState.disconnected
        ? null
        : {
            "service": service.id,
            "token": _token,
            "user": _username,
            "needs_sign_in": _state == ScrobbleState.needsSignIn,
          },
  );

  /// Checks [token] with the service and starts sending with it. Throws a
  /// [ScrobbleFailure] (or [FormatException] for an empty token) and changes
  /// nothing when the token does not work.
  Future<void> connect(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const FormatException("Paste your ListenBrainz user token.");
    }
    final username = await service.validate(trimmed);
    if (_closed) return;
    final previous = (_state, _token, _username);
    _token = trimmed;
    _username = username;
    _state = ScrobbleState.connected;
    try {
      _save();
    } catch (_) {
      _state = previous.$1;
      _token = previous.$2;
      _username = previous.$3;
      rethrow;
    }
    _lastError = null;
    _failures = 0;
    notifyListeners();
    unawaited(sendPending());
  }

  /// Stops scrobbling and forgets the token. Queued listens are dropped
  /// too unless [keepQueue]; they would otherwise go to the next account.
  void disconnect({bool keepQueue = false}) {
    _retry?.cancel();
    _store.set(_stateKey, null);
    if (!keepQueue) _store.clearScrobbles(service.id);
    _state = ScrobbleState.disconnected;
    _token = "";
    _username = "";
    _lastError = null;
    _failures = 0;
    notifyListeners();
  }

  /// Queues [listen] and tries to send what is waiting.
  void add(Listen listen) {
    if (_closed || _state == ScrobbleState.disconnected) return;
    final payload = listenBrainzListen(listen);
    if (payload == null) return;
    try {
      _store.enqueueScrobble(
        service.id,
        payload["listened_at"]! as int,
        payload,
      );
    } on Object catch (error) {
      debugPrint("Could not queue a scrobble: $error");
      return;
    }
    notifyListeners();
    // A new listen is a good moment to see whether the connection is back.
    unawaited(sendPending());
  }

  /// Tries at once rather than waiting for a scheduled retry, such as when
  /// Melody comes back on screen.
  void retryNow() {
    if (_state != ScrobbleState.connected || !waiting) return;
    _retry?.cancel();
    unawaited(sendPending());
  }

  /// Sends queued listens until the queue is empty or a request fails. One
  /// run at a time: a call during a run makes it look again before it ends,
  /// so the returned future covers what was queued before the call.
  Future<void> sendPending() {
    if (_closed) return Future.value();
    _sendAgain = true;
    return _sending ??= _run();
  }

  Future<void> _run() async {
    try {
      while (_sendAgain && !_closed) {
        _sendAgain = false;
        await _drain();
      }
    } finally {
      _sending = null;
    }
  }

  Future<void> _drain() async {
    _retry?.cancel();
    while (!_closed && _state == ScrobbleState.connected) {
      final batch = _store.pendingScrobbles(service.id, limit: batchSize);
      if (batch.isEmpty) return;
      try {
        await _send(batch);
      } on ScrobbleFailure catch (failure) {
        if (_closed) return;
        _failed(failure, batch);
        return;
      }
      if (_closed) return;
      _failures = 0;
      _lastError = null;
      _lastSent = DateTime.now();
      notifyListeners();
    }
  }

  /// Sends [batch]; a rejected batch is split so only the listens the
  /// service refuses on their own are dropped.
  Future<void> _send(List<PendingScrobble> batch) async {
    try {
      await service.submit(_token, [for (final item in batch) item.listen]);
      _store.removeScrobbles([for (final item in batch) item.id]);
    } on ScrobbleFailure catch (failure) {
      if (failure.kind != ScrobbleFailureKind.rejected) rethrow;
      if (batch.length == 1) {
        debugPrint("Dropped a scrobble the service refused: $failure");
        _store.removeScrobbles([batch.single.id]);
        return;
      }
      for (final item in batch) {
        await _send([item]);
      }
    }
  }

  void _failed(ScrobbleFailure failure, List<PendingScrobble> batch) {
    _lastError = failure.message;
    switch (failure.kind) {
      case ScrobbleFailureKind.auth:
        _state = ScrobbleState.needsSignIn;
        try {
          _save();
        } on Object catch (error) {
          debugPrint("Could not save the scrobbling state: $error");
        }
      case ScrobbleFailureKind.rateLimited:
        _schedule(failure.retryAfter ?? const Duration(minutes: 1));
      case ScrobbleFailureKind.unavailable:
      case ScrobbleFailureKind.rejected:
        _failures++;
        try {
          _store.recordScrobbleAttempt([for (final item in batch) item.id]);
        } on Object catch (error) {
          debugPrint("Could not count a scrobble attempt: $error");
        }
        _schedule(_backoff(_failures));
    }
    notifyListeners();
  }

  void _schedule(Duration delay) {
    _retry?.cancel();
    _retry = Timer(delay, () => unawaited(sendPending()));
  }

  @override
  void dispose() {
    _closed = true;
    _retry?.cancel();
    super.dispose();
  }
}
