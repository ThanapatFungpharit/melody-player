import "dart:io";

import "../core/errors.dart";
import "../core/media.dart";
import "../worker/worker_client.dart";
import "models.dart";

final _youtubeVideoId = RegExp(r"^[A-Za-z0-9_-]{6,64}$");

/// Options every yt-dlp call shares: bundled FFmpeg and the uploaded cookies.
Map<String, Object?> sharedYtDlpOptions(
  AppSettings settings, {
  String? ffmpegLocation,
}) => {
  "ffmpeg_location": ?ffmpegLocation,
  if (settings.cookieFile.isNotEmpty && File(settings.cookieFile).existsSync())
    "cookiefile": settings.cookieFile,
};

class RemotePlaylist {
  const RemotePlaylist(this.title, this.tracks);

  final String title;
  final List<SearchResult> tracks;
}

/// Search and metadata through the worker; downloads use [Downloader].
class YtDlpProvider {
  YtDlpProvider(this._worker, this._sharedOptions);

  final WorkerClient _worker;
  final Map<String, Object?> _sharedOptions;
  final String id = youtubeProviderId;
  final String name = youtubeMusicName;

  bool accepts(String query) {
    final uri = Uri.tryParse(query.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (scheme != "http" && scheme != "https") return true;
    return isYoutubeUrl(query);
  }

  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final count = limit < 1 ? 1 : limit;
    final start = offset < 0 ? 0 : offset;
    // YouTube Music's search extractor emits sparse flat entries; the regular
    // YouTube search supplies channel and thumbnail metadata in one request,
    // and results are still canonicalized to music.youtube.com.
    final target = isHttpUrl(term) ? term : "ytsearch${start + count}:$term";
    final info = await _extract(target, {
      "playliststart": start + 1,
      "playlistend": start + count,
    });
    return resultsFromInfo(info, name, limit: count);
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
      throw ProviderError("This result does not expose a playable audio stream.");
    }
    return stream;
  }

  /// YouTube Music radio recommendations for a seed track.
  Future<List<SearchResult>> recommendations(String seedUrl, {int limit = 12}) async {
    final String target;
    try {
      target = youtubeMusicRadioUrl(seedUrl);
    } on ArgumentError {
      throw ProviderError("A $youtubeMusicName track is needed for recommendations.");
    }
    final count = limit < 1 ? 1 : limit;
    // Radio mixes normally include the seed; request one extra entry.
    final info = await _extract(target, {"playliststart": 1, "playlistend": count + 1});
    final seed = MediaIdentity.fromUrl(seedUrl);
    final seen = <String>{};
    final results = <SearchResult>[];
    for (final result in resultsFromInfo(info, name)) {
      final identity = result.identity;
      final key = identity?.key ?? result.url;
      if (result.isPlaylist || identity == seed || key.isEmpty || !seen.add(key)) {
        continue;
      }
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
    final info = await _extract(source);
    if (info == null || !isExplicitPlaylist(info)) {
      throw ProviderError("That URL did not resolve to a $youtubeMusicName playlist.");
    }
    final title = "${info["title"] ?? ""}".trim();
    return RemotePlaylist(
      title.isNotEmpty ? title : "Imported $youtubeMusicName playlist",
      [
        for (final result in resultsFromInfo(info, name))
          if (result.url.isNotEmpty && isYoutubeUrl(result.url)) result,
      ],
    );
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
        ..._sharedOptions,
      });
    } on ProviderError {
      rethrow;
    } catch (error) {
      throw ProviderError(friendlyProviderError(error));
    }
  }
}

class ProviderRegistry {
  ProviderRegistry(WorkerClient worker, Map<String, Object?> sharedOptions)
    : _youtube = YtDlpProvider(worker, sharedOptions);

  final YtDlpProvider _youtube;

  YtDlpProvider get(String providerId) {
    if (providerId != youtubeProviderId) {
      throw ProviderError("Source '$providerId' is not available.");
    }
    return _youtube;
  }

  Future<List<SearchResult>> search(
    String providerId,
    String query, {
    int limit = 20,
    int offset = 0,
  }) {
    final provider = get(providerId);
    if (!provider.accepts(query)) {
      throw ProviderError("Enter a search term or paste a $youtubeMusicName URL.");
    }
    return provider.search(query, limit: limit, offset: offset);
  }

  Future<RemotePlaylist> loadPlaylist(String url) => _youtube.loadPlaylist(url);

  Future<List<SearchResult>> recommendations(String seedUrl, {int limit = 12}) =>
      _youtube.recommendations(seedUrl, limit: limit);
}

bool _isSearchContainer(Map<String, Object?> info) {
  final extractor = "${info["extractor"] ?? ""} ${info["extractor_key"] ?? ""}"
      .toLowerCase();
  final original = "${info["original_url"] ?? ""}".toLowerCase();
  return extractor.contains("search") || original.startsWith("ytsearch");
}

bool isExplicitPlaylist(Map<String, Object?> info) =>
    info["_type"] == "playlist" && !_isSearchContainer(info);

String _text(Object? value) => value == null || value == "" ? "" : "$value";

double _number(Object? value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text) ?? 0,
  _ => 0,
};

List<SearchResult> resultsFromInfo(
  Map<String, Object?>? info,
  String source, {
  int? limit,
}) {
  if (info == null) return const [];
  final explicitPlaylist = isExplicitPlaylist(info);
  final playlistTitle = explicitPlaylist ? (_text(info["title"]).isEmpty ? "Playlist" : _text(info["title"])) : "";
  final playlistUploader = _text(info["uploader"]).isNotEmpty
      ? _text(info["uploader"])
      : _text(info["channel"]);
  final entries = info["entries"];
  final List<Object?> raw = explicitPlaylist
      ? (entries is List ? entries : const [])
      : (entries is List && entries.isNotEmpty ? entries : [info]);
  final youtubeSource = source.toLowerCase().startsWith("youtube");
  final results = <SearchResult>[];
  for (final value in raw) {
    if (limit != null && results.length >= limit) break;
    if (value is! Map || value.isEmpty) continue;
    final entry = value.cast<String, Object?>();
    final mediaId = _text(entry["id"]);
    var url = _text(entry["webpage_url"]).isNotEmpty
        ? _text(entry["webpage_url"])
        : _text(entry["url"]);
    if (youtubeSource) {
      url = youtubeMusicTrackUrl(url, mediaId.isNotEmpty ? mediaId : url);
    }
    final uploader = [
      _text(entry["uploader"]),
      _text(entry["channel"]),
      playlistUploader,
    ].firstWhere((item) => item.isNotEmpty, orElse: () => "Unknown uploader");
    final title = _text(entry["title"]);
    final entryPlaylistTitle = _text(entry["playlist_title"]);
    results.add(
      SearchResult(
        id: mediaId.isNotEmpty ? mediaId : url,
        title: title.isNotEmpty ? title : "Untitled track",
        uploader: uploader,
        duration: _number(entry["duration"]),
        thumbnail: thumbnailUrl(entry, youtubeId: youtubeSource ? mediaId : ""),
        url: url,
        source: source,
        playlistTitle: entryPlaylistTitle.isNotEmpty ? entryPlaylistTitle : playlistTitle,
      ),
    );
  }
  return results;
}

/// A usable thumbnail from full or flat yt-dlp metadata.
String thumbnailUrl(Map<String, Object?> info, {String youtubeId = ""}) {
  final direct = _text(info["thumbnail"]).trim();
  if (direct.isNotEmpty) return _absolute(direct);
  Map<String, Object?>? best;
  (double, double)? bestQuality;
  final thumbnails = info["thumbnails"];
  if (thumbnails is List) {
    for (final candidate in thumbnails) {
      if (candidate is! Map) continue;
      final item = candidate.cast<String, Object?>();
      if (_text(item["url"]).trim().isEmpty) continue;
      final quality = (
        _number(item["preference"]),
        _number(item["width"]) * _number(item["height"]),
      );
      if (bestQuality == null ||
          quality.$1 > bestQuality.$1 ||
          (quality.$1 == bestQuality.$1 && quality.$2 > bestQuality.$2)) {
        best = item;
        bestQuality = quality;
      }
    }
  }
  if (best == null) {
    return _youtubeVideoId.hasMatch(youtubeId)
        ? "https://i.ytimg.com/vi/$youtubeId/hqdefault.jpg"
        : "";
  }
  return _absolute(_text(best["url"]).trim());
}

String _absolute(String url) => url.startsWith("//") ? "https:$url" : url;
