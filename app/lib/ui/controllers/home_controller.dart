import "dart:async";
import "dart:math";

import "package:flutter/foundation.dart";

import "../app_state.dart";
import "../shared/format.dart";
import "../../application/models.dart";
import "../../core/errors.dart";
import "../../core/library/models.dart";
import "../../core/media.dart";

/// Home collections and the YouTube Music recommendation mix.
class HomeController extends ChangeNotifier {
  HomeController(this.app);

  static const recommendationLimit = 8;
  static const recommendationFetchLimits = [24, 48, 96];
  static const recommendationTarget = 32;
  static const recommendationSeedLimit = 2;
  static const refreshDelay = Duration(seconds: 1);

  final MelodyApp app;
  final Random _random = Random();
  List<SearchResult> recommendations = [];
  bool recommendationsLoading = false;
  String recommendationsError = "";
  int recommendationPage = 0;
  List<String> _seedUrls = [];
  List<String> _sources = [];
  int _request = 0;
  int _watchers = 0;
  Timer? _refreshTimer;
  late final Listenable _changes = Listenable.merge([
    app.libraryRevision,
    app.playbackState,
  ]);

  /// Keeps the mix following plays, favorites, and downloads while a Home
  /// view is showing. Pair each call with [detach].
  void attach() {
    if (_watchers++ == 0) _changes.addListener(_scheduleRefresh);
    ensureRecommendations();
  }

  void detach() {
    if (--_watchers > 0) return;
    _changes.removeListener(_scheduleRefresh);
    _refreshTimer?.cancel();
  }

  /// Waits for a burst of playback and library events to settle.
  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(refreshDelay, () {
      final pruned = _pruneDownloaded();
      if (ensureRecommendations(quiet: true) || pruned) notifyListeners();
    });
  }

  /// Drops recommendations that have since been added to the library.
  bool _pruneDownloaded() {
    final manager = app.services.manager;
    final kept = [
      for (final result in recommendations)
        if (manager.findTrackBySource(result.url) == null) result,
    ];
    if (kept.length == recommendations.length) return false;
    recommendations = kept;
    final last = max(0, (kept.length - 1) ~/ recommendationLimit);
    recommendationPage = min(recommendationPage, last);
    return true;
  }

  /// Track count, up to six recent tracks, and every favorite.
  (int, List<Track>, List<Track>) collections() {
    final manager = app.services.manager;
    final recentIds = app.services.store.get("recent_tracks", const []);
    final recent = <Track>[];
    if (recentIds is List) {
      for (final id in recentIds.whereType<String>()) {
        if (!manager.hasTrack(id)) continue;
        recent.add(manager.getTrack(id));
        if (recent.length == 6) break;
      }
    }
    final favorites = manager.tracksByIds(
      app.services.store.favoriteTrackIds(),
    );
    return (manager.counts().$1, recent, favorites);
  }

  void playLibrary() => app.playback.playTracks([
    for (final track in app.services.manager.listTracks()) track.id,
  ]);

  void shuffleLibrary() => app.playback.playTracksShuffled([
    for (final track in app.services.manager.listTracks()) track.id,
  ]);

  void queueLibrary() =>
      queueCollection(app, app.services.manager.listTracks());

  /// Loads a related mix without blocking the Home view, returning whether
  /// the visible state changed. A [quiet] refresh keeps the current mix on
  /// screen until the new one arrives.
  bool ensureRecommendations({bool force = false, bool quiet = false}) {
    final sources = _candidates();
    if (sources.isEmpty) {
      if (_sources.isEmpty && recommendations.isEmpty) return false;
      _request++;
      recommendations = [];
      recommendationsLoading = false;
      recommendationsError = "";
      _seedUrls = [];
      _sources = [];
      recommendationPage = 0;
      return true;
    }
    // Replaying a known track only reorders the sources; keep the mix.
    if (!force && setEquals(sources.toSet(), _sources.toSet())) return false;
    final choices = List.of(sources)..shuffle(_random);
    if (choices.length > 1 &&
        _seedUrls.isNotEmpty &&
        choices.first == _seedUrls.first) {
      choices.add(choices.removeAt(0));
    }
    final seeds = choices.take(recommendationSeedLimit).toList();
    final request = ++_request;
    _sources = sources;
    _seedUrls = seeds;
    final keep = quiet && recommendations.isNotEmpty;
    if (!keep) {
      recommendationsLoading = true;
      recommendationsError = "";
      recommendationPage = 0;
    }
    unawaited(_fetch(seeds, request, keep: keep));
    return !keep;
  }

  void reload() {
    ensureRecommendations(force: true);
    notifyListeners();
  }

  /// Distinct playable sources from the current, recent, and favorite tracks.
  List<String> _candidates() {
    final ids = <String>[
      ?app.playback.currentTrackId,
      if (app.services.store.get("recent_tracks")
          case final List<Object?> recent)
        ...recent.whereType<String>(),
      ...(app.services.store.favoriteTrackIds().toList()..sort()),
    ];
    final seen = <String>{};
    final sources = <String>[];
    for (final id in ids) {
      if (!seen.add(id) || !app.services.manager.hasTrack(id)) continue;
      final source = app.services.manager.getTrack(id).source;
      if (isYoutubeUrl(source) && !sources.contains(source)) {
        sources.add(source);
      }
    }
    return sources;
  }

  /// Expands radio mixes when duplicates leave too few new tracks.
  Future<void> _fetch(
    List<String> seeds,
    int request, {
    bool keep = false,
  }) async {
    final results = <SearchResult>[];
    final seen = <String>{};
    final errors = <Object>[];
    var active = seeds;
    try {
      for (final limit in recommendationFetchLimits) {
        final nextSeeds = <String>[];
        for (final seed in active) {
          final List<SearchResult> fetched;
          try {
            fetched = await app.services.catalog.recommendations(
              seed,
              limit: limit,
            );
          } on ProviderError catch (error) {
            errors.add(error);
            continue;
          }
          final before = results.length;
          for (final result in fetched) {
            final key = result.identity?.key ?? result.url;
            if (result.isPlaylist ||
                key.isEmpty ||
                seen.contains(key) ||
                app.services.manager.findTrackBySource(result.url) != null) {
              continue;
            }
            seen.add(key);
            results.add(result);
          }
          // A short result can conceal entries the provider filtered; probe
          // once more at a larger limit.
          if (limit == recommendationFetchLimits.first ||
              fetched.length >= limit ||
              results.length > before) {
            nextSeeds.add(seed);
          }
          if (results.length >= recommendationTarget) break;
        }
        if (results.length >= recommendationTarget || nextSeeds.isEmpty) break;
        active = nextSeeds;
      }
      if (results.isEmpty && errors.isNotEmpty) throw errors.first;
      results.shuffle(_random);
      if (request != _request) return;
      recommendations = results;
      recommendationsError = "";
      recommendationPage = 0;
    } catch (error) {
      if (request != _request) return;
      // A failed background refresh leaves the current mix in place.
      if (keep) return;
      recommendations = [];
      recommendationsError = "$error";
    }
    recommendationsLoading = false;
    notifyListeners();
  }

  List<SearchResult> visibleRecommendations() => recommendations
      .skip(recommendationPage * recommendationLimit)
      .take(recommendationLimit)
      .toList();

  void changeRecommendationPage(int direction) {
    final last = max(0, (recommendations.length - 1) ~/ recommendationLimit);
    recommendationPage = (recommendationPage + direction).clamp(0, last);
    notifyListeners();
  }
}

/// Appends tracks to the queue and confirms how many were added.
void queueCollection(MelodyApp app, List<Track> tracks) {
  final count = app.playback.addLastMany([
    for (final track in tracks) track.id,
  ]);
  if (count > 0) {
    app.showMessage("Added ${plural(count, "track")} to the queue.");
  }
}
