/// Provider identities independent of titles, paths, UI, and storage records.
library;

const youtubeProviderId = "youtube";
const youtubeMusicName = "YouTube Music";
const youtubeMusicHost = "music.youtube.com";
const youtubeHosts = {
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  youtubeMusicHost,
  "youtube-nocookie.com",
  "www.youtube-nocookie.com",
  "youtu.be",
};

Uri? _parse(String value) => Uri.tryParse(value.trim());

bool _isHttp(Uri? uri) {
  final scheme = uri?.scheme.toLowerCase();
  return scheme == "http" || scheme == "https";
}

bool isHttpUrl(String value) => _isHttp(_parse(value));

/// Whether [value] is an HTTP(S) URL hosted by YouTube.
bool isYoutubeUrl(String value) {
  final uri = _parse(value);
  return _isHttp(uri) && youtubeHosts.contains(uri!.host.toLowerCase());
}

/// Whether [value] identifies a specific YouTube playlist.
bool isYoutubePlaylistUrl(String value) {
  if (!isYoutubeUrl(value)) return false;
  final list = _parse(value)!.queryParametersAll["list"];
  return list != null && list.any((item) => item.isNotEmpty);
}

String _musicWatchUrl(String videoId) =>
    Uri.https(youtubeMusicHost, "/watch", {"v": videoId}).toString();

/// A canonical YouTube Music watch URL for a YouTube video.
String youtubeMusicTrackUrl(String url, [String mediaId = ""]) {
  if (url.isEmpty || !isHttpUrl(url)) {
    final videoId = mediaId.isNotEmpty ? mediaId : url;
    return videoId.isNotEmpty ? _musicWatchUrl(videoId) : url;
  }
  final uri = _parse(url)!;
  final host = uri.host.toLowerCase();
  if (!youtubeHosts.contains(host)) return url;
  final path = uri.path;
  String videoId;
  if (host == "youtu.be") {
    final trimmed = path.replaceAll(RegExp(r"^/+|/+$"), "");
    videoId = trimmed.isNotEmpty ? trimmed : mediaId;
  } else if (path.replaceAll(RegExp(r"/+$"), "") == "/watch") {
    final values = uri.queryParametersAll["v"];
    videoId = values != null && values.isNotEmpty ? values.first : mediaId;
  } else if (path.startsWith("/shorts/") ||
      path.startsWith("/live/") ||
      path.startsWith("/embed/")) {
    final last = path.replaceAll(RegExp(r"/+$"), "").split("/").last;
    videoId = last.isNotEmpty ? last : mediaId;
  } else {
    return url;
  }
  return videoId.isNotEmpty ? _musicWatchUrl(videoId) : url;
}

/// Remote identity: provider plus stable media ID.
class MediaIdentity {
  const MediaIdentity(this.provider, this.mediaId);

  final String provider;
  final String mediaId;

  String get key => "$provider:$mediaId";

  static MediaIdentity? fromUrl(String source) {
    final uri = _parse(source);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final parts = uri.path.replaceAll(RegExp(r"^/+|/+$"), "").split("/");
    var mediaId = "";
    if (host == "youtu.be") {
      mediaId = parts.first;
    } else if (youtubeHosts.contains(host)) {
      final values = uri.queryParametersAll["v"];
      mediaId = values != null && values.isNotEmpty ? values.first : "";
      if (mediaId.isEmpty &&
          parts.length == 2 &&
          const {"shorts", "embed", "live"}.contains(parts[0])) {
        mediaId = parts[1];
      }
    }
    if (mediaId.isNotEmpty && _isHttp(uri)) {
      return MediaIdentity(youtubeProviderId, mediaId);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MediaIdentity &&
      other.provider == provider &&
      other.mediaId == mediaId;

  @override
  int get hashCode => Object.hash(provider, mediaId);
}

/// The deduplication key for a source: its media identity when known,
/// otherwise a normalized URL without tracking parameters.
String sourceKey(String source) {
  final identity = MediaIdentity.fromUrl(source);
  if (identity != null) return identity.key;
  final trimmed = source.trim();
  if (trimmed.isEmpty) return "";
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return trimmed;
  final query = uri.queryParametersAll;
  final names =
      query.keys
          .where((name) => !name.toLowerCase().startsWith("utm_"))
          .toList()
        ..sort();
  final filtered = [
    for (final name in names)
      for (final value in query[name]!)
        "${Uri.encodeQueryComponent(name)}=${Uri.encodeQueryComponent(value)}",
  ].join("&");
  var authority = uri.hasAuthority ? uri.authority.toLowerCase() : "";
  if (authority.startsWith("www.")) authority = authority.substring(4);
  final path = uri.path.replaceAll(RegExp(r"/+$"), "");
  final scheme = uri.scheme.toLowerCase();
  final buffer = StringBuffer();
  if (scheme.isNotEmpty) buffer.write("$scheme:");
  if (authority.isNotEmpty || scheme.isNotEmpty) buffer.write("//$authority");
  buffer.write(path);
  if (filtered.isNotEmpty) buffer.write("?$filtered");
  return buffer.toString();
}
