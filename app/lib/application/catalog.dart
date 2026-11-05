/// Search, playlists, recommendations, and lyrics from YouTube.
///
/// [MusicSource] picks where they come from: YouTube Music through ytmusicapi,
/// or regular YouTube through yt-dlp without downloading. Lyrics only exist on
/// YouTube Music, so they come from there either way.
library;

import "dart:io";

import "../core/errors.dart";
import "../core/media.dart";
import "../core/storage.dart" show pruneCacheDirectory;
import "../worker/worker_client.dart";
import "lyrics.dart";
import "models.dart";

/// Options every yt-dlp call shares: bundled FFmpeg, the uploaded cookies
/// when [cookieFile] exists, and a cache folder inside Melody's data
/// ([pruneYtDlpCache] bounds it).
Map<String, Object?> sharedYtDlpOptions({
  String? ffmpegLocation,
  String? cacheDirectory,
  String? cookieFile,
}) => {
  "ffmpeg_location": ?ffmpegLocation,
  "cachedir": ?cacheDirectory,
  if (cookieFile != null && File(cookieFile).existsSync())
    "cookiefile": cookieFile,
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

/// YouTube through the Python worker. Downloads go through the download
/// coordinator instead.
class MusicCatalog {
  MusicCatalog(
    this._worker, {
    MusicSource Function()? source,
    Map<String, Object?> Function()? ytDlpOptions,
  }) : _source = source ?? _defaultSource,
       _ytDlpOptions = ytDlpOptions ?? _noOptions;

  static MusicSource _defaultSource() => MusicSource.youtubeMusic;
  static Map<String, Object?> _noOptions() => const {};

  final WorkerClient _worker;
  final MusicSource Function() _source;
  final Map<String, Object?> Function() _ytDlpOptions;

  bool get _regularYoutube => _source() == MusicSource.youtube;

  /// The source and playlist link last pasted into a search, and what it
  /// loaded.
  ((MusicSource, String), RemotePlaylist)? _pastedPlaylist;

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
          "Enter a search term or paste a ${_source().label} URL.",
        );
      }
      if (isYoutubePlaylistUrl(term)) {
        // Turning the page must not fetch the whole playlist again.
        final key = (_source(), term);
        final loaded = _pastedPlaylist;
        final playlist = start > 0 && loaded != null && loaded.$1 == key
            ? loaded.$2
            : await loadPlaylist(term);
        _pastedPlaylist = (key, playlist);
        return playlist.tracks.skip(start).take(count).toList();
      }
      final identity = MediaIdentity.fromUrl(term);
      if (identity == null) {
        throw ProviderError("That URL does not identify a track.");
      }
      if (start > 0) return const [];
      if (_regularYoutube) return [await _youtubeVideo(identity.mediaId)];
      return (await _watchPlaylist(
        videoId: identity.mediaId,
        limit: 1,
      )).tracks.where((track) => track.id == identity.mediaId).take(1).toList();
    }
    if (_regularYoutube) {
      // Like ytmusicapi below, yt-dlp's search has no offset.
      final found = await _extract(
        "ytsearch${start + count}:$term",
        _flatOptions(),
      );
      return tracksFromYoutube(
        found?["entries"],
      ).skip(start).take(count).toList();
    }
    // ytmusicapi has no offset; it returns at least `limit` results.
    final found = await _call("search", {
      "query": term,
      "filter": "songs",
      "limit": start + count,
    });
    return tracksFromYtMusic(found).skip(start).take(count).toList();
  }

  /// Radio recommendations for a seed track, from the selected source.
  Future<List<SearchResult>> recommendations(
    String seedUrl, {
    int limit = 12,
  }) async {
    final seed = MediaIdentity.fromUrl(seedUrl);
    if (seed == null || seed.provider != youtubeProviderId) {
      throw ProviderError(
        "A ${_source().label} track is needed for recommendations.",
      );
    }
    final count = limit < 1 ? 1 : limit;
    // Radio mixes normally include the seed; request one extra entry.
    final List<SearchResult> tracks;
    if (_regularYoutube) {
      final mix = Uri.https(youtubeHost, "/watch", {
        "v": seed.mediaId,
        "list": "RD${seed.mediaId}",
      }).toString();
      final found = await _extract(mix, {
        ..._flatOptions(),
        "playlistend": count + 1,
      });
      tracks = tracksFromYoutube(found?["entries"]);
    } else {
      tracks = (await _watchPlaylist(
        videoId: seed.mediaId,
        limit: count + 1,
        radio: true,
      )).tracks;
    }
    final seen = <String>{};
    final results = <SearchResult>[];
    for (final result in tracks) {
      if (result.identity == seed || !seen.add(result.id)) continue;
      results.add(result);
      if (results.length == count) break;
    }
    return results;
  }

  Future<RemotePlaylist> loadPlaylist(String url) async {
    final source = url.trim();
    if (!isYoutubePlaylistUrl(source)) {
      throw ProviderError("Paste a complete ${_source().label} playlist URL.");
    }
    final playlistId = Uri.parse(
      source,
    ).queryParametersAll["list"]!.firstWhere((item) => item.isNotEmpty);
    final String title;
    final List<SearchResult> tracks;
    if (playlistId.startsWith("RD")) {
      // Mixes are generated per listener and have no playlist page, on either
      // source; only YouTube Music can open one from its ID alone.
      final mix = await _watchPlaylist(playlistId: playlistId, limit: 100);
      title = "$youtubeMusicName mix";
      tracks = mix.tracks;
    } else if (_regularYoutube) {
      final data = await _extract(
        Uri.https(youtubeHost, "/playlist", {"list": playlistId}).toString(),
        _flatOptions(),
      );
      if (data == null) {
        throw ProviderError(
          "That URL did not resolve to a $youtubeName playlist.",
        );
      }
      title = _text(data["title"]);
      tracks = tracksFromYoutube(data["entries"]);
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
        : "Imported ${_source().label} playlist";
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

  /// One video, checked with yt-dlp, so a link to a removed or restricted
  /// video fails here rather than as a download.
  Future<SearchResult> _youtubeVideo(String videoId) async {
    final data = await _extract(youtubeVideoUrl(videoId), {
      ..._ytDlpOptions(),
      ..._quiet,
      "noplaylist": true,
      "format": "bestaudio/best",
    });
    if (data != null && _isLive(data)) {
      throw ProviderError("Live streams cannot be saved to your library.");
    }
    final tracks = tracksFromYoutube([?data]);
    if (tracks.isEmpty) {
      throw ProviderError("That URL does not identify a track.");
    }
    return tracks.single;
  }

  static const _quiet = {
    "quiet": true,
    "no_warnings": true,
    "skip_download": true,
  };

  /// Lists a search or playlist without opening each video, which would take
  /// a request per entry.
  Map<String, Object?> _flatOptions() => {
    ..._ytDlpOptions(),
    ..._quiet,
    "noplaylist": false,
    "extract_flat": "in_playlist",
  };

  Future<Map<String, Object?>?> _extract(
    String target,
    Map<String, Object?> options,
  ) async {
    try {
      return await _worker.extract(target, options);
    } on ProviderError {
      rethrow;
    } catch (error) {
      throw ProviderError(friendlyProviderError(error, provider: youtubeName));
    }
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

const _unlistedTitles = {"[Deleted video]", "[Private video]"};

bool _isLive(Map<String, Object?> info) =>
    const {"is_live", "is_upcoming"}.contains(info["live_status"]);

/// Video entries from yt-dlp. Entries that cannot be saved (removed, private,
/// or live) are skipped. Regular YouTube names no artists, so the channel
/// stands in, without the " - Topic" of its auto-generated music channels.
List<SearchResult> tracksFromYoutube(Object? entries) {
  if (entries is! List) return const [];
  final results = <SearchResult>[];
  for (final value in entries) {
    if (value is! Map) continue;
    final item = value.cast<String, Object?>();
    final videoId = _text(item["id"]);
    final title = _text(item["title"]);
    if (videoId.isEmpty || _unlistedTitles.contains(title) || _isLive(item)) {
      continue;
    }
    final channel = _text(
      item["channel"] ?? item["uploader"],
    ).replaceFirst(RegExp(r" - Topic$"), "");
    final thumbnail = ytMusicThumbnail(item["thumbnails"]);
    results.add(
      SearchResult(
        id: videoId,
        title: title.isNotEmpty ? title : "Untitled video",
        uploader: channel.isNotEmpty ? channel : "Unknown channel",
        duration: _seconds(item),
        thumbnail: thumbnail.isNotEmpty ? thumbnail : _text(item["thumbnail"]),
        url: youtubeVideoUrl(videoId),
        source: youtubeName,
      ),
    );
  }
  return results;
}

/// `duration_seconds`, or a `duration`/`length` such as "1:02:03".
double _seconds(Map<String, Object?> item) {
  if (item["duration_seconds"] case final num seconds
      when seconds.isFinite && seconds >= 0) {
    return seconds.toDouble();
  }
  // yt-dlp reports seconds as a number under `duration`.
  if (item["duration"] case final num seconds
      when seconds.isFinite && seconds >= 0) {
    return seconds.toDouble();
  }
  final text = _text(item["duration"] ?? item["length"]);
  if (text.isEmpty) return 0;
  var total = 0;
  for (final part in text.split(":")) {
    final value = int.tryParse(part.trim());
    if (value == null || value < 0) return 0;
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
