import "package:flutter_test/flutter_test.dart";
import "package:melody/core/media.dart";

const _watch = "https://music.youtube.com/watch?v=abc";

void main() {
  group("URL predicates", () {
    test("isHttpUrl accepts only HTTP schemes", () {
      expect(isHttpUrl(" HTTPS://example.com "), isTrue);
      expect(isHttpUrl("http://example.com"), isTrue);
      expect(isHttpUrl("ftp://example.com"), isFalse);
      expect(isHttpUrl("example.com"), isFalse);
    });

    test("isYoutubeUrl matches known hosts case-insensitively", () {
      expect(isYoutubeUrl("https://Music.YouTube.com/watch?v=abc"), isTrue);
      expect(isYoutubeUrl("https://youtu.be/abc"), isTrue);
      expect(isYoutubeUrl("https://notyoutube.com/watch?v=abc"), isFalse);
      expect(isYoutubeUrl("ftp://youtube.com/watch?v=abc"), isFalse);
    });

    test("isYoutubePlaylistUrl needs a non-empty list parameter", () {
      expect(
        isYoutubePlaylistUrl("https://music.youtube.com/playlist?list=PL1"),
        isTrue,
      );
      expect(
        isYoutubePlaylistUrl("https://www.youtube.com/watch?v=a&list=&list=RD"),
        isTrue,
      );
      expect(
        isYoutubePlaylistUrl("https://music.youtube.com/playlist?list="),
        isFalse,
      );
      expect(isYoutubePlaylistUrl(_watch), isFalse);
      expect(isYoutubePlaylistUrl("https://example.com/?list=PL1"), isFalse);
    });
  });

  group("youtubeMusicTrackUrl", () {
    test("builds a watch URL from a bare video ID", () {
      expect(youtubeMusicTrackUrl("", "abc"), _watch);
      expect(youtubeMusicTrackUrl("abc"), _watch);
      expect(youtubeMusicTrackUrl(""), "");
    });

    test("canonicalizes the YouTube URL shapes", () {
      for (final url in [
        "https://youtu.be/abc?t=10",
        "https://www.youtube.com/watch?v=abc&list=PL1",
        "https://m.youtube.com/watch/?v=abc",
        "https://www.youtube.com/shorts/abc/",
        "https://www.youtube.com/live/abc",
        "https://www.youtube-nocookie.com/embed/abc",
      ]) {
        expect(youtubeMusicTrackUrl(url), _watch, reason: url);
      }
    });

    test("falls back to the media ID when the URL has none", () {
      expect(
        youtubeMusicTrackUrl("https://www.youtube.com/watch", "abc"),
        _watch,
      );
      expect(youtubeMusicTrackUrl("https://youtu.be/", "abc"), _watch);
      expect(
        youtubeMusicTrackUrl("https://www.youtube.com/watch"),
        "https://www.youtube.com/watch",
      );
    });

    test("leaves other URLs unchanged", () {
      expect(
        youtubeMusicTrackUrl("https://example.com/watch?v=abc"),
        "https://example.com/watch?v=abc",
      );
      expect(
        youtubeMusicTrackUrl("https://www.youtube.com/channel/UC1", "abc"),
        "https://www.youtube.com/channel/UC1",
      );
    });
  });

  group("MediaIdentity", () {
    test("extracts the video ID from YouTube URLs", () {
      const expected = MediaIdentity(youtubeProviderId, "abc");
      for (final url in [
        "https://youtu.be/abc",
        _watch,
        "https://www.youtube.com/shorts/abc",
        "https://www.youtube.com/embed/abc",
        "https://www.youtube.com/live/abc/",
      ]) {
        expect(MediaIdentity.fromUrl(url), expected, reason: url);
      }
      expect(expected.key, "youtube:abc");
    });

    test("rejects non-YouTube, schemeless, and ID-less URLs", () {
      expect(MediaIdentity.fromUrl("https://example.com/watch?v=abc"), isNull);
      expect(MediaIdentity.fromUrl("youtube.com/watch?v=abc"), isNull);
      expect(MediaIdentity.fromUrl("ftp://youtube.com/watch?v=abc"), isNull);
      expect(
        MediaIdentity.fromUrl("https://music.youtube.com/playlist?list=PL"),
        isNull,
      );
      expect(MediaIdentity.fromUrl("https://www.youtube.com/a/b/c"), isNull);
    });

    test("compares by provider and media ID", () {
      const a = MediaIdentity("youtube", "abc");
      expect(a, const MediaIdentity("youtube", "abc"));
      expect(a.hashCode, const MediaIdentity("youtube", "abc").hashCode);
      expect(a, isNot(const MediaIdentity("youtube", "abd")));
      expect(a, isNot(const MediaIdentity("other", "abc")));
    });
  });

  group("sourceKey", () {
    test("uses the media identity for YouTube sources", () {
      expect(sourceKey("https://youtu.be/abc"), "youtube:abc");
      expect(sourceKey("$_watch&utm_source=x"), "youtube:abc");
    });

    test("normalizes other URLs", () {
      expect(
        sourceKey(" https://WWW.Example.com/a/b/?utm_source=x&b=2&a=1 "),
        "https://example.com/a/b?a=1&b=2",
      );
      expect(
        sourceKey("https://example.com/x?UTM_medium=y"),
        "https://example.com/x",
      );
      expect(
        sourceKey("https://example.com/x?a=2&a=1"),
        "https://example.com/x?a=2&a=1",
      );
    });

    test("keeps blank and non-URL values recognizable", () {
      expect(sourceKey("   "), "");
      expect(sourceKey("local/song.mp3"), "local/song.mp3");
    });
  });
}
