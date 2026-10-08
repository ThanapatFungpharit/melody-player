/// Failure vocabulary shared by the catalog, downloads, and the UI.
library;

import "dart:io";

import "media.dart";

/// A failure reported by the Python worker, with the facts needed to
/// classify it: the exception chain's messages, types, errno values, and
/// HTTP-like status codes.
class WorkerFailure implements Exception {
  WorkerFailure(
    this.message, {
    this.chain = const [],
    this.types = const [],
    this.errnos = const [],
    this.codes = const [],
    this.timeout = false,
    this.connection = false,
  });

  factory WorkerFailure.fromJson(Map<String, Object?> data) {
    List<T> list<T>(String key) => [
      if (data[key] case final List<Object?> values)
        for (final value in values)
          if (value is T) value,
    ];
    return WorkerFailure(
      switch (data["message"]) {
        final String message when message.isNotEmpty => message,
        _ => "The worker failed",
      },
      chain: list<String>("chain"),
      types: list<String>("types"),
      errnos: list<int>("errnos"),
      codes: list<String>("codes"),
      timeout: data["timeout"] == true,
      connection: data["connection"] == true,
    );
  }

  final String message;
  final List<String> chain;
  final List<String> types;
  final List<int> errnos;
  final List<String> codes;
  final bool timeout;
  final bool connection;

  @override
  String toString() => message;
}

enum DownloadErrorKind {
  network,
  authentication,
  unavailable,
  extractor,
  rateLimit("rate_limit"),
  disk,
  postprocessing,
  cancelled,
  unsupported,
  unknown;

  const DownloadErrorKind([this._value]);

  final String? _value;

  String get value => _value ?? name;
}

class DownloadFailure {
  const DownloadFailure(this.kind, this.message, this.recovery);

  final DownloadErrorKind kind;
  final String message;
  final String recovery;
}

// errno values that mean storage cannot be written, across platforms:
// ENOSPC, EDQUOT (Linux 122, macOS 69), EACCES, EROFS, EIO.
const _diskErrnos = {28, 122, 69, 13, 30, 5};
// The same conditions as Windows error codes: access denied, write
// protected, handle disk full, disk full.
const _windowsDiskErrors = {5, 19, 39, 112};

bool _hasAny(String text, List<String> words) => words.any(text.contains);

// The status code on its own, not digits inside a video ID (letters, digits,
// "-", and "_") that the message quotes.
final _tooManyRequests = RegExp(r"(?<![\w-])429(?![\w-])");

bool _isDiskError(FileSystemException error) {
  final code = error.osError?.errorCode;
  if (code == null) return false;
  return Platform.isWindows
      ? _windowsDiskErrors.contains(code)
      : _diskErrnos.contains(code);
}

/// Classifies a download failure into a stable kind and recovery action.
DownloadFailure classifyDownloadError(Object error) {
  final failure = error is WorkerFailure ? error : null;
  final message = ["$error", ...?failure?.chain].join(" ").toLowerCase();
  final types = failure?.types ?? const <String>[];
  final codes = failure?.codes ?? const <String>[];
  if (types.contains("CookieLoadError") ||
      _hasAny(message, [
        "cookie",
        "sign in",
        "login required",
        "authentication",
        "private video",
      ])) {
    return const DownloadFailure(
      DownloadErrorKind.authentication,
      "This media requires a valid session. Upload fresh Netscape cookies.txt "
          "in Settings, or remove cookies for public media.",
      "refresh_cookies",
    );
  }
  if (codes.contains("429") ||
      _tooManyRequests.hasMatch(message) ||
      _hasAny(message, ["too many requests", "rate limit"])) {
    return const DownloadFailure(
      DownloadErrorKind.rateLimit,
      "The provider is limiting requests. Wait before retrying.",
      "retry_later",
    );
  }
  if ((failure?.errnos.any(_diskErrnos.contains) ?? false) ||
      (error is FileSystemException && _isDiskError(error)) ||
      _hasAny(message, [
        "no space left",
        "disk full",
        "permission denied",
        "read-only file system",
      ])) {
    return const DownloadFailure(
      DownloadErrorKind.disk,
      "The file could not be written. Check free space and folder "
          "permissions, then retry.",
      "repair_storage",
    );
  }
  if (_hasAny(message, ["unsupported url", "unsupported scheme"])) {
    return const DownloadFailure(
      DownloadErrorKind.unsupported,
      "This URL is unsupported. Use a $youtubeMusicName media URL.",
      "change_url",
    );
  }
  if (_hasAny(message, [
    "video unavailable",
    "not available",
    "removed",
    "deleted",
    "copyright",
    "geo restricted",
  ])) {
    return const DownloadFailure(
      DownloadErrorKind.unavailable,
      "This media is unavailable. Choose another source.",
      "change_media",
    );
  }
  if (_hasAny(message, [
    "unable to extract",
    "extractor",
    "signature extraction",
    "nsig",
  ])) {
    return const DownloadFailure(
      DownloadErrorKind.extractor,
      "The provider's extractor failed. Install the latest Melody release, "
          "then retry.",
      "update_downloader",
    );
  }
  if (message.contains("thumbnail") &&
      _hasAny(message, ["embed", "embedded", "embedding"])) {
    return const DownloadFailure(
      DownloadErrorKind.postprocessing,
      "Cover artwork could not be embedded in the audio file. Retry the "
          "download or choose another audio format.",
      "retry",
    );
  }
  if ((failure?.timeout ?? false) ||
      (failure?.connection ?? false) ||
      _hasAny(message, [
        "timed out",
        "network",
        "connection",
        "name resolution",
        "urlopen error",
        "http error 5",
      ])) {
    return const DownloadFailure(
      DownloadErrorKind.network,
      "The network request failed. Check your connection and retry.",
      "retry",
    );
  }
  return const DownloadFailure(
    DownloadErrorKind.unknown,
    "The download failed. Retry or try another source.",
    "retry",
  );
}

/// A download could not be finished, with a message for classification.
class DownloadError implements Exception {
  DownloadError(this.message);

  final String message;

  @override
  String toString() => message;
}

const _technicalMarkers = [
  "[errno ",
  "[winerror ",
  "exception:",
  "traceback (most recent call last)",
];
final _sensitiveValue = RegExp(
  r"(?:https?://\S+|[A-Za-z]:[\\/]|(?:^|\s)/(?:[^\s/]+/)+|\\\\[^\\]+\\)",
  caseSensitive: false,
);
const _genericUserError =
    "The operation could not be completed. Please try again.";

/// Keeps user-facing failures concise and free of paths, URLs, or traces.
String publicErrorMessage(String message) {
  final compact = message
      .split(RegExp(r"\s+"))
      .where((part) => part.isNotEmpty)
      .join(" ");
  final lowered = compact.toLowerCase();
  if (compact.isEmpty ||
      compact.length > 240 ||
      _technicalMarkers.any(lowered.contains) ||
      _sensitiveValue.hasMatch(compact)) {
    return _genericUserError;
  }
  return compact;
}

/// The text to show for a failed action: the message of an argument, format,
/// or file error (the exceptions Melody raises for people to read), and the
/// error's own description otherwise. Pass it through [publicErrorMessage]
/// before showing anything that may carry paths.
String failureMessage(Object error) => switch (error) {
  ArgumentError(:final message) => "$message",
  FormatException(:final message) => message,
  FileSystemException(:final message, :final osError) =>
    osError == null ? message : "$message (${osError.message})",
  _ => "$error",
};

/// A provider (search/metadata) failure with a user-facing message.
class ProviderError implements Exception {
  ProviderError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Private media, or an uploaded cookie file yt-dlp could not load.
String? _sessionProblem(String lowered) {
  if (lowered.contains("private") || lowered.contains("sign in")) {
    return "This media is private or requires sign-in.";
  }
  if (lowered.contains("failed to load cookies") ||
      lowered.contains("cookies database")) {
    return "The uploaded cookie file could not be loaded. Upload a valid "
        "Netscape cookies.txt file in Settings, or remove it for anonymous access.";
  }
  return null;
}

String friendlyProviderError(Object error) {
  final message = "$error".trim();
  final lowered = message.toLowerCase();
  if (lowered.contains("unsupported url")) {
    return "Only $youtubeMusicName URLs are supported.";
  }
  if (lowered.contains("timed out") || lowered.contains("timeout")) {
    return "$youtubeMusicName took too long to respond. "
        "Check your connection and retry.";
  }
  final unreachable =
      error is WorkerFailure &&
      (error.connection ||
          error.types.any((type) => type.contains("ConnectionError")));
  if (unreachable ||
      lowered.contains("unable to download") ||
      lowered.contains("network") ||
      // requests (ytmusicapi) wraps DNS and socket failures this way.
      lowered.contains("max retries exceeded") ||
      lowered.contains("failed to resolve")) {
    return "$youtubeMusicName could not be reached. "
        "Check your connection and retry.";
  }
  if (_sessionProblem(lowered) case final message?) return message;
  return publicErrorMessage(
    message.isNotEmpty ? message : "$youtubeMusicName could not be searched.",
  );
}

String friendlyDownloadError(String message) {
  if (message.isEmpty) return "";
  final lowered = message.toLowerCase();
  if (lowered.contains("encoder not found") ||
      lowered.contains("unknown encoder")) {
    return "Melody's bundled FFmpeg is missing the selected audio encoder. "
        "Restart Melody to refresh its media tools, then retry.";
  }
  if ((lowered.contains("ffmpeg") &&
          (lowered.contains("not found") ||
              lowered.contains("not installed"))) ||
      lowered.contains("ffmpeg-location")) {
    return "Melody's bundled FFmpeg tools are unavailable. "
        "Reinstall the application and retry.";
  }
  if (lowered.contains("unsupported url")) {
    return "Only $youtubeMusicName URLs are supported.";
  }
  if (_sessionProblem(lowered) case final message?) return message;
  if (lowered.contains("timed out") || lowered.contains("network")) {
    return "The network request failed. Check your connection and retry.";
  }
  return publicErrorMessage(message);
}
