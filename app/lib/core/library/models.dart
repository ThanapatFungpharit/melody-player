import "package:path/path.dart" as p;

class Track {
  Track({
    required this.id,
    required this.filename,
    this.source = "",
    this.title = "",
    required this.addedAt,
    this.contentHash = "",
  });

  final String id;
  String filename;
  String source;
  String title;

  /// Seconds since the Unix epoch.
  final double addedAt;
  String contentHash;

  Track copy() => Track(
    id: id,
    filename: filename,
    source: source,
    title: title,
    addedAt: addedAt,
    contentHash: contentHash,
  );

  /// The visible title: the stored title or the file's stem.
  String get displayTitle {
    final trimmed = title.trim();
    return trimmed.isNotEmpty ? trimmed : p.basenameWithoutExtension(filename);
  }
}

class Playlist {
  Playlist({
    required this.id,
    required this.name,
    this.source = "",
    List<String>? trackIds,
  }) : trackIds = trackIds ?? [];

  final String id;
  String name;

  /// The link it was imported from, so it can be updated; empty for others.
  final String source;
  List<String> trackIds;

  Playlist copy() =>
      Playlist(id: id, name: name, source: source, trackIds: List.of(trackIds));
}

class TrackFileProblem {
  const TrackFileProblem(this.trackId, this.filename, this.kind, this.message);

  final String trackId;
  final String filename;

  /// invalid_path, missing, unreadable, or empty.
  final String kind;
  final String message;
}
