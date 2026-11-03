import "dart:convert";
import "dart:io";
import "dart:isolate";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../core/artwork.dart";
import "../core/errors.dart" show failureMessage;
import "../core/library/manager.dart";
import "../core/library/models.dart";
import "../core/media.dart" show MediaIdentity, isHttpUrl, youtubeMusicTrackUrl;
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

  /// What shows a track's cover: its cached copy, or its remote artwork until
  /// there is one. Empty when it has neither.
  String artwork(String trackId) =>
      thumbnails?.cachedPath(trackId) ?? details(trackId).thumbnail;

  /// A track's cover for system media controls.
  String artworkUri(String trackId) =>
      thumbnails?.artworkUri(trackId) ?? details(trackId).thumbnail;

  /// Remembers a track's length the first time the decoder reports it, for
  /// files nothing else has named one for.
  void rememberDuration(String trackId, double seconds) {
    if (seconds <= 0 || !manager.hasTrack(trackId)) return;
    final current = details(trackId);
    if (current.duration > 0) return;
    store.saveTrackDetails(trackId, current..duration = seconds);
  }

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
      await for (final entity in folder.list(
        recursive: true,
        followLinks: false,
      )) {
        final name = p.relative(entity.path, from: manager.musicFolder);
        // Track paths have links resolved; compare listed files the same way.
        if (entity is File &&
            _isVisibleAudio(name) &&
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
            final file = await _readFile(path);
            final trackId = await manager.addTrack(
              path,
              title: file.title(p.basenameWithoutExtension(path)),
            );
            try {
              store.saveTrackDetails(
                trackId,
                TrackDetails(uploader: file.artist, sourceName: "Local file"),
              );
              await thumbnails?.store(trackId, file.artwork);
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

  /// Whether a path relative to a folder names an audio file Melody would
  /// list: not itself, or inside, anything hidden.
  static bool _isVisibleAudio(String relative) =>
      audioSuffixes.contains(p.extension(relative).toLowerCase()) &&
      !p.split(relative).any((part) => part.startsWith("."));

  /// Audio files anywhere under [folder], in name order. Lists the folder in a
  /// background isolate.
  static Future<List<String>> audioFilesIn(String folder) => Isolate.run(
    () => [
      for (final entity in Directory(
        folder,
      ).listSync(recursive: true, followLinks: false))
        if (entity is File &&
            _isVisibleAudio(p.relative(entity.path, from: folder)))
          entity.path,
    ]..sort(),
  );

  /// Accepts only an audio file in the music folder that no track uses, as
  /// [reconcile] reports them; the library may have changed since.
  void _requireStray(String path) {
    if (!p.isWithin(manager.musicFolder, path) ||
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
    // A track favorited again joins the end, not its old place.
    final order = store.favoritesOrder();
    if (!current.favorite && order.contains(trackId)) {
      store.saveFavoritesOrder([
        for (final id in order)
          if (id != trackId) id,
      ]);
    }
    return current;
  }

  /// Favorites several tracks with a single durable store update.
  int favoriteTracks(Iterable<String> trackIds) =>
      store.favoriteTracks(trackIds);

  /// Whether Melody downloaded the track's file.
  static bool isDownload(Track track) {
    final scheme = Uri.tryParse(track.source)?.scheme.toLowerCase();
    return scheme == "http" || scheme == "https";
  }

  /// Whether Melody put the track's file where it is, by downloading it or by
  /// copying it on import, so deleting the track may delete it. A record
  /// without a source is a file adopted where it already was, and stays.
  static bool ownsFile(Track track) =>
      isDownload(track) || _originalFile(track) != null;

  /// The files that go with [tracks]' entries, as [goes] says. Other files
  /// only lose a `.lrc` Melody wrote beside them.
  List<String> _pathsToDelete(
    Iterable<Track> tracks,
    bool Function(Track track) goes,
  ) => [
    for (final track in tracks)
      if (goes(track)) ?_pathOf(track),
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

  /// Removes a library record with the file Melody put there for it (never an
  /// original it was imported from), the `.lrc` beside that file, and the
  /// cached artwork and saved lyrics no other track uses. The file goes even if the operating system refuses
  /// now: it is deleted at a later launch ([OwnedFiles]).
  Future<void> deleteTrack(String trackId) => manager.mutation.run(() async {
    final track = manager.getTrack(trackId);
    final owned = _pathsToDelete([track], ownsFile);
    _files.mark(owned);
    manager.deleteTrack(trackId);
    store.removeTrackDetails(trackId);
    await _files.release(owned);
    await _removeMelodySidecars([track], ownsFile);
    await _forgetCaches([track]);
  });

  /// Removes every track and playlist record, every file Melody downloaded
  /// for them (with the `.lrc` beside it), and their cached artwork and
  /// saved lyrics. Copies of imported files stay on disk unless
  /// [deleteImported], in case they are the only ones left.
  /// Returns the track and playlist counts that were removed.
  Future<(int, int)> clearLibrary({bool deleteImported = false}) =>
      manager.mutation.run(() async {
        final tracks = manager.listTracks();
        final owned = _pathsToDelete(
          tracks,
          deleteImported ? (_) => true : isDownload,
        );
        _files.mark(owned);
        final counts = manager.clearLibrary();
        store.clearLibraryData();
        await _files.release(owned);
        if (!deleteImported) {
          await _removeMelodySidecars(tracks, isDownload);
        }
        await _forgetCaches(tracks);
        return counts;
      });

  /// Finishes file deletions an earlier launch could not. Call it at
  /// launch, before downloads open.
  Future<void> releasePendingFiles() => _files.releasePending();

  /// Removes `.lrc` files Melody wrote beside the kept files of [tracks].
  Future<void> _removeMelodySidecars(
    Iterable<Track> tracks,
    bool Function(Track track) deleted,
  ) async {
    for (final track in tracks) {
      if (deleted(track)) continue;
      if (_pathOf(track) case final path?) {
        await LyricsLibrary.removeMelodySidecar(path);
      }
    }
  }

  Future<void> _forgetCaches(List<Track> removed) async {
    final keepFor = [for (final track in manager.listTracks()) track.source];
    for (final track in removed) {
      await thumbnails?.remove(track.id);
      await lyrics?.forget(track.source, keepFor: keepFor);
    }
  }

  /// Drops cached artwork and saved lyrics that no library track uses, such
  /// as those of downloads that failed. Call it before
  /// downloads start: a finishing download caches its artwork and lyrics
  /// before its track is registered. Returns how many files were removed.
  Future<int> removeUnusedCaches() async {
    final tracks = manager.listTracks();
    final artwork =
        await thumbnails?.retainOnly([for (final track in tracks) track.id]) ??
        0;
    final saved =
        await lyrics?.retainOnly([for (final track in tracks) track.source]) ??
        0;
    return artwork + saved;
  }

  void renameTrack(String trackId, String title) =>
      manager.updateTrack(trackId, title: title);

  void setArtist(String trackId, String artist) {
    final current = details(trackId);
    final name = artist.trim();
    if (current.uploader != name) {
      store.saveTrackDetails(trackId, current..uploader = name);
    }
  }

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
    final file = await _readFile(destination);
    final String trackId;
    try {
      trackId = await manager.addTrack(
        destination,
        source: Uri.file(sourcePath).toString(),
        title: file.title(p.basenameWithoutExtension(sourcePath)),
      );
    } catch (_) {
      await deleteQuietly(destination);
      await LyricsLibrary.deleteSidecar(destination);
      rethrow;
    }
    try {
      store.saveTrackDetails(
        trackId,
        TrackDetails(uploader: file.artist, sourceName: "Local file"),
      );
      await thumbnails?.store(trackId, file.artwork);
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

  static Future<_FileMetadata> _readFile(String path) =>
      Isolate.run(() => _FileMetadata.read(path));

  /// Reads what tracks' files hold and the library has not read yet: every
  /// track's cover, and a local track's title and artist where the library
  /// still has only its file name. Works through the library newest first, a
  /// few files at a time in a background isolate, and calls [onChanged] as it
  /// goes. [cancelled] ends it early; the next launch carries on.
  Future<void> readMissingMetadata({
    void Function()? onChanged,
    bool Function()? cancelled,
  }) async {
    final cache = thumbnails;
    if (cache == null) return;
    final missing = [
      for (final track in manager.listTracks())
        if (!cache.known(track.id)) track,
    ];
    const batch = 16;
    for (var start = 0; start < missing.length; start += batch) {
      if (cancelled?.call() ?? false) return;
      final tracks = missing.skip(start).take(batch).toList();
      final paths = [for (final track in tracks) _pathOf(track)];
      final files = await Isolate.run(
        () => [
          for (final path in paths)
            if (path == null || !File(path).existsSync())
              null
            else
              _FileMetadata.read(path),
        ],
      );
      if (cancelled?.call() ?? false) return;
      for (final (index, file) in files.indexed) {
        final track = tracks[index];
        // A missing file is read once it is back.
        if (file == null || !manager.hasTrack(track.id)) continue;
        await cache.store(track.id, file.artwork);
        if (!isDownload(track)) _adoptTags(track, file);
      }
      onChanged?.call();
    }
  }

  /// Gives a local track the tags of its file, where the library still has
  /// only the file's name for them.
  void _adoptTags(Track track, _FileMetadata file) {
    final original = p.basenameWithoutExtension(
      _originalFile(track) ?? track.filename,
    );
    final named =
        track.title == original ||
        track.title == p.basenameWithoutExtension(track.filename);
    if (named && file.tags.title.isNotEmpty) {
      manager.updateTrack(track.id, title: file.tags.title);
    }
    final current = details(track.id);
    if (current.uploader.isEmpty && file.artist.isNotEmpty) {
      store.saveTrackDetails(track.id, current..uploader = file.artist);
    }
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

  /// Whether a track's title or artist holds [query].
  bool matches(String trackId, String query) {
    final needle = query.trim().toLowerCase();
    return needle.isEmpty ||
        manager.titleContains(trackId, needle) ||
        details(trackId).uploader.toLowerCase().contains(needle);
  }

  /// The tracks matching [query] in [sort] order. Tracks that compare equal
  /// stay newest first, or by title for those of one artist.
  List<String> trackIds({String query = "", String sort = "recent"}) {
    final ordered = manager.orderedTrackIds(sort == "artist" ? "title" : sort);
    final matching = query.trim().isEmpty
        ? ordered
        : [
            for (final id in ordered)
              if (matches(id, query)) id,
          ];
    if (!const {"artist", "longest", "played"}.contains(sort)) return matching;
    final all = {for (final id in matching) id: details(id)};
    final sorted = List.of(matching);
    switch (sort) {
      case "artist":
        final artists = {
          for (final MapEntry(key: id, value: item) in all.entries)
            id: item.uploader.trim().toLowerCase(),
        };
        // Tracks without an artist come last.
        mergeSort(
          sorted,
          compare: (a, b) {
            final (first, second) = (artists[a]!, artists[b]!);
            if (first.isEmpty != second.isEmpty) return first.isEmpty ? 1 : -1;
            return first.compareTo(second);
          },
        );
      case "longest":
        mergeSort(
          sorted,
          compare: (a, b) => all[b]!.duration.compareTo(all[a]!.duration),
        );
      case "played":
        mergeSort(
          sorted,
          compare: (a, b) {
            final count = all[b]!.playCount.compareTo(all[a]!.playCount);
            return count != 0
                ? count
                : all[b]!.lastPlayed.compareTo(all[a]!.lastPlayed);
          },
        );
    }
    return sorted;
  }

  List<Playlist> playlists() => manager.listPlaylists();

  /// Every favorite library track in the order the user dragged them into.
  /// Favorites that order does not list yet follow it, newest first.
  List<Track> favoriteTrackList() {
    final tracks = manager.tracksByIds(store.favoriteTrackIds());
    final saved = store.favoritesOrder();
    if (saved.isEmpty) return tracks;
    final rank = {for (final (index, id) in saved.indexed) id: index};
    final ordered = [
      for (final track in tracks)
        if (rank.containsKey(track.id)) track,
    ]..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
    return [
      ...ordered,
      for (final track in tracks)
        if (!rank.containsKey(track.id)) track,
    ];
  }

  /// Saves Favorites in [orderedTrackIds] order.
  void reorderFavorites(List<String> orderedTrackIds) =>
      store.saveFavoritesOrder(orderedTrackIds);

  /// The app-managed playlist of every favorite track. It follows the
  /// favorites, so it is never stored as a playlist, renamed, or deleted.
  Playlist favoritesPlaylist() => Playlist(
    id: favoritesPlaylistId,
    name: "Favorites",
    trackIds: [for (final track in favoriteTrackList()) track.id],
  );

  /// An ordered M3U8 index of the library: each track's source link.
  List<int> exportLibraryM3u8() =>
      _m3u8("Melody Library", manager.listTracks());

  /// An M3U8 index in the playlist's saved track order.
  List<int> exportPlaylistM3u8(String playlistId) =>
      playlistId == favoritesPlaylistId
      ? _m3u8(favoritesPlaylist().name, favoriteTrackList())
      : _m3u8(
          manager.getPlaylist(playlistId).name,
          manager.playlistTracks(playlistId),
        );

  /// The links that share [tracks], in order. A track imported from a file has
  /// none.
  static List<String> linksOf(Iterable<Track> tracks) => [
    for (final track in tracks)
      if (isHttpUrl(track.source)) youtubeMusicTrackUrl(track.source.trim()),
  ];

  /// A track with no link (one imported from a local file) is listed by its
  /// file instead, or left out when that is outside the music folders.
  List<int> _m3u8(String name, Iterable<Track> tracks) {
    String line(String text) => text.split(RegExp(r"\s+")).join(" ");
    final lines = ["#EXTM3U", "#PLAYLIST:${line(name)}"];
    for (final track in tracks) {
      final String location;
      if (isHttpUrl(track.source)) {
        // Sources saved by earlier releases may still carry a pasted link's
        // playlist and tracking parameters.
        location = youtubeMusicTrackUrl(track.source.trim());
      } else if (_pathOf(track) case final path?) {
        location = Uri.file(p.normalize(p.absolute(path))).toString();
      } else {
        continue;
      }
      lines
        ..add("#EXTINF:-1,${line(track.displayTitle)}")
        ..add(location);
    }
    return utf8.encode("${lines.join("\n")}\n");
  }

  /// Matches each entry of an M3U or M3U8 file to a library track by its
  /// path, its source (a URL, or the file a local track was imported from),
  /// its contents, or a file name only one track has. An unmatched link to a
  /// YouTube song is left for the caller to download, and an unmatched audio
  /// file that exists to import ([importListedFiles]).
  /// [baseDirectory] resolves relative entries.
  Future<PlaylistFileMatch> matchPlaylistM3u(
    List<int> bytes, {
    required String fallbackName,
    String? baseDirectory,
  }) async {
    final (title, entries) = parseM3u(bytes);
    if (entries.isEmpty) {
      throw const FormatException("The playlist file lists no tracks");
    }
    final byPath = <String, String>{};
    final byName = <String, List<String>>{};
    for (final track in manager.listTracks()) {
      final path = _pathOf(track);
      if (path == null) continue;
      byPath[pathKey(p.absolute(path))] = track.id;
      byName
          .putIfAbsent(p.basename(path).toLowerCase(), () => [])
          .add(track.id);
    }
    final matched = <PlaylistFileEntry>[];
    for (final (:location, :title) in entries) {
      final path = _entryPath(location, baseDirectory);
      String? id;
      var exists = false;
      if (path != null) {
        id =
            byPath[pathKey(p.absolute(path))] ??
            manager.findTrackBySource(Uri.file(path).toString())?.id;
        exists = await File(path).exists();
        if (id == null && exists) {
          try {
            id = (await manager.findTrackByContent(path))?.id;
          } on FileSystemException {
            // An unreadable file can still match by name.
          }
        }
      } else if (Uri.tryParse(location)?.hasScheme ?? false) {
        id = manager.findTrackBySource(location)?.id;
        if (id == null && MediaIdentity.fromUrl(location) != null) {
          matched.add(PlaylistFileEntry.download(location, title ?? location));
          continue;
        }
      }
      if (id == null) {
        // Another system's separators are not this one's.
        final name = (path ?? location).split(RegExp(r"[\\/]")).last;
        final candidates = byName[name.toLowerCase()];
        if (candidates != null && candidates.length == 1) id = candidates.first;
      }
      matched.add(
        id != null
            ? PlaylistFileEntry.track(id)
            : exists && audioSuffixes.contains(p.extension(path!).toLowerCase())
            ? PlaylistFileEntry.file(path)
            : const PlaylistFileEntry.skipped(),
      );
    }
    if (matched.every(
      (entry) =>
          entry.trackId == null && entry.url == null && entry.file == null,
    )) {
      throw FormatException(
        "None of the ${entries.length} tracks in the playlist file are in "
        "the library",
      );
    }
    final name = title ?? fallbackName.trim();
    return PlaylistFileMatch(
      name.isEmpty ? "Imported playlist" : name,
      matched,
    );
  }

  /// Imports the audio files [match] lists that the library lacks, and returns
  /// it with their tracks in their place. A file that cannot be imported is
  /// skipped.
  Future<PlaylistFileMatch> importListedFiles(PlaylistFileMatch match) async {
    final entries = <PlaylistFileEntry>[];
    for (final entry in match.entries) {
      if (entry.file case final path?) {
        try {
          entries.add(PlaylistFileEntry.track(await importLocalFile(path)));
        } on Object catch (error) {
          debugPrint("Could not import $path for a playlist: $error");
          entries.add(const PlaylistFileEntry.skipped());
        }
      } else {
        entries.add(entry);
      }
    }
    return PlaylistFileMatch(match.name, entries);
  }

  /// Creates a playlist from the library tracks an M3U or M3U8 file lists
  /// (see [matchPlaylistM3u]), importing the files it names that the library
  /// lacks; other entries are skipped. A file that matches none creates no
  /// playlist.
  Future<PlaylistFileImport> importPlaylistM3u(
    List<int> bytes, {
    required String fallbackName,
    String? baseDirectory,
  }) async => createPlaylistFrom(
    await importListedFiles(
      await matchPlaylistM3u(
        bytes,
        fallbackName: fallbackName,
        baseDirectory: baseDirectory,
      ),
    ),
  );

  /// Creates a playlist of the tracks in [match]; other entries are skipped.
  PlaylistFileImport createPlaylistFrom(PlaylistFileMatch match) {
    final trackIds = match.trackIds;
    if (trackIds.isEmpty) {
      throw FormatException(
        "None of the ${match.entries.length} tracks in the playlist file are "
        "in the library",
      );
    }
    final playlistId = manager.createPlaylist(match.name);
    final int added;
    try {
      added = manager.addTracksToPlaylist(playlistId, trackIds);
    } catch (_) {
      manager.deletePlaylist(playlistId);
      rethrow;
    }
    return PlaylistFileImport(
      playlistId,
      manager.getPlaylist(playlistId).name,
      added,
      match.entries.length - trackIds.length,
    );
  }

  /// A local entry's path, or null for a URL or a relative entry without
  /// [base]. A drive letter is a path, not a URL scheme.
  static String? _entryPath(String entry, String? base) {
    final uri = Uri.tryParse(entry);
    if (uri != null && uri.scheme == "file") {
      try {
        return uri.toFilePath();
      } on UnsupportedError {
        return null;
      }
    }
    if (uri != null && uri.scheme.length > 1) return null;
    if (p.isAbsolute(entry)) return p.normalize(entry);
    return base == null ? null : p.normalize(p.join(base, entry));
  }
}

/// What an audio file says about itself.
class _FileMetadata {
  const _FileMetadata(this.tags, this.artwork);

  /// Reads [path]; run it off the UI isolate.
  factory _FileMetadata.read(String path) =>
      _FileMetadata(readEmbeddedTagsSync(path), readEmbeddedArtworkSync(path));

  final AudioTags tags;
  final Uint8List artwork;

  String get artist => tags.artist;

  /// The tagged title, or [fallback] for a file without one.
  String title(String fallback) =>
      tags.title.isNotEmpty ? tags.title : fallback;
}

/// An M3U entry matched to a library track, a link to download, a file to
/// import, or none of them.
class PlaylistFileEntry {
  const PlaylistFileEntry.track(String this.trackId)
    : url = null,
      file = null,
      title = "";
  const PlaylistFileEntry.download(String this.url, this.title)
    : trackId = null,
      file = null;
  const PlaylistFileEntry.file(String this.file)
    : trackId = null,
      url = null,
      title = "";
  const PlaylistFileEntry.skipped()
    : trackId = null,
      url = null,
      file = null,
      title = "";

  final String? trackId;
  final String? url;
  final String? file;
  final String title;
}

/// A playlist file's name and its entries in order.
class PlaylistFileMatch {
  const PlaylistFileMatch(this.name, this.entries);

  final String name;
  final List<PlaylistFileEntry> entries;

  List<String> get trackIds => [for (final entry in entries) ?entry.trackId];

  int get skipped => entries
      .where(
        (entry) =>
            entry.trackId == null && entry.url == null && entry.file == null,
      )
      .length;
}

/// The playlist an M3U import created, how many tracks it holds (a track
/// listed twice is added once), and how many entries matched no track.
class PlaylistFileImport {
  const PlaylistFileImport(
    this.playlistId,
    this.name,
    this.added,
    this.skipped,
  );

  final String playlistId;
  final String name;
  final int added;
  final int skipped;
}

/// The `#PLAYLIST:` title and the track entries of an M3U or M3U8 file, in
/// order, each with the title its `#EXTINF:` line gives. Text that is not
/// UTF-8 is read as Latin-1, as plain `.m3u` often is.
(String?, List<({String location, String? title})>) parseM3u(List<int> bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  if (text.startsWith("\uFEFF")) text = text.substring(1);
  String? title;
  String? entryTitle;
  final entries = <({String location, String? title})>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith("#")) {
      if (line.startsWith("#PLAYLIST:")) {
        final value = line.substring("#PLAYLIST:".length).trim();
        if (value.isNotEmpty) title = value;
      } else if (line.startsWith("#EXTINF:")) {
        final comma = line.indexOf(",");
        final value = comma < 0 ? "" : line.substring(comma + 1).trim();
        entryTitle = value.isEmpty ? null : value;
      }
      continue;
    }
    entries.add((location: line, title: entryTitle));
    entryTitle = null;
  }
  return (title, entries);
}
