import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:melody_audio/melody_audio.dart" show AndroidPlatform;
import "package:path/path.dart" as p;

import "../core/library/manager.dart";
import "library_service.dart" show audioSuffixes;

/// Publishes audio staged in private storage to Android's public
/// `Music/Melody` folder through MediaStore, then makes the public copy the
/// library's file.
///
/// A private copy that is still playing is removed once playback moves on.
/// Exports interrupted by a restart resume at the next launch.
class AndroidMusicExport {
  AndroidMusicExport(
    this._manager, {
    required String privateRoot,
    required this.publicRoot,
    required this._isPlaying,
    required this._onFailure,
  }) : _privateRoot = p.normalize(privateRoot);

  final MusicManager _manager;
  final String _privateRoot;

  /// The public folder MediaStore must place tracks in.
  final String? publicRoot;
  final bool Function(String trackId) _isPlaying;
  final void Function(String message) _onFailure;
  final Set<String> _pending = {};

  /// Private copies kept until their track stops playing.
  final Map<String, String> _deferredSources = {};
  bool _draining = false;
  bool _closed = false;

  /// Removes private copies left behind by a process that ended while their
  /// published track was still playing, then queues tracks whose file is
  /// still in private storage.
  void resumeInterrupted() {
    unawaited(
      removeOrphanedCopies().catchError((Object error) {
        debugPrint("Could not look for leftover private copies: $error");
        return 0;
      }),
    );
    for (final track in _manager.listTracks()) {
      try {
        // [_publish] skips a file that is gone, so the UI isolate makes no
        // per-track filesystem call here.
        if (p.isWithin(_privateRoot, _manager.trackPath(track.id))) {
          _pending.add(track.id);
        }
      } on Object {
        continue;
      }
    }
    if (_pending.isNotEmpty) unawaited(_drain());
  }

  /// Deletes audio in the private music folder that no track references
  /// and whose bytes a library track already has: a published track's
  /// private copy whose deferred removal never ran. Only Melody writes to
  /// private storage, and a file without such a twin is never touched.
  /// Meant for startup, before a download can be between its move and its
  /// registration. Returns how many files were removed.
  Future<int> removeOrphanedCopies() => _manager.mutation.run(() async {
    final folder = p.normalize(p.absolute(_manager.musicFolder));
    if (!p.isWithin(_privateRoot, folder) ||
        !await Directory(folder).exists()) {
      return 0;
    }
    final deferred = {
      for (final path in _deferredSources.values) p.normalize(p.absolute(path)),
    };
    var removed = 0;
    await for (final entity in Directory(folder).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is! File ||
          name.startsWith(".") ||
          !audioSuffixes.contains(p.extension(name).toLowerCase()) ||
          deferred.contains(p.normalize(entity.path)) ||
          _manager.isPathReferenced(entity.path)) {
        continue;
      }
      try {
        if (await _manager.findTrackByContent(entity.path) == null) continue;
        await entity.delete();
        removed++;
      } on FileSystemException catch (error) {
        debugPrint("Could not remove a leftover private copy: $error");
      }
    }
    return removed;
  });

  void export(Iterable<String> trackIds) {
    _pending.addAll(trackIds);
    if (_pending.isNotEmpty) unawaited(_drain());
  }

  /// Removes private copies whose track is no longer playing.
  Future<void> releasePlayedSources() async {
    for (final entry in _deferredSources.entries.toList()) {
      if (_isPlaying(entry.key)) continue;
      await _removeUnreferencedFile(entry.value);
      _deferredSources.remove(entry.key);
    }
  }

  bool get hasDeferredSources => _deferredSources.isNotEmpty;

  void close() {
    _closed = true;
    for (final path in _deferredSources.values) {
      unawaited(_removeUnreferencedFile(path));
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    var failed = false;
    try {
      while (_pending.isNotEmpty && !_closed) {
        final trackId = _pending.first;
        _pending.remove(trackId);
        try {
          await _publish(trackId);
        } catch (error) {
          failed = true;
          debugPrint(
            "Could not publish track to the Android Music folder: $error",
          );
        }
      }
    } finally {
      _draining = false;
    }
    if (failed) {
      _onFailure(
        "A downloaded track could not be moved to Music/Melody. "
        "Melody will retry next time it starts.",
      );
    }
  }

  /// Runs under the library's mutation lock, like every file swap, so a
  /// concurrent delete or import never sees a half-moved track.
  Future<void> _publish(String trackId) => _manager.mutation.run(() async {
    // Deleted while it waited, or published already.
    if (!_manager.hasTrack(trackId)) return;
    final source = _manager.trackPath(trackId);
    if (!p.isWithin(_privateRoot, source) || !await File(source).exists()) {
      return;
    }
    final published = await AndroidPlatform.publishAudio(source);
    final root = publicRoot;
    if (root == null || !p.isWithin(root, published)) {
      throw StateError("Android returned a file outside Music/Melody");
    }
    await _manager.replaceTrackFile(trackId, published);
    if (p.equals(source, published)) return;
    if (_isPlaying(trackId)) {
      _deferredSources[trackId] = source;
    } else {
      await _removeUnreferencedFile(source);
    }
  });

  Future<void> _removeUnreferencedFile(String path) async {
    if (_manager.isPathReferenced(path)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint("Could not remove exported staging audio: $error");
    }
  }
}
