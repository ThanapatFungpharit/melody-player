import "dart:math";

import "../core/downloader/downloader.dart";
import "../core/media.dart";
import "../core/storage.dart";

export "../core/downloader/downloader.dart" show DownloadStatus;

enum RepeatMode {
  off("off"),
  track("track"),
  playlist("playlist");

  const RepeatMode(this.value);

  final String value;

  static RepeatMode parse(Object? value) => RepeatMode.values.firstWhere(
    (mode) => mode.value == value,
    orElse: () => RepeatMode.off,
  );
}

const notificationActionPairs = [
  "shuffle_favorite",
  "shuffle_repeat",
  "repeat_favorite",
];

/// A codec yt-dlp can extract downloads to, by its `preferredcodec` name.
///
/// Every format here can carry cover art and lyrics tags, which downloads
/// verify; raw AAC and WAV cannot, so they are not offered.
enum DownloadFormat {
  mp3(
    "mp3",
    "MP3",
    ".mp3",
    "Plays on everything: car stereos, old players, any app.",
  ),
  m4a(
    "m4a",
    "M4A (AAC)",
    ".m4a",
    "Smaller than MP3 at the same quality; ideal for Apple devices.",
  ),
  opus(
    "opus",
    "Opus",
    ".opus",
    "Best sound for the size. YouTube audio is usually Opus already, "
        "so it is saved without re-encoding.",
  ),
  vorbis(
    "vorbis",
    "Ogg Vorbis",
    ".ogg",
    "Open format for players and games that support Ogg but not Opus.",
  ),
  flac(
    "flac",
    "FLAC (lossless)",
    ".flac",
    "Avoids a second lossy encode for editing or archiving. Much larger, "
        "and no better than the source.",
    lossless: true,
  ),
  alac(
    "alac",
    "ALAC (lossless)",
    ".m4a",
    "Lossless like FLAC, for Apple Music and iTunes libraries.",
    lossless: true,
  );

  const DownloadFormat(
    this.codec,
    this.label,
    this.extension,
    this.reason, {
    this.lossless = false,
  });

  final String codec;
  final String label;

  /// When to pick this format, shown in settings.
  final String reason;

  /// The suffix yt-dlp gives the extracted file.
  final String extension;

  /// Lossless codecs ignore the quality setting.
  final bool lossless;

  static DownloadFormat parse(Object? value) => DownloadFormat.values
      .firstWhere((format) => format.codec == value, orElse: () => mp3);
}

// Stored numbers may be hand-edited or written by an older version: a
// non-finite value (`1e999` decodes to infinity) falls back instead of
// throwing on toInt() or spreading NaN into layout and progress math.
int _int(Object? value, int fallback) => switch (value) {
  int number => number,
  num number when number.isFinite => number.toInt(),
  String text => switch (num.tryParse(text.trim())) {
    final num number when number.isFinite => number.toInt(),
    _ => fallback,
  },
  _ => fallback,
};

double _double(Object? value, double fallback) => switch (value) {
  num number when number.isFinite => number.toDouble(),
  String text => switch (double.tryParse(text.trim())) {
    final double number when number.isFinite => number,
    _ => fallback,
  },
  _ => fallback,
};

int _count(Object? value) => max(0, _int(value, 0));

double _seconds(Object? value) => max(0, _double(value, 0));

String _string(Object? value, String fallback) =>
    value is String ? value : (value == null ? fallback : "$value");

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

/// How long finished downloads stay listed, in days; 0 means forever.
const downloadHistoryChoices = [1, 7, 30, 90, 0];

/// Loudness normalization targets in LUFS, loudest first.
const loudnessTargetChoices = [-11, -14, -16, -18, -23];

class AppSettings {
  AppSettings({
    required this.downloadDirectory,
    this.volume = 25,
    this.previousVolume = 25,
    this.muted = false,
    this.theme = "system",
    this.audioFormat = "mp3",
    this.audioQuality = "best",
    // Audio extraction launches external encoder processes; two concurrent
    // jobs keep downloads responsive without overwhelming low-core devices.
    this.concurrentDownloads = 2,
    this.resumeSession = true,
    this.notifications = true,
    this.notificationActionPair = "shuffle_favorite",
    this.autoFocalPointLiveNotifications = false,
    this.accentColor = "violet",
    this.downloadHistoryDays = 30,
    this.normalizeLoudness = true,
    this.loudnessTarget = -14,
  });

  String downloadDirectory;
  int volume;
  int previousVolume;
  bool muted;
  String theme;
  String audioFormat;
  String audioQuality;
  int concurrentDownloads;
  bool resumeSession;
  bool notifications;
  String notificationActionPair;
  bool autoFocalPointLiveNotifications;
  String accentColor;

  /// Days a finished download stays in the history; 0 keeps it forever.
  int downloadHistoryDays;

  /// Plays every track at a similar loudness (`application/loudness.dart`).
  bool normalizeLoudness;

  /// The loudness tracks are brought down to, in LUFS; one of
  /// [loudnessTargetChoices].
  int loudnessTarget;

  DownloadFormat get downloadFormat => DownloadFormat.parse(audioFormat);

  factory AppSettings.fromJson(
    Map<String, Object?> data, {
    required String defaultDownloadDirectory,
  }) {
    final defaults = AppSettings(downloadDirectory: defaultDownloadDirectory);
    final pair = _string(
      data["notification_action_pair"],
      defaults.notificationActionPair,
    );
    return AppSettings(
      downloadDirectory: _string(
        data["download_directory"],
        defaults.downloadDirectory,
      ),
      volume: _int(data["volume"], defaults.volume).clamp(0, 100),
      previousVolume: _int(
        data["previous_volume"],
        defaults.previousVolume,
      ).clamp(1, 100),
      muted: _bool(data["muted"], defaults.muted),
      theme: _string(data["theme"], defaults.theme),
      audioFormat: DownloadFormat.parse(data["audio_format"]).codec,
      audioQuality: _string(data["audio_quality"], defaults.audioQuality),
      concurrentDownloads: _int(
        data["concurrent_downloads"],
        defaults.concurrentDownloads,
      ).clamp(1, 8),
      resumeSession: _bool(data["resume_session"], defaults.resumeSession),
      notifications: _bool(data["notifications"], defaults.notifications),
      notificationActionPair: notificationActionPairs.contains(pair)
          ? pair
          : defaults.notificationActionPair,
      autoFocalPointLiveNotifications:
          data["auto_focal_point_live_notifications"] == true,
      accentColor: _string(data["accent_color"], defaults.accentColor),
      downloadHistoryDays: switch (data["download_history_days"]) {
        final int days when downloadHistoryChoices.contains(days) => days,
        _ => defaults.downloadHistoryDays,
      },
      normalizeLoudness: _bool(
        data["normalize_loudness"],
        defaults.normalizeLoudness,
      ),
      loudnessTarget: switch (data["loudness_target"]) {
        final int target when loudnessTargetChoices.contains(target) => target,
        _ => defaults.loudnessTarget,
      },
    );
  }

  Map<String, Object?> toJson() => {
    "download_directory": downloadDirectory,
    "volume": volume,
    "previous_volume": previousVolume,
    "muted": muted,
    "theme": theme,
    "audio_format": audioFormat,
    "audio_quality": audioQuality,
    "concurrent_downloads": concurrentDownloads,
    "resume_session": resumeSession,
    "notifications": notifications,
    "notification_action_pair": notificationActionPair,
    "auto_focal_point_live_notifications": autoFocalPointLiveNotifications,
    "accent_color": accentColor,
    "download_history_days": downloadHistoryDays,
    "normalize_loudness": normalizeLoudness,
    "loudness_target": loudnessTarget,
  };

  AppSettings copy() => AppSettings.fromJson(
    toJson(),
    defaultDownloadDirectory: downloadDirectory,
  );

  bool sameAs(AppSettings other) {
    final mine = toJson();
    final theirs = other.toJson();
    return mine.keys.every((key) => mine[key] == theirs[key]);
  }
}

class TrackDetails {
  TrackDetails({
    this.uploader = "",
    this.duration = 0,
    this.thumbnail = "",
    this.favorite = false,
    this.playCount = 0,
    this.lastPlayed = 0,
    this.sourceName = "Local",
  });

  String uploader;
  double duration;
  String thumbnail;
  bool favorite;
  int playCount;
  double lastPlayed;
  String sourceName;

  factory TrackDetails.fromJson(Map<String, Object?> data) => TrackDetails(
    // Before version 0.2 the uploader/channel was stored as an artist.
    uploader: _string(data["uploader"] ?? data["artist"], ""),
    duration: _seconds(data["duration"]),
    thumbnail: _string(data["thumbnail"], ""),
    favorite: data["favorite"] == true,
    playCount: _count(data["play_count"]),
    lastPlayed: _seconds(data["last_played"]),
    sourceName: _string(data["source_name"], "Local"),
  );

  Map<String, Object?> toJson() => {
    "uploader": uploader,
    "duration": duration,
    "thumbnail": thumbnail,
    "favorite": favorite,
    "play_count": playCount,
    "last_played": lastPlayed,
    "source_name": sourceName,
  };

  /// The visible credit line for a track.
  String get credit {
    final name = uploader.trim();
    if (name.isNotEmpty) return name;
    final source = sourceName.trim();
    return source.isNotEmpty ? source : "Unknown source";
  }
}

class SearchResult {
  const SearchResult({
    required this.id,
    required this.title,
    required this.uploader,
    required this.duration,
    required this.thumbnail,
    required this.url,
    required this.source,
    this.providerId = youtubeProviderId,
    this.kind = "track",
    this.playlistTitle = "",
    this.entryCount = 0,
  });

  final String id;
  final String title;
  final String uploader;
  final double duration;
  final String thumbnail;
  final String url;
  final String source;
  final String providerId;
  final String kind;
  final String playlistTitle;
  final int entryCount;

  bool get isPlaylist => kind == "playlist";

  SearchResult withPlaylistTitle(String title) => SearchResult(
    id: id,
    title: this.title,
    uploader: uploader,
    duration: duration,
    thumbnail: thumbnail,
    url: url,
    source: source,
    providerId: providerId,
    kind: kind,
    playlistTitle: title,
    entryCount: entryCount,
  );

  MediaIdentity? get identity {
    if (isPlaylist) return null;
    return MediaIdentity.fromUrl(url) ??
        (id.isNotEmpty ? MediaIdentity(providerId, id) : null);
  }
}

class DownloadRecord {
  DownloadRecord({
    required this.id,
    required this.url,
    required this.title,
    this.uploader = "",
    this.thumbnail = "",
    this.source = youtubeMusicName,
    this.kind = "track",
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.filename = "",
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.error = "",
    this.errorKind = "",
    this.recovery = "",
    double? createdAt,
    this.completedAt = 0,
    List<String>? trackIds,
    this.batchId = "",
    this.batchPosition = 0,
    this.batchSize = 0,
  }) : createdAt = createdAt ?? unixSeconds(),
       trackIds = trackIds ?? [];

  final String id;
  String url;
  String title;
  String uploader;
  String thumbnail;
  String source;
  String kind;
  DownloadStatus status;
  double progress;
  String filename;
  int downloadedBytes;
  int totalBytes;
  String error;
  String errorKind;
  String recovery;
  double createdAt;
  double completedAt;
  List<String> trackIds;
  String batchId;
  int batchPosition;
  int batchSize;

  factory DownloadRecord.fromJson(Map<String, Object?> data) => DownloadRecord(
    id: _string(data["id"], ""),
    url: _string(data["url"], ""),
    title: _string(data["title"], ""),
    uploader: _string(data["uploader"] ?? data["artist"], ""),
    thumbnail: _string(data["thumbnail"], ""),
    source: _string(data["source"], youtubeMusicName),
    kind: _string(data["kind"], "track"),
    status: DownloadStatus.parse(data["status"]),
    progress: _double(data["progress"], 0).clamp(0.0, 1.0),
    filename: _string(data["filename"], ""),
    downloadedBytes: _count(data["downloaded_bytes"]),
    totalBytes: _count(data["total_bytes"]),
    error: _string(data["error"], ""),
    errorKind: _string(data["error_kind"], ""),
    recovery: _string(data["recovery"], ""),
    createdAt: _seconds(data["created_at"]),
    completedAt: _seconds(data["completed_at"]),
    trackIds: [
      if (data["track_ids"] case final List<Object?> ids)
        for (final id in ids)
          if (id is String) id,
    ],
    batchId: _string(data["batch_id"], ""),
    batchPosition: _count(data["batch_position"]),
    batchSize: _count(data["batch_size"]),
  );

  Map<String, Object?> toJson() => {
    "id": id,
    "url": url,
    "title": title,
    "uploader": uploader,
    "thumbnail": thumbnail,
    "source": source,
    "kind": kind,
    "status": status.name,
    "progress": progress,
    "filename": filename,
    "downloaded_bytes": downloadedBytes,
    "total_bytes": totalBytes,
    "error": error,
    "error_kind": errorKind,
    "recovery": recovery,
    "created_at": createdAt,
    "completed_at": completedAt,
    "track_ids": trackIds,
    "batch_id": batchId,
    "batch_position": batchPosition,
    "batch_size": batchSize,
  };

  DownloadRecord copy() => DownloadRecord.fromJson(toJson());
}
