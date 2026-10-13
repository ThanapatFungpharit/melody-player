/// Filesystem and SQLite primitives shared by durable state owners.
library;

import "dart:async";
import "dart:io";
import "dart:isolate";
import "dart:math";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:sqlite3/sqlite3.dart";

/// A durable commit failed; the transaction was rolled back.
class DatabaseFailure implements Exception {
  DatabaseFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One process-lifetime SQLite connection in write-ahead-log mode.
///
/// WAL appends each commit instead of rewriting a whole state file.
/// `synchronous=FULL` makes every commit survive power loss; `NORMAL`
/// survives application crashes and may lose only the latest commits on power
/// loss, never consistency. Owners keep their own in-memory model and restore
/// it when [transaction] throws.
///
/// A FULL commit waits for the disk to flush the log, which on phone storage
/// can hold the UI isolate for tens of milliseconds. With `syncInBackground`,
/// commits run at `NORMAL` and a background isolate flushes the log right
/// after each one ([flushed] completes once it has): a commit becomes durable
/// a moment after it returns instead of before. If that isolate cannot start
/// or fails, commits go back to waiting for the disk.
class SqliteStore {
  SqliteStore._(this.path, this._db);

  final String path;
  Database? _db;
  _WalSyncer? _syncer;

  static SqliteStore open(
    String path, {
    bool fullSync = true,
    bool syncInBackground = false,
  }) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final Database db;
    try {
      db = sqlite3.open(path);
    } on SqliteException catch (error) {
      throw FormatException("Could not open $path: $error");
    }
    final bool wal;
    try {
      // WAL is persistent in the file; a filesystem that cannot map the
      // shared-memory index keeps the rollback journal, which is still atomic.
      final mode = db.select("PRAGMA journal_mode=WAL").first.values.first;
      wal = "$mode".toLowerCase() == "wal";
      db.execute("PRAGMA synchronous=${fullSync ? "FULL" : "NORMAL"}");
      db.execute("PRAGMA foreign_keys=ON");
      db.execute("PRAGMA busy_timeout=5000");
      final check = db.select("PRAGMA quick_check").first.values.first;
      if (check != "ok") throw FormatException("$check");
      _reclaimFreePages(db);
    } catch (error) {
      db.close();
      throw FormatException("$path is not a valid database: $error");
    }
    final store = SqliteStore._(path, db);
    // Only a WAL commit's durability is a separate log flush.
    if (fullSync && syncInBackground && wal) store._startBackgroundSync();
    return store;
  }

  /// Deleted rows leave free pages that SQLite reuses but never returns to
  /// the filesystem. Once they are a large share of a sizable file (after
  /// clearing the library, say), the file is rebuilt without them.
  static void _reclaimFreePages(Database db) {
    int pragma(String name) =>
        (db.select("PRAGMA $name").first.values.first as num).toInt();
    final free = pragma("freelist_count");
    final total = pragma("page_count");
    if (free * pragma("page_size") < 4 * 1024 * 1024 || free * 4 < total) {
      return;
    }
    try {
      db.execute("VACUUM");
    } on SqliteException catch (error) {
      // Only space is lost; the database is intact.
      debugPrint("Could not compact the database: $error");
    }
  }

  void _startBackgroundSync() {
    final syncer = _WalSyncer("$path-wal", onFailure: _syncInForeground);
    _syncer = syncer;
    unawaited(
      syncer.start().then((started) {
        final db = _db;
        if (db == null || !identical(_syncer, syncer)) return;
        if (!started) {
          _syncer = null;
          return;
        }
        // Commits were FULL until now. Asynchronous callbacks never run
        // inside [transaction], so no transaction is open here.
        try {
          db.execute("PRAGMA synchronous=NORMAL");
        } on SqliteException catch (error) {
          debugPrint("Commits to $path keep waiting for the disk: $error");
          _syncer = null;
          unawaited(syncer.stop());
        }
      }),
    );
  }

  void _syncInForeground(Object error) {
    debugPrint("Background flushing of $path stopped: $error");
    _syncer = null;
    final db = _db;
    if (db == null) return;
    try {
      db.execute("PRAGMA synchronous=FULL");
      // Commits the background isolate never confirmed.
      flushFileSync("$path-wal");
    } on Object catch (error) {
      debugPrint("Could not flush $path: $error");
    }
  }

  /// Completes once every commit made so far is on durable storage.
  Future<void> flushed() => _syncer?.flushed() ?? Future<void>.value();

  Database _requireOpen() {
    final db = _db;
    if (db == null) throw DatabaseFailure("Database is closed: $path");
    return db;
  }

  /// Runs [write] atomically; any exception rolls every statement back.
  T transaction<T>(T Function(Database db) write) {
    final db = _requireOpen();
    try {
      db.execute("BEGIN IMMEDIATE");
    } on SqliteException catch (error) {
      throw DatabaseFailure("Could not write $path: $error");
    }
    final T result;
    try {
      result = write(db);
      db.execute("COMMIT");
    } catch (error) {
      try {
        if (!db.autocommit) db.execute("ROLLBACK");
      } on SqliteException catch (rollback) {
        debugPrint("Could not roll back $path: $rollback");
      }
      if (error is SqliteException) {
        throw DatabaseFailure("Could not write $path: $error");
      }
      rethrow;
    }
    _syncer?.request();
    return result;
  }

  ResultSet query(String sql, [List<Object?> parameters = const []]) {
    try {
      return _requireOpen().select(sql, parameters);
    } on SqliteException catch (error) {
      throw DatabaseFailure("Could not read $path: $error");
    }
  }

  bool hasTable(String name) => query(
    "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?",
    [name],
  ).isNotEmpty;

  /// New transactions fail at once. Without background flushing the
  /// connection closes before this returns; with it, once the pending
  /// commits are flushed and the isolate has exited.
  Future<void> close() async {
    final db = _db;
    _db = null;
    final syncer = _syncer;
    _syncer = null;
    if (syncer != null) await syncer.stop();
    // The last connection to close checkpoints the log into the database.
    db?.close();
  }
}

/// Flushes a file's written bytes to durable storage, whichever handle
/// wrote them.
void flushFileSync(String path) {
  final file = File(path);
  if (!file.existsSync()) return;
  // Append mode never truncates; Windows needs write access to flush.
  final handle = file.openSync(mode: FileMode.append);
  try {
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
}

/// Flushes a write-ahead log from a background isolate after commits.
///
/// Requests are numbered and one flush is in flight at a time. A flush
/// covers every commit made before it began, so a burst of commits costs at
/// most two flushes.
class _WalSyncer {
  _WalSyncer(this.walPath, {required this.onFailure});

  final String walPath;
  final void Function(Object error) onFailure;
  final ReceivePort _replies = ReceivePort();
  SendPort? _commands;
  Isolate? _isolate;
  int _requested = 0;
  int _sent = 0;
  int _flushed = 0;
  bool _failed = false;
  bool _stopping = false;
  final List<Completer<void>> _waiters = [];
  final Completer<void> _exited = Completer();

  bool get _idle => _failed || _flushed >= _requested;

  /// Whether the isolate is ready to flush.
  Future<bool> start() async {
    final ready = Completer<bool>();
    _replies.listen((message) {
      switch (message) {
        case SendPort commands:
          _commands = commands;
          if (_stopping) {
            // Closed while the isolate was starting: let it exit.
            commands.send(null);
            if (!ready.isCompleted) ready.complete(false);
            return;
          }
          if (!ready.isCompleted) ready.complete(true);
          // Commits made while the isolate started.
          _send();
        case int flushed:
          _flushed = flushed;
          _send();
          _wake();
        case String error:
          _fail(error);
        case [final error, _]:
          // An uncaught error in the isolate.
          _fail("$error");
        case null:
          if (!_exited.isCompleted) _exited.complete();
          _replies.close();
          _fail("The background isolate exited");
      }
      if (_failed && !ready.isCompleted) ready.complete(false);
    });
    try {
      _isolate = await Isolate.spawn(
        _walSyncMain,
        (walPath, _replies.sendPort),
        onExit: _replies.sendPort,
        onError: _replies.sendPort,
        debugName: "database flush",
      );
    } on Object catch (error) {
      debugPrint("Could not start background database flushing: $error");
      _failed = true;
      _replies.close();
      return false;
    }
    return ready.future;
  }

  void request() {
    if (_failed || _stopping) return;
    _requested++;
    _send();
  }

  void _send() {
    final commands = _commands;
    // One flush at a time; its reply sends the next.
    if (commands == null || _failed || _sent > _flushed) return;
    if (_requested > _flushed) {
      _sent = _requested;
      commands.send(_requested);
    }
  }

  void _wake() {
    if (!_idle) return;
    for (final waiter in _waiters) {
      waiter.complete();
    }
    _waiters.clear();
  }

  Future<void> flushed() {
    if (_idle) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _fail(String error) {
    if (_failed) return;
    _failed = true;
    _commands?.send(null);
    _wake();
    if (!_stopping) onFailure(error);
  }

  /// Flushes what is pending, then ends the isolate.
  Future<void> stop() async {
    if (_stopping) return _exited.future;
    final isolate = _isolate;
    if (isolate == null) {
      _stopping = true;
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    await flushed();
    _stopping = true;
    _commands?.send(null);
    try {
      await _exited.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
      _replies.close();
    }
  }
}

void _walSyncMain((String, SendPort) setup) {
  final (walPath, replies) = setup;
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  commands.listen((message) {
    if (message is! int) {
      // Closing the only port lets the isolate exit.
      commands.close();
      return;
    }
    try {
      flushFileSync(walPath);
      replies.send(message);
    } on Object catch (error) {
      replies.send("Could not flush $walPath: $error");
      commands.close();
    }
  });
}

final _random = Random.secure();

/// The prefix of every temporary file Melody writes beside a destination
/// before renaming it into place ([temporarySibling]).
const temporaryPrefix = ".melody-tmp-";

/// A fresh, unused-looking path in [destination]'s folder for writing its
/// contents before an atomic rename: `.melody-tmp-<16 hex><extension>`.
///
/// The name keeps the destination's extension, because Android refuses
/// files whose type does not belong in a shared folder (such as a `.tmp` in
/// `Music`); an unusual extension becomes `.tmp`.
String temporarySibling(String destination) {
  final token = List.generate(
    8,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, "0"),
  ).join();
  final extension = p.extension(destination).toLowerCase();
  final suffix = RegExp(r"^\.[0-9a-z]{1,8}$").hasMatch(extension)
      ? extension
      : ".tmp";
  return p.join(p.dirname(destination), "$temporaryPrefix$token$suffix");
}

/// How long a temporary file must sit untouched before it counts as
/// abandoned. A writer still at work keeps updating its file, so only a
/// process that died mid-write leaves one this old.
const staleTemporaryAge = Duration(hours: 1);

final _temporaryName = RegExp(
  // Current: [temporarySibling].
  r"^\.melody-tmp-[0-9a-f]{16}\.[0-9a-z]{1,8}$"
  // The Python releases (mkstemp): `.<name>.<random>.tmp` and
  // `.melody-import-<random>.tmp`.
  r"|^\.(?:melody-import-|.+\.)[0-9a-z_]{8}\.tmp$",
);

/// Whether [name] is a temporary file Melody writes before a rename.
bool isTemporaryFile(String name) => _temporaryName.hasMatch(name);

/// Removes temporary files ([isTemporaryFile]) that a process ending
/// mid-write left in [directory] (not its subfolders).
/// Nothing else is touched. Returns how many files were removed.
Future<int> removeStaleTemporaries(String directory, {DateTime? now}) async {
  final cutoff = (now ?? DateTime.now()).subtract(staleTemporaryAge);
  var removed = 0;
  try {
    if (!await Directory(directory).exists()) return 0;
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (entity is! File || !isTemporaryFile(p.basename(entity.path))) {
        continue;
      }
      if (await _deleteIfOlder(entity, cutoff)) removed++;
    }
  } on FileSystemException catch (error) {
    debugPrint("Could not look for leftover temporary files: $error");
  }
  return removed;
}

/// Bounds a disposable cache folder that another program fills: removes
/// files not modified for [maxAge] (temporary `.tmp` files after
/// [staleTemporaryAge]), then the least recently modified until the folder
/// holds at most [maxBytes]. Every file under [directory] must be safe to
/// lose. Returns how many files were removed.
Future<int> pruneCacheDirectory(
  String directory, {
  required Duration maxAge,
  required int maxBytes,
  DateTime? now,
}) async {
  final current = now ?? DateTime.now();
  final expired = current.subtract(maxAge);
  final abandoned = current.subtract(staleTemporaryAge);
  final kept = <(File, FileStat)>[];
  var removed = 0;
  try {
    if (!await Directory(directory).exists()) return 0;
    await for (final entity in Directory(
      directory,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final status = await entity.stat();
      final cutoff = entity.path.endsWith(".tmp") ? abandoned : expired;
      if (status.modified.isBefore(cutoff)) {
        if (await _delete(entity)) removed++;
      } else {
        kept.add((entity, status));
      }
    }
  } on FileSystemException catch (error) {
    debugPrint("Could not prune the cache in $directory: $error");
    return removed;
  }
  var total = kept.fold<int>(0, (sum, item) => sum + item.$2.size);
  kept.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
  for (final (file, status) in kept) {
    if (total <= maxBytes) break;
    if (await _delete(file)) {
      removed++;
      total -= status.size;
    }
  }
  return removed;
}

Future<bool> _deleteIfOlder(File file, DateTime cutoff) async {
  try {
    if (!(await file.lastModified()).isBefore(cutoff)) return false;
  } on FileSystemException {
    return false;
  }
  return _delete(file);
}

/// Deletes the file at [path] if there is one. Throws when it stays, such
/// as one another program holds open on Windows.
Future<void> deleteFile(String path) async {
  try {
    await File(path).delete();
  } on PathNotFoundException {
    // Already gone.
  }
}

/// Deletes the file at [path] if there is one. Best effort: a failure only
/// logs, and a file another process holds open stays for next time.
/// Returns whether a file was removed.
Future<bool> deleteQuietly(String path) => _delete(File(path));

Future<bool> _delete(File file) async {
  try {
    await file.delete();
    return true;
  } on FileSystemException catch (error) {
    if (error is! PathNotFoundException) {
      debugPrint("Could not remove ${file.path}: $error");
    }
    return false;
  }
}

/// Replaces [path] only after all bytes have reached durable storage.
Future<void> atomicWrite(String path, List<int> contents) async {
  final directory = p.dirname(path);
  await Directory(directory).create(recursive: true);
  final temporary = File(temporarySibling(path));
  try {
    final handle = await temporary.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(contents);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(path);
  } finally {
    // Gone after a successful rename.
    await _delete(temporary);
  }
}

/// Copies across filesystems without exposing a partial destination file.
Future<void> atomicCopy(String source, String destination) async {
  final temporary = temporarySibling(destination);
  try {
    await Isolate.run(() => _copyAndSync(source, temporary));
    await File(temporary).rename(destination);
  } finally {
    await deleteQuietly(temporary);
  }
}

/// Moves [source] to [destination], copying when they are on different
/// volumes. Either the destination exists and the source is gone, or the
/// source is left where it was.
Future<void> moveFile(String source, String destination) async {
  await Directory(p.dirname(destination)).create(recursive: true);
  try {
    await File(source).rename(destination);
    return;
  } on PathNotFoundException {
    rethrow;
  } on FileSystemException {
    // Usually another volume; a file held open fails again below.
  }
  await atomicCopy(source, destination);
  try {
    await File(source).delete();
  } on FileSystemException {
    await deleteQuietly(destination);
    rethrow;
  }
}

void _copyAndSync(String source, String destination) {
  final input = File(source).openSync();
  try {
    final output = File(destination).openSync(mode: FileMode.writeOnly);
    try {
      final buffer = Uint8List(1024 * 1024);
      while (true) {
        final read = input.readIntoSync(buffer);
        if (read == 0) break;
        output.writeFromSync(buffer, 0, read);
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
  } finally {
    input.closeSync();
  }
}

/// SHA-256 of a file, computed off the UI isolate.
Future<String> sha256File(String path) =>
    Isolate.run(() => sha256FileSync(path));

String sha256FileSync(String path) {
  final input = File(path).openSync();
  try {
    final output = _DigestSink();
    final sink = sha256.startChunkedConversion(output);
    final buffer = Uint8List(1024 * 1024);
    while (true) {
      final read = input.readIntoSync(buffer);
      if (read == 0) break;
      sink.add(Uint8List.sublistView(buffer, 0, read));
    }
    sink.close();
    return output.value.toString();
  } finally {
    input.closeSync();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Which of [paths] are regular files ([nonEmpty]: with at least one byte),
/// checked in one background isolate so many checks cost the UI isolate a
/// single message instead of one blocking call or event per file.
Future<Set<String>> existingFiles(
  Iterable<String> paths, {
  bool nonEmpty = false,
}) async {
  final candidates = paths.toSet().toList();
  if (candidates.isEmpty) return {};
  return Isolate.run(
    () => {
      for (final path in candidates)
        if (_isFile(path, nonEmpty: nonEmpty)) path,
    },
  );
}

bool _isFile(String path, {required bool nonEmpty}) {
  try {
    final status = File(path).statSync();
    return status.type == FileSystemEntityType.file &&
        (!nonEmpty || status.size > 0);
  } on FileSystemException {
    return false;
  }
}

/// Seconds since the Unix epoch, the timestamp unit of every stored record.
double unixSeconds() => DateTime.now().microsecondsSinceEpoch / 1e6;

/// Whether the filesystems Melody runs on usually ignore case in names
/// (NTFS, APFS), so `Song.mp3` and `song.mp3` are one file.
final bool caseInsensitiveFileNames = Platform.isWindows || Platform.isMacOS;

/// [path] in the form path comparisons use: normalized, and lowercase where
/// [caseInsensitiveFileNames]. Never use it to open a file.
String pathKey(String path) {
  final normalized = p.normalize(path);
  return caseInsensitiveFileNames ? normalized.toLowerCase() : normalized;
}

/// Whether [a] and [b] name the same location, relative names resolved
/// against the working directory. Links are not followed.
bool samePath(String a, String b) =>
    pathKey(p.absolute(a)) == pathKey(p.absolute(b));

/// A path in [directory] for a file called [name] that neither exists nor is
/// in [reserved]: `Song.mp3`, then `Song (2).mp3`, `Song (3).mp3`, ...
String availablePath(
  String directory,
  String name, {
  Set<String> reserved = const {},
}) {
  final stem = p.basenameWithoutExtension(name);
  final extension = p.extension(name);
  final reservedKeys = {for (final path in reserved) pathKey(path)};
  bool taken(String path) =>
      File(path).existsSync() || reservedKeys.contains(pathKey(path));
  var candidate = p.join(directory, name);
  for (var counter = 2; taken(candidate); counter++) {
    candidate = p.join(directory, "$stem ($counter)$extension");
  }
  return candidate;
}

/// Keeps an imported legacy file as a backup that is never imported again.
void retireLegacyFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return;
  try {
    file.renameSync("$path.migrated");
  } on FileSystemException catch (error) {
    debugPrint("Imported legacy state, but could not rename $path: $error");
  }
}

/// Serializes asynchronous critical sections, like a non-reentrant lock.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(FutureOr<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
