import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/errors.dart";

void main() {
  group("WorkerFailure.fromJson", () {
    test("keeps only correctly typed entries", () {
      final failure = WorkerFailure.fromJson({
        "message": "boom",
        "chain": ["outer", 3, "inner"],
        "types": ["OSError", null],
        "errnos": [28, "28"],
        "codes": ["429"],
        "timeout": true,
        "connection": "yes",
      });
      expect(failure.message, "boom");
      expect(failure.chain, ["outer", "inner"]);
      expect(failure.types, ["OSError"]);
      expect(failure.errnos, [28]);
      expect(failure.codes, ["429"]);
      expect(failure.timeout, isTrue);
      expect(failure.connection, isFalse);
      expect("$failure", "boom");
    });

    test("falls back to a default message and empty lists", () {
      final failure = WorkerFailure.fromJson({"chain": "not a list"});
      expect(failure.message, "The worker failed");
      expect(failure.chain, isEmpty);
      expect(failure.timeout, isFalse);
    });
  });

  group("classifyDownloadError", () {
    DownloadErrorKind kind(Object error) => classifyDownloadError(error).kind;

    test("recognizes authentication failures", () {
      expect(
        kind(WorkerFailure("failed", types: ["CookieLoadError"])),
        DownloadErrorKind.authentication,
      );
      expect(
        kind("Sign in to confirm your age"),
        DownloadErrorKind.authentication,
      );
      expect(
        classifyDownloadError("Private video").recovery,
        "refresh_cookies",
      );
    });

    test("authentication wins over a rate limit in the same message", () {
      expect(
        kind("HTTP Error 429 while loading cookies"),
        DownloadErrorKind.authentication,
      );
    });

    test("recognizes rate limits from codes and messages", () {
      expect(
        kind(WorkerFailure("failed", codes: ["429"])),
        DownloadErrorKind.rateLimit,
      );
      expect(
        kind("HTTP Error 429: Too Many Requests"),
        DownloadErrorKind.rateLimit,
      );
      expect(kind("Server answered 429"), DownloadErrorKind.rateLimit);
      expect(DownloadErrorKind.rateLimit.value, "rate_limit");
    });

    test("a 429 inside a quoted video ID is not a rate limit", () {
      for (final id in ["ab429cdefgh", "ab-429-defg", "a_429_bcdef"]) {
        expect(
          kind("ERROR: [youtube] $id: Video unavailable"),
          DownloadErrorKind.unavailable,
          reason: id,
        );
      }
      expect(DownloadErrorKind.network.value, "network");
    });

    test("recognizes disk failures from errnos, OS errors, and messages", () {
      expect(
        kind(WorkerFailure("failed", errnos: [28])),
        DownloadErrorKind.disk,
      );
      expect(
        kind(
          FileSystemException(
            "write failed",
            "song.mp3",
            OSError("", Platform.isWindows ? 112 : 28),
          ),
        ),
        DownloadErrorKind.disk,
      );
      expect(kind("No space left on device"), DownloadErrorKind.disk);
      expect(classifyDownloadError("disk full").recovery, "repair_storage");
    });

    test("recognizes unsupported, unavailable, and extractor failures", () {
      expect(kind("Unsupported URL: ftp://x"), DownloadErrorKind.unsupported);
      expect(kind("Video unavailable"), DownloadErrorKind.unavailable);
      expect(
        kind(WorkerFailure("failed", chain: ["This video has been removed"])),
        DownloadErrorKind.unavailable,
      );
      expect(kind("Unable to extract nsig"), DownloadErrorKind.extractor);
    });

    test("recognizes thumbnail embedding failures", () {
      expect(
        kind("Could not embed thumbnail"),
        DownloadErrorKind.postprocessing,
      );
      expect(kind("Thumbnail missing"), DownloadErrorKind.unknown);
    });

    test("recognizes network failures from flags and messages", () {
      expect(
        kind(WorkerFailure("failed", timeout: true)),
        DownloadErrorKind.network,
      );
      expect(
        kind(WorkerFailure("failed", connection: true)),
        DownloadErrorKind.network,
      );
      expect(kind("Read timed out"), DownloadErrorKind.network);
      expect(kind("HTTP Error 503"), DownloadErrorKind.network);
    });

    test("falls back to unknown with a retry", () {
      final failure = classifyDownloadError("Something odd happened");
      expect(failure.kind, DownloadErrorKind.unknown);
      expect(failure.recovery, "retry");
    });
  });

  group("publicErrorMessage", () {
    const generic = "The operation could not be completed. Please try again.";

    test("collapses whitespace in short messages", () {
      expect(publicErrorMessage("  Track\n  not   found "), "Track not found");
    });

    test("hides empty, long, and technical messages", () {
      expect(publicErrorMessage("   "), generic);
      expect(publicErrorMessage("x" * 241), generic);
      expect(publicErrorMessage("[Errno 2] No such file"), generic);
      expect(publicErrorMessage("[WinError 5] Access is denied"), generic);
      expect(
        publicErrorMessage("Traceback (most recent call last): ..."),
        generic,
      );
    });

    test("hides URLs and file paths", () {
      expect(publicErrorMessage("Failed https://example.com/a"), generic);
      expect(publicErrorMessage(r"Cannot open C:\Users\me\song.mp3"), generic);
      expect(publicErrorMessage("Cannot open /home/me/song.mp3"), generic);
      expect(publicErrorMessage(r"Cannot reach \\server\share"), generic);
    });
  });

  group("friendlyProviderError", () {
    test("explains unsupported URLs and timeouts", () {
      expect(
        friendlyProviderError("ERROR: Unsupported URL: x"),
        "Only YouTube Music URLs are supported.",
      );
      expect(
        friendlyProviderError("Request timeout"),
        startsWith("YouTube Music took too long"),
      );
    });

    test("explains unreachable providers", () {
      const unreachable =
          "YouTube Music could not be reached. "
          "Check your connection and retry.";
      expect(
        friendlyProviderError(WorkerFailure("x", connection: true)),
        unreachable,
      );
      expect(
        friendlyProviderError(
          WorkerFailure("x", types: ["requests.exceptions.ConnectionError"]),
        ),
        unreachable,
      );
      expect(friendlyProviderError("Max retries exceeded"), unreachable);
      expect(friendlyProviderError("Failed to resolve host"), unreachable);
    });

    test("explains session problems", () {
      expect(
        friendlyProviderError("Private video"),
        "This media is private or requires sign-in.",
      );
      expect(
        friendlyProviderError("Failed to load cookies"),
        startsWith("The uploaded cookie file could not be loaded."),
      );
    });

    test("passes short messages through and fills in empty ones", () {
      expect(friendlyProviderError("No results"), "No results");
      expect(friendlyProviderError(""), "YouTube Music could not be searched.");
    });
  });

  group("friendlyDownloadError", () {
    test("leaves empty messages empty", () {
      expect(friendlyDownloadError(""), "");
    });

    test("explains missing FFmpeg tools and encoders", () {
      expect(
        friendlyDownloadError("Unknown encoder 'libmp3lame'"),
        startsWith("Melody's bundled FFmpeg is missing"),
      );
      expect(
        friendlyDownloadError("ffmpeg not found"),
        startsWith("Melody's bundled FFmpeg tools are unavailable."),
      );
      expect(
        friendlyDownloadError("Bad --ffmpeg-location"),
        startsWith("Melody's bundled FFmpeg tools are unavailable."),
      );
    });

    test("explains URLs, sessions, and networks", () {
      expect(
        friendlyDownloadError("Unsupported URL"),
        "Only YouTube Music URLs are supported.",
      );
      expect(
        friendlyDownloadError("Sign in required"),
        "This media is private or requires sign-in.",
      );
      expect(
        friendlyDownloadError("Network is unreachable"),
        "The network request failed. Check your connection and retry.",
      );
    });

    test("sanitizes everything else", () {
      expect(friendlyDownloadError("Disk  quota"), "Disk quota");
      expect(
        friendlyDownloadError("Failed at /tmp/melody/x.part"),
        "The operation could not be completed. Please try again.",
      );
    });
  });

  group("failureMessage", () {
    test("shows the message of errors raised for people to read", () {
      expect(
        failureMessage(ArgumentError("Pick a playlist")),
        "Pick a playlist",
      );
      expect(
        failureMessage(const FormatException("Name cannot be empty")),
        "Name cannot be empty",
      );
      expect(
        failureMessage(
          const FileSystemException("Cannot delete", "x", OSError("Busy")),
        ),
        "Cannot delete (Busy)",
      );
      expect(failureMessage(ProviderError("Offline")), "Offline");
    });
  });
}
