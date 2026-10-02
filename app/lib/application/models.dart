import "../core/media.dart";

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

int _int(Object? value, int fallback) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? fallback,
  _ => fallback,
};

double _double(Object? value, double fallback) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text) ?? fallback,
  _ => fallback,
};

String _string(Object? value, String fallback) =>
    value is String ? value : (value == null ? fallback : "$value");

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

class AppSettings {
  AppSettings({
    required this.downloadDirectory,
    this.volume = 5,
    this.previousVolume = 5,
    this.muted = false,
    this.theme = "system",
    this.audioFormat = "mp3",
    this.audioQuality = "best",
    // Audio extraction launches external encoder processes; two concurrent
    // jobs keep downloads responsive without overwhelming low-core devices.
    this.concurrentDownloads = 2,
    this.cookieFile = "",
    this.resumeSession = true,
    this.skipLoadingDelay = false,
    this.notifications = true,
    this.notificationActionPair = "shuffle_favorite",
    this.autoFocalPointLiveNotifications = false,
    this.accentColor = "violet",
  });

  String downloadDirectory;
  int volume;
  int previousVolume;
  bool muted;
  String theme;
  String audioFormat;
  String audioQuality;
  int concurrentDownloads;
  String cookieFile;
  bool resumeSession;
  bool skipLoadingDelay;
  bool notifications;
  String notificationActionPair;
  bool autoFocalPointLiveNotifications;
  String accentColor;

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
      audioFormat: _string(data["audio_format"], defaults.audioFormat),
      audioQuality: _string(data["audio_quality"], defaults.audioQuality),
      concurrentDownloads: _int(
        data["concurrent_downloads"],
        defaults.concurrentDownloads,
      ).clamp(1, 8),
      cookieFile: data["cookie_file"] is String
          ? data["cookie_file"] as String
          : "",
      resumeSession: _bool(data["resume_session"], defaults.resumeSession),
      skipLoadingDelay: data["skip_loading_delay"] == true,
      notifications: _bool(data["notifications"], defaults.notifications),
      notificationActionPair: notificationActionPairs.contains(pair)
          ? pair
          : defaults.notificationActionPair,
      autoFocalPointLiveNotifications:
          data["auto_focal_point_live_notifications"] == true,
      accentColor: _string(data["accent_color"], defaults.accentColor),
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
    "cookie_file": cookieFile,
    "resume_session": resumeSession,
    "skip_loading_delay": skipLoadingDelay,
    "notifications": notifications,
    "notification_action_pair": notificationActionPair,
    "auto_focal_point_live_notifications": autoFocalPointLiveNotifications,
    "accent_color": accentColor,
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
    duration: _double(data["duration"], 0),
    thumbnail: _string(data["thumbnail"], ""),
    favorite: data["favorite"] == true,
    playCount: _int(data["play_count"], 0),
    lastPlayed: _double(data["last_played"], 0),
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
    this.status = "queued",
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
  }) : createdAt = createdAt ?? DateTime.now().microsecondsSinceEpoch / 1e6,
       trackIds = trackIds ?? [];

  final String id;
  String url;
  String title;
  String uploader;
  String thumbnail;
  String source;
  String kind;
  String status;
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
    status: _string(data["status"], "queued"),
    progress: _double(data["progress"], 0),
    filename: _string(data["filename"], ""),
    downloadedBytes: _int(data["downloaded_bytes"], 0),
    totalBytes: _int(data["total_bytes"], 0),
    error: _string(data["error"], ""),
    errorKind: _string(data["error_kind"], ""),
    recovery: _string(data["recovery"], ""),
    createdAt: _double(data["created_at"], 0),
    completedAt: _double(data["completed_at"], 0),
    trackIds: [
      if (data["track_ids"] case final List<Object?> ids)
        for (final id in ids)
          if (id is String) id,
    ],
    batchId: _string(data["batch_id"], ""),
    batchPosition: _int(data["batch_position"], 0),
    batchSize: _int(data["batch_size"], 0),
  );

  Map<String, Object?> toJson() => {
    "id": id,
    "url": url,
    "title": title,
    "uploader": uploader,
    "thumbnail": thumbnail,
    "source": source,
    "kind": kind,
    "status": status,
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
