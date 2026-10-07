/// YouTube Music search, playlists, recommendations, lyrics, and stream URLs.
///
/// Metadata comes from YouTube Music itself through ytmusicapi; yt-dlp only
/// resolves playable streams (and, in the download coordinator, downloads).
library;

import "dart:io";

import "../core/errors.dart";
import "../core/media.dart";
import "../core/storage.dart" show pruneCacheDirectory;
import "../worker/worker_client.dart";
import "lyrics.dart";
import "models.dart";

/// Options every yt-dlp call shares: bundled FFmpeg, the uploaded cookies,
/// and a cache folder inside Melody's data ([pruneYtDlpCache] bounds it).
Map<String, Object?> sharedYtDlpOptions(
  AppSettings settings, {
  String? ffmpegLocation,
  String? cacheDirectory,
}) => {
  "ffmpeg_location": ?ffmpegLocation,
  "cachedir": ?cacheDirectory,
  if (settings.cookieFile.isNotEmpty && File(settings.cookieFile).existsSync())
    "cookiefile": settings.cookieFile,
};

/// yt-dlp caches code and signature data per YouTube player release and
/// never deletes any of it. Releases change often, so entries this old
/// belong to retired players; a still-used entry is simply rebuilt.
const ytDlpCacheMaxAge = Duration(days: 30);
const ytDlpCacheMaxBytes = 64 * 1024 * 1024;

/// Bounds yt-dlp's cache folder. Everything in it is disposable.
Future<int> pruneYtDlpCache(String directory) => pruneCacheDirectory(
  directory,
  maxAge: ytDlpCacheMaxAge,
  maxBytes: ytDlpCacheMaxBytes,
);

class RemotePlaylist {
  const RemotePlaylist(this.title, this.tracks);

  final String title;
  final List<SearchResult> tracks;
}

/// YouTube Music through the Python worker. Downloads go through the
/// download coordinator instead.
class MusicCatalog {
  MusicCatalog(this._worker, this._sharedOptions);

  final WorkerClient _worker;

  /// yt-dlp options, read for every request so a changed cookie file
  /// applies immediately.
  final Map<String, Object?> Function() _sharedOptions;

  /// Songs matching a search term, or a pasted YouTube URL (a track or a
  /// playlist).
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final count = limit < 1 ? 1 : limit;
    final start = offset < 0 ? 0 : offset;
    if (isHttpUrl(term)) {
      if (!isYoutubeUrl(term)) {
        throw ProviderError(
          "Enter a search term or paste a $youtubeMusicName URL.",
        );
      }
      if (isYoutubePlaylistUrl(term)) {
        final playlist = await loadPlaylist(term);
        return playlist.tracks.skip(start).take(count).toList();
      }
      final identity = MediaIdentity.fromUrl(term);
      if (identity == null) {
        throw ProviderError("That URL does not identify a track.");
      }
      if (start > 0) return const [];
      return (await _watchPlaylist(
        videoId: identity.mediaId,
        limit: 1,
      )).tracks.where((track) => track.id == identity.mediaId).take(1).toList();
    }
    // ytmusicapi has no offset; it returns at least `limit` results.
    final found = await _call("search", {
      "query": term,
      "filter": "songs",
      "limit": start + count,
    });
    return tracksFromYtMusic(found).skip(start).take(count).toList();
  }

  Future<String> resolveStream(String url) async {
    var info = await _extract(url, {
      "format": "bestaudio/best",
      "noplaylist": true,
      "extract_flat": false,
    });
    final entries = info?["entries"];
    if (entries is List) {
      info = entries.whereType<Map>().firstOrNull?.cast<String, Object?>();
    }
    final stream = "${info?["url"] ?? ""}";
    if (stream.isEmpty) {
      throw ProviderError(
        "This result does not expose a playable audio stream.",
      );
    }
    return stream;
  }

  /// YouTube Music radio recommendations for a seed track.
  Future<List<SearchResult>> recommendations(
    String seedUrl, {
    int limit = 12,
  }) async {
    final seed = MediaIdentity.fromUrl(seedUrl);
    if (seed == null || seed.provider != youtubeProviderId) {
      throw ProviderError(
        "A $youtubeMusicName track is needed for recommendations.",
      );
    }
    final count = limit < 1 ? 1 : limit;
    // Radio mixes normally include the seed; request one extra entry.
    final radio = await _watchPlaylist(
      videoId: seed.mediaId,
      limit: count + 1,
      radio: true,
    );
    final seen = <String>{};
    final results = <SearchResult>[];
    for (final result in radio.tracks) {
      if (result.identity == seed || !seen.add(result.id)) continue;
      results.add(result);
      if (results.length == count) break;
    }
    return results;
  }

  Future<RemotePlaylist> loadPlaylist(String url) async {
    final source = url.trim();
    if (!isYoutubePlaylistUrl(source)) {
      throw ProviderError("Paste a complete $youtubeMusicName playlist URL.");
    }
    final playlistId = Uri.parse(
      source,
    ).queryParametersAll["list"]!.firstWhere((item) => item.isNotEmpty);
    final String title;
    final List<SearchResult> tracks;
    if (playlistId.startsWith("RD")) {
      // Mixes are generated per listener and have no playlist page.
      final mix = await _watchPlaylist(playlistId: playlistId, limit: 100);
      title = "$youtubeMusicName mix";
      tracks = mix.tracks;
    } else {
      final data = await _call("get_playlist", {
        "playlistId": playlistId,
        "limit": null,
        "related": false,
        "suggestions_limit": 0,
      });
      if (data is! Map) {
        throw ProviderError(
          "That URL did not resolve to a $youtubeMusicName playlist.",
        );
      }
      title = _text(data["title"]);
      tracks = tracksFromYtMusic(data["tracks"]);
    }
    final named = title.isNotEmpty
        ? title
        : "Imported $youtubeMusicName playlist";
    return RemotePlaylist(named, [
      for (final track in tracks) track.withPlaylistTitle(named),
    ]);
  }

  /// The lyrics YouTube Music shows for a track, timed when available, or
  /// null when it has none.
  Future<Lyrics?> lyrics(String videoId) async {
    final watch = await _watchPlaylist(videoId: videoId, limit: 1);
    final browseId = watch.lyricsBrowseId;
    if (browseId.isEmpty) return null;
    final data = await _call("get_lyrics", {
      "browseId": browseId,
      "timestamps": true,
    });
    return data is Map
        ? Lyrics.fromYtMusic(data.cast<String, Object?>())
        : null;
  }

  Future<_WatchPlaylist> _watchPlaylist({
    String? videoId,
    String? playlistId,
    required int limit,
    bool radio = false,
  }) async {
    final data = await _call("get_watch_playlist", {
      "videoId": ?videoId,
      "playlistId": ?playlistId,
      "limit": limit,
      "radio": radio,
    });
    if (data is! Map) return const _WatchPlaylist([], "");
    return _WatchPlaylist(
      tracksFromYtMusic(data["tracks"]),
      _text(data["lyrics"]),
    );
  }

  Future<Object?> _call(String method, Map<String, Object?> arguments) async {
    try {
      return await _worker.ytMusic(method, arguments);
    } on ProviderError {
      rethrow;
    } catch (error) {
      throw ProviderError(friendlyProviderError(error));
    }
  }

  Future<Map<String, Object?>?> _extract(
    String target, [
    Map<String, Object?> options = const {},
  ]) async {
    try {
      return await _worker.extract(target, {
        "quiet": true,
        "no_warnings": true,
        "skip_download": true,
        "noplaylist": false,
        "extract_flat": "in_playlist",
        "socket_timeout": 12,
        ...options,
        ..._sharedOptions(),
      });
    } on ProviderError {
      rethrow;
    } catch (error) {
      throw ProviderError(friendlyProviderError(error));
    }
  }
}

class _WatchPlaylist {
  const _WatchPlaylist(this.tracks, this.lyricsBrowseId);

  final List<SearchResult> tracks;

  /// Empty when the first track has no lyrics.
  final String lyricsBrowseId;
}

String _text(Object? value) => value == null ? "" : "$value".trim();

/// Search results, watch-playlist tracks, or playlist tracks from ytmusicapi.
/// Entries without a video (unavailable or region-locked) are skipped.
List<SearchResult> tracksFromYtMusic(Object? items) {
  if (items is! List) return const [];
  final results = <SearchResult>[];
  for (final value in items) {
    if (value is! Map) continue;
    final item = value.cast<String, Object?>();
    final videoId = _text(item["videoId"]);
    if (videoId.isEmpty) continue;
    final title = _text(item["title"]);
    final artists = [
      if (item["artists"] case final List<Object?> artists)
        for (final artist in artists)
          if (artist case {"name": final Object name}) _text(name),
    ].where((name) => name.isNotEmpty).toList();
    results.add(
      SearchResult(
        id: videoId,
        title: title.isNotEmpty ? title : "Untitled track",
        uploader: artists.isNotEmpty ? artists.join(", ") : "Unknown artist",
        duration: _seconds(item),
        thumbnail: ytMusicThumbnail(item["thumbnails"] ?? item["thumbnail"]),
        url: youtubeMusicTrackUrl("", videoId),
        source: youtubeMusicName,
      ),
    );
  }
  return results;
}

/// `duration_seconds`, or a `duration`/`length` such as "1:02:03".
double _seconds(Map<String, Object?> item) {
  if (item["duration_seconds"] case final num seconds) {
    return seconds.toDouble();
  }
  final text = _text(item["duration"] ?? item["length"]);
  if (text.isEmpty) return 0;
  var total = 0;
  for (final part in text.split(":")) {
    final value = int.tryParse(part);
    if (value == null) return 0;
    total = total * 60 + value;
  }
  return total.toDouble();
}

final _sizedArtwork = RegExp(r"=w\d+-h\d+");

/// The largest thumbnail, with YouTube Music's sized artwork URLs asked for
/// at cover size (search results list 60 and 120 pixel variants).
String ytMusicThumbnail(Object? thumbnails) {
  if (thumbnails is! List) return "";
  var best = "";
  var bestArea = -1.0;
  for (final value in thumbnails) {
    if (value is! Map) continue;
    final url = _text(value["url"]);
    if (url.isEmpty) continue;
    final width = value["width"];
    final height = value["height"];
    final area = width is num && height is num
        ? width.toDouble() * height.toDouble()
        : 0.0;
    if (area > bestArea) {
      best = url;
      bestArea = area;
    }
  }
  if (best.startsWith("//")) best = "https:$best";
  return best.replaceFirst(_sizedArtwork, "=w544-h544");
}
