import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/errors.dart" show failureMessage;
import "../core/library/manager.dart";
import "../core/library/models.dart";
import "../core/storage.dart";
import "lyrics.dart";
import "models.dart";
import "owned_files.dart";
import "store.dart";
import "thumbnails.dart";

/// Files every backend plays: ExoPlayer on Android, media_kit elsewhere.
const _portableAudioSuffixes = {
  ".mp3",
  ".m4a",
  ".m4b",
  ".aac",
  ".opus",
  ".ogg",
  ".oga",
  ".flac",
  ".wav",
  ".mka",
  ".webm",
  ".weba",
};

/// Files only media_kit's FFmpeg decoders play.
const _desktopAudioSuffixes = {".aif", ".aiff", ".wma", ".ape", ".wv"};

/// Audio files Melody imports and recognizes in the music folder.
final audioSuffixes = {
  ..._portableAudioSuffixes,
  if (!Platform.isAndroid) ..._desktopAudioSuffixes,
};

/// The ID of the app-managed Favorites playlist. It is not a UUID, so it
/// never collides with a playlist the user creates.
const favoritesPlaylistId = "favorites";

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

/// How many cleanup items an action fixed, and why the others were not.
class CleanupOutcome {
  const CleanupOutcome(this.done, this.failures);

  final int done;
  final List<String> failures;
}

class LibraryService {
  LibraryService(this.manager, this.store, {this.thumbnails, this.lyrics})
    : _files = OwnedFiles(store, manager);

  final MusicManager manager;
  final ApplicationStore store;

  /// Caches Melody fills for library tracks; a deleted track's entries go
  /// with it once no other track uses them.
  final ThumbnailCache? thumbnails;
  final LyricsLibrary? lyrics;
  final OwnedFiles _files;

  TrackDetails details(String trackId) => store.trackDetails(trackId);

  Map<String, TrackDetails> detailsMany(Iterable<String> trackIds) =>
      store.trackDetailsMany(trackIds);

  /// Repairs stale secondary metadata and reports ambiguous media. Missing
  /// tracks stay available for source-based repair; files without a download
  /// receipt are never adopted or deleted automatically.
  Future<LibraryReconciliation> reconcile() => manager.mutation.run(() async {
    final tracks = manager.listTracks();
    final removed = store.reconcileTrackReferences({
      for (final track in tracks) track.id,
    });
    // A stored path outside every music folder cannot be played: it counts
    // as missing instead of failing the whole check.
    final trackPaths = {for (final track in tracks) track.id: _pathOf(track)};
    // One background check for the whole library.
    final present = await existingFiles(trackPaths.values.nonNulls);
    final missing = [
      for (final MapEntry(key: id, value: path) in trackPaths.entries)
        if (path == null || !present.contains(path)) id,
    ];
    final paths = {
      for (final path in trackPaths.values.nonNulls) pathKey(path),
    };
    final unregistered = <String>[];
    final folder = Directory(manager.musicFolder);
    if (await folder.exists()) {
      await for (final entity in folder.list()) {
        final name = p.basename(entity.path);
        // Track paths have links resolved; compare listed files the same way.
        if (entity is File &&
            !name.startsWith(".") &&
            audioSuffixes.contains(p.extension(name).toLowerCase()) &&
            !paths.contains(pathKey(p.join(manager.musicRoot, name)))) {
          unregistered.add(entity.path);
        }
      }
    }
    return LibraryReconciliation(removed, missing, unregistered);
  });

  /// Registers audio files found in the music folder where they are, as
  /// local tracks whose files Melody keeps when they are removed. A file
  /// whose audio is already in the library is reported, not added.
  Future<CleanupOutcome> addStrayFiles(Iterable<String> paths) =>
      manager.mutation.run(() async {
        var done = 0;
        final failures = <String>[];
        for (final path in paths) {
          final name = p.basename(path);
          try {
            _requireStray(path);
            final existing = await manager.findTrackByContent(path);
            if (existing != null) {
              failures.add(
                "$name is already in the library as “${existing.displayTitle}”",
              );
              continue;
            }
            final trackId = await manager.addTrack(
              path,
              title: p.basenameWithoutExtension(path),
            );
            try {
              store.saveTrackDetails(
                trackId,
                TrackDetails(sourceName: "Local file"),
              );
            } catch (_) {
              manager.deleteTrack(trackId);
              rethrow;
            }
            done++;
          } on Object catch (error) {
            failures.add("$name: ${failureMessage(error)}");
          }
        }
        return CleanupOutcome(done, failures);
      });

  /// Deletes audio files in the music folder that no library track uses,
  /// with the lyrics beside them.
  Future<CleanupOutcome> deleteStrayFiles(Iterable<String> paths) =>
      manager.mutation.run(() async {
        var done = 0;
        final failures = <String>[];
        for (final path in paths) {
          try {
            _requireStray(path);
            final file = File(path);
            if (await file.exists()) await file.delete();
            await LyricsLibrary.deleteSidecar(path);
            done++;
          } on Object catch (error) {
            failures.add("${p.basename(path)}: ${failureMessage(error)}");
          }
        }
        return CleanupOutcome(done, failures);
      });

  /// Accepts only a top-level audio file in the music folder that no track
  /// uses, as [reconcile] reports them; the library may have changed since.
  void _requireStray(String path) {
    if (!samePath(p.dirname(path), manager.musicFolder) ||
        !audioSuffixes.contains(p.extension(path).toLowerCase())) {
      throw ArgumentError("Not an audio file in the music folder");
    }
    if (manager.isPathReferenced(path)) {
      throw ArgumentError("Already in the library");
    }
  }

  /// Whether [restoreLocalFile] can bring back [trackId]'s audio: it was
  /// imported and the original file is still there.
  Future<bool> canRestoreLocalFile(String trackId) async {
    final original = _originalFile(manager.getTrack(trackId));
    return original != null && await File(original).exists();
  }

  /// Copies an imported track's original file back into the library,
  /// keeping the track's identity and playlist membership.
  Future<void> restoreLocalFile(String trackId) =>
      manager.mutation.run(() async {
        final original = _originalFile(manager.getTrack(trackId));
        if (original == null || !await File(original).exists()) {
          throw ArgumentError("The original file is no longer available");
        }
        final path = manager.trackPath(trackId);
        if (!await File(path).exists()) {
          await Directory(p.dirname(path)).create(recursive: true);
          await atomicCopy(original, path);
        }
        await _importLyricsFile(original, path);
        await manager.replaceTrackFile(trackId, path);
      });

  static String? _originalFile(Track track) {
    final uri = Uri.tryParse(track.source);
    if (uri == null || uri.scheme != "file") return null;
    try {
      return uri.toFilePath();
    } on UnsupportedError {
      // Such as a file URI naming another host: not a local original.
      return null;
    }
  }

  TrackDetails toggleFavorite(String trackId) {
    // A stale row must not recreate details for a removed track.
    if (!manager.hasTrack(trackId)) {
      throw ArgumentError("This track is no longer in your library.");
    }
    final current = details(trackId);
    current.favorite = !current.favorite;
    store.saveTrackDetails(trackId, current);
    return current;
  }

  /// Favorites several tracks with a single durable store update.
  int favoriteTracks(Iterable<String> trackIds) =>
      store.favoriteTracks(trackIds);

  void recordPlay(String trackId, {Map<String, Object?>? playback}) =>
      store.recordPlay(trackId, playedAt: unixSeconds(), playback: playback);

  /// Whether Melody downloaded the track's file, so removing the track may
  /// delete it. Local imports and records without a source keep their file.
  static bool ownsFile(Track track) {
    final scheme = Uri.tryParse(track.source)?.scheme.toLowerCase();
    return scheme == "http" || scheme == "https";
  }

  /// The owned files of [tracks]' entries, which go with the entries:
  /// files Melody downloaded ([ownsFile]), or every file when [all].
  /// Other files only lose a `.lrc` Melody wrote beside them.
  List<String> _ownedPaths(Iterable<Track> tracks, {bool all = false}) => [
    for (final track in tracks)
      if (all || ownsFile(track)) ?_pathOf(track),
  ];

  /// The track's file, or null when its stored path is not in a music
  /// folder (then it is not Melody's to delete).
  String? _pathOf(Track track) {
    try {
      return manager.trackPath(track.id);
    } on ArgumentError {
      return null;
    }
  }

  /// Removes a library record with the file Melody downloaded for it, the
  /// `.lrc` beside that file, and the cached artwork and saved lyrics no
  /// other track uses. The file goes even if the operating system refuses
  /// now: it is deleted at a later launch ([OwnedFiles]).
  Future<void> deleteTrack(String trackId) => manager.mutation.run(() async {
    final track = manager.getTrack(trackId);
    final thumbnail = details(trackId).thumbnail;
    final owned = _ownedPaths([track]);
    _files.mark(owned);
    manager.deleteTrack(trackId);
    store.removeTrackDetails(trackId);
    await _files.release(owned);
    await _removeMelodySidecars([track]);
    await _forgetCaches([(track.source, thumbnail)]);
  });

  /// Removes every track and playlist record, every file Melody downloaded
  /// for them (with the `.lrc` beside it), and their cached artwork and
  /// saved lyrics. Imported copies stay on disk unless [deleteImported].
  /// Returns the track and playlist counts that were removed.
  Future<(int, int)> clearLibrary({bool deleteImported = false}) =>
      manager.mutation.run(() async {
        final tracks = manager.listTracks();
        final thumbnailsById = detailsMany([
          for (final track in tracks) track.id,
        ]);
        final owned = _ownedPaths(tracks, all: deleteImported);
        _files.mark(owned);
        final counts = manager.clearLibrary();
        store.clearLibraryData();
        await _files.release(owned);
        if (!deleteImported) await _removeMelodySidecars(tracks);
        await _forgetCaches([
          for (final track in tracks)
            (track.source, thumbnailsById[track.id]?.thumbnail ?? ""),
        ]);
        return counts;
      });

  /// Finishes file deletions an earlier launch could not. Call it at
  /// launch, before downloads open.
  Future<void> releasePendingFiles() => _files.releasePending();

  /// Removes `.lrc` files Melody wrote beside the kept files of [tracks].
  Future<void> _removeMelodySidecars(Iterable<Track> tracks) async {
    for (final track in tracks) {
      if (ownsFile(track)) continue;
      if (_pathOf(track) case final path?) {
        await LyricsLibrary.removeMelodySidecar(path);
      }
    }
  }

  Future<void> _forgetCaches(List<(String, String)> removed) async {
    final remaining = manager.listTracks();
    final cache = thumbnails;
    if (cache != null) {
      final inUse = {
        for (final other in detailsMany([
          for (final track in remaining) track.id,
        ]).values)
          other.thumbnail,
      };
      for (final thumbnail in {for (final (_, url) in removed) url}) {
        if (thumbnail.isNotEmpty && !inUse.contains(thumbnail)) {
          await cache.remove(thumbnail);
        }
      }
    }
    final keepFor = [for (final track in remaining) track.source];
    for (final source in {for (final (source, _) in removed) source}) {
      await lyrics?.forget(source, keepFor: keepFor);
    }
  }

  /// Drops cached artwork and saved lyrics that no library track uses, such
  /// as those of previews and of downloads that failed. Call it before
  /// downloads start: a finishing download caches its artwork and lyrics
  /// before its track is registered. Returns how many files were removed.
  Future<int> removeUnusedCaches() async {
    final tracks = manager.listTracks();
    final details = detailsMany([for (final track in tracks) track.id]);
    return await (thumbnails?.retainOnly([
              for (final item in details.values) item.thumbnail,
            ]) ??
            Future.value(0)) +
        await (lyrics?.retainOnly([for (final track in tracks) track.source]) ??
            Future.value(0));
  }

  void renameTrack(String trackId, String title) =>
      manager.updateTrack(trackId, title: title);

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
      final name = existing.title.isNotEmpty
          ? existing.title
          : existing.filename;
      throw FormatException("“$name” is already in the library");
    }
    final destination = availablePath(
      manager.musicFolder,
      p.basename(sourcePath),
    );
    await atomicCopy(sourcePath, destination);
    await _importLyricsFile(sourcePath, destination);
    final String trackId;
    try {
      trackId = await manager.addTrack(
        destination,
        source: Uri.file(sourcePath).toString(),
        title: p.basenameWithoutExtension(sourcePath),
      );
    } catch (_) {
      await deleteQuietly(destination);
      await LyricsLibrary.deleteSidecar(destination);
      rethrow;
    }
    try {
      store.saveTrackDetails(trackId, TrackDetails(sourceName: "Local file"));
    } catch (_) {
      // Registration and metadata live in separate stores; undo the first so
      // a failed import never leaves a half-imported track visible.
      try {
        manager.deleteTrack(trackId);
        await deleteQuietly(destination);
        await LyricsLibrary.deleteSidecar(destination);
      } on Object catch (error) {
        debugPrint("Could not roll back a local import: $error");
      }
      rethrow;
    }
    return trackId;
  }

  /// Brings along a `.lrc` beside the original, so its lyrics show for the
  /// copy. Lyrics are optional; a failure only logs.
  static Future<void> _importLyricsFile(String source, String copy) async {
    final lyrics = File(LyricsLibrary.sidecarPath(source));
    final target = File(LyricsLibrary.sidecarPath(copy));
    try {
      if (await lyrics.exists() && !await target.exists()) {
        await lyrics.copy(target.path);
      }
    } on FileSystemException catch (error) {
      debugPrint("Lyrics were not imported with $source: $error");
    }
  }

  List<Track> tracks({
    String query = "",
    String sort = "recent",
    int offset = 0,
    int? limit,
  }) => manager.searchTracks(query, offset: offset, limit: limit, sort: sort);

  List<Playlist> playlists() => manager.listPlaylists();

  /// Every favorite library track, newest first.
  List<Track> favoriteTrackList() =>
      manager.tracksByIds(store.favoriteTrackIds());

  /// The app-managed playlist of every favorite track. It follows the
  /// favorites, so it is never stored, renamed, reordered, or deleted.
  Playlist favoritesPlaylist() => Playlist(
    id: favoritesPlaylistId,
    name: "Favorites",
    trackIds: [for (final track in favoriteTrackList()) track.id],
  );

  /// An ordered M3U8 index of the managed library files.
  List<int> exportLibraryM3u8() => _m3u8(manager.listTracks());

  /// An M3U8 index in the playlist's saved track order.
  List<int> exportPlaylistM3u8(String playlistId) => _m3u8(
    playlistId == favoritesPlaylistId
        ? favoriteTrackList()
        : manager.playlistTracks(playlistId),
  );

  /// Tracks whose stored path is outside the music folders are left out:
  /// no player could open them.
  List<int> _m3u8(Iterable<Track> tracks) {
    final lines = ["#EXTM3U"];
    for (final track in tracks) {
      final path = _pathOf(track);
      if (path == null) continue;
      final title = track.displayTitle.split(RegExp(r"\s+")).join(" ");
      lines
        ..add("#EXTINF:-1,$title")
        ..add(Uri.file(p.normalize(p.absolute(path))).toString());
    }
    return utf8.encode("${lines.join("\n")}\n");
  }
}
