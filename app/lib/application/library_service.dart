import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/library/manager.dart";
import "../core/library/models.dart";
import "../core/storage.dart";
import "models.dart";
import "store.dart";

const audioSuffixes = {".mp3", ".m4a", ".opus", ".wav", ".flac", ".ogg", ".aac"};

class LibraryReconciliation {
  const LibraryReconciliation(
    this.staleReferencesRemoved,
    this.missingTrackIds,
    this.unregisteredFiles,
  );

  final int staleReferencesRemoved;
  final List<String> missingTrackIds;
  final List<String> unregisteredFiles;
}

class LibraryService {
  LibraryService(this.manager, this.store);

  final MusicManager manager;
  final ApplicationStore store;

  TrackDetails details(String trackId) => store.trackDetails(trackId);

  Map<String, TrackDetails> detailsMany(Iterable<String> trackIds) =>
      store.trackDetailsMany(trackIds);

  /// Repairs stale secondary metadata and reports ambiguous media. Missing
  /// tracks stay available for source-based repair; files without a download
  /// receipt are never adopted or deleted automatically.
  Future<LibraryReconciliation> reconcile() => manager.mutation.run(() async {
    final tracks = manager.listTracks();
    final removed = store.reconcileTrackReferences({for (final track in tracks) track.id});
    final paths = <String>{};
    final missing = <String>[];
    for (final track in tracks) {
      final path = manager.trackPath(track.id);
      paths.add(_comparable(path));
      if (!await File(path).exists()) missing.add(track.id);
    }
    final unregistered = <String>[];
    final folder = Directory(manager.musicFolder);
    if (await folder.exists()) {
      await for (final entity in folder.list()) {
        final name = p.basename(entity.path);
        if (entity is File &&
            !name.startsWith(".") &&
            audioSuffixes.contains(p.extension(name).toLowerCase()) &&
            !paths.contains(_comparable(entity.path))) {
          unregistered.add(entity.path);
        }
      }
    }
    return LibraryReconciliation(removed, missing, unregistered);
  });

  static String _comparable(String path) {
    final absolute = p.normalize(p.absolute(path));
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  TrackDetails toggleFavorite(String trackId) {
    final current = details(trackId);
    current.favorite = !current.favorite;
    store.saveTrackDetails(trackId, current);
    return current;
  }

  /// Favorites several tracks with a single durable store update.
  int favoriteTracks(Iterable<String> trackIds) => store.favoriteTracks(trackIds);

  void recordPlay(String trackId, {Map<String, Object?>? playback}) => store.recordPlay(
    trackId,
    playedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
    playback: playback,
  );

  /// Removes a library record and, when asked, the media file it owns.
  Future<void> deleteTrack(String trackId, {bool deleteFile = false}) =>
      manager.mutation.run(() async {
        final path = manager.trackPath(trackId);
        if (deleteFile && !manager.isPathReferenced(path, excluding: trackId)) {
          // Keep the record for retry if the OS refuses to remove the file.
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
        manager.deleteTrack(trackId);
        store.removeTrackDetails(trackId);
      });

  Future<void> deleteTrackAndFile(String trackId) => deleteTrack(trackId, deleteFile: true);

  void renameTrack(String trackId, String title) => manager.renameTrack(trackId, title);

  /// Copies an existing audio file into the managed folder and registers it.
  Future<String> importLocalFile(String source) =>
      manager.mutation.run(() => _importLocalFile(source));

  Future<String> _importLocalFile(String source) async {
    final sourcePath = p.normalize(p.absolute(source));
    if (!await File(sourcePath).exists()) {
      throw PathNotFoundException(sourcePath, const OSError("File not found"));
    }
    final extension = p.extension(sourcePath).toLowerCase();
    if (!audioSuffixes.contains(extension)) {
      throw FormatException(
        "Unsupported audio format: ${extension.isEmpty ? "unknown" : extension}",
      );
    }
    final existing = await manager.findTrackByContent(sourcePath);
    if (existing != null) {
      final name = existing.title.isNotEmpty ? existing.title : existing.filename;
      throw FormatException("“$name” is already in the library");
    }
    final destination = _availableDestination(p.basename(sourcePath));
    await atomicCopy(sourcePath, destination);
    final String trackId;
    try {
      trackId = await manager.addTrack(
        destination,
        source: Uri.file(sourcePath).toString(),
        title: p.basenameWithoutExtension(sourcePath),
      );
    } catch (_) {
      await _deleteQuietly(destination);
      rethrow;
    }
    try {
      store.saveTrackDetails(trackId, TrackDetails(sourceName: "Local file"));
    } catch (_) {
      // Registration and metadata live in separate stores; undo the first so
      // a failed import never leaves a half-imported track visible.
      try {
        manager.deleteTrack(trackId);
        await _deleteQuietly(destination);
      } on Object catch (error) {
        debugPrint("Could not roll back a local import: $error");
      }
      rethrow;
    }
    return trackId;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint("Could not remove $path: $error");
    }
  }

  String _availableDestination(String name) {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var destination = p.join(manager.musicFolder, name);
    var counter = 1;
    while (File(destination).existsSync()) {
      counter++;
      destination = p.join(manager.musicFolder, "$stem ($counter)$extension");
    }
    return destination;
  }

  List<Track> tracks({String query = "", String sort = "recent", int offset = 0, int? limit}) =>
      manager.searchTracks(query, offset: offset, limit: limit, sort: sort);

  List<Playlist> playlists() => manager.listPlaylists();

  /// An ordered M3U8 index of the managed library files.
  List<int> exportLibraryM3u8() => _m3u8(manager.listTracks());

  /// An M3U8 index in the playlist's saved track order.
  List<int> exportPlaylistM3u8(String playlistId) =>
      _m3u8(manager.playlistTracks(playlistId));

  List<int> _m3u8(Iterable<Track> tracks) {
    final lines = ["#EXTM3U"];
    for (final track in tracks) {
      final title = track.displayTitle.split(RegExp(r"\s+")).join(" ");
      lines
        ..add("#EXTINF:-1,$title")
        ..add(Uri.file(p.normalize(p.absolute(manager.trackPath(track.id)))).toString());
    }
    return utf8.encode("${lines.join("\n")}\n");
  }
}
