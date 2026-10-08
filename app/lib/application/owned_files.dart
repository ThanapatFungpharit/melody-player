import "package:flutter/foundation.dart";

import "../core/library/manager.dart";
import "../core/storage.dart";
import "lyrics.dart";
import "store.dart";

/// Deletes audio files Melody owns (it downloaded them) once no library
/// entry uses them, with the `.lrc` beside each.
///
/// Every deletion is recorded in the state database before the entry that
/// uses the file goes ([mark]), and forgotten only once the file is gone
/// ([release]). A file the operating system refuses to delete now (open in
/// another program), or one a crash left between the two steps, is deleted
/// at a later launch ([releasePending]). A path some entry still uses is
/// never deleted: an entry that survived a crash keeps its file.
///
/// Callers hold [MusicManager.mutation], so no registration can claim a
/// file between the check and the deletion.
class OwnedFiles {
  OwnedFiles(this._store, this._manager);

  final ApplicationStore _store;
  final MusicManager _manager;

  static const _key = "pending_file_deletions";

  List<String> get _pending => [
    if (_store.get(_key) case final List items)
      for (final item in items)
        if (item is String) item,
  ];

  void _save(Iterable<String> paths) {
    final unique = paths.toSet().toList();
    if (unique.isEmpty && _store.get(_key) is! List) return;
    _store.set(_key, unique);
  }

  /// Records [paths] for deletion. Call it before removing or repointing
  /// the entries that use them. Throws when the record cannot be saved, so
  /// the caller changes nothing.
  void mark(Iterable<String> paths) {
    final added = paths.toList();
    if (added.isEmpty) return;
    _save([..._pending, ...added]);
  }

  /// Deletes those of [paths] no entry uses, and forgets each one that is
  /// gone or still in use. Never throws; a file that stays is retried at
  /// the next launch.
  Future<void> release(Iterable<String> paths) async {
    final done = <String>{};
    for (final path in paths.toSet()) {
      if (_manager.isPathReferenced(path)) {
        done.add(path);
        continue;
      }
      try {
        await deleteFile(path);
        await LyricsLibrary.deleteSidecar(path);
        done.add(path);
      } on Object catch (error) {
        debugPrint("$path will be deleted at the next launch: $error");
      }
    }
    if (done.isEmpty) return;
    try {
      _save(_pending.where((path) => !done.contains(path)));
    } on Object catch (error) {
      // Only the bookkeeping is stale; the next launch finds the files gone.
      debugPrint("Could not update pending file deletions: $error");
    }
  }

  /// Finishes deletions an earlier launch could not. Call it at launch,
  /// before downloads open.
  Future<void> releasePending() =>
      _manager.mutation.run(() => release(_pending));
}
