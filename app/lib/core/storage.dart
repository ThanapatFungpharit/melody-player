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
class SqliteStore {
  SqliteStore._(this.path, this._db);

  final String path;
  Database? _db;

  static SqliteStore open(String path, {bool fullSync = true}) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final Database db;
    try {
      db = sqlite3.open(path);
    } on SqliteException catch (error) {
      throw FormatException("Could not open $path: $error");
    }
    try {
      // WAL is persistent in the file; a filesystem that cannot map the
      // shared-memory index keeps the rollback journal, which is still atomic.
      db.execute("PRAGMA journal_mode=WAL");
      db.execute("PRAGMA synchronous=${fullSync ? "FULL" : "NORMAL"}");
      db.execute("PRAGMA foreign_keys=ON");
      db.execute("PRAGMA busy_timeout=5000");
      final check = db.select("PRAGMA quick_check").first.values.first;
      if (check != "ok") throw FormatException("$check");
    } catch (error) {
      db.close();
      throw FormatException("$path is not a valid database: $error");
    }
    return SqliteStore._(path, db);
  }

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
    try {
      final result = write(db);
      db.execute("COMMIT");
      return result;
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

  void close() {
    _db?.close();
    _db = null;
  }
}

final _random = Random.secure();

String _temporaryName(String directory, String prefix, String suffix) {
  final token = List.generate(
    8,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, "0"),
  ).join();
  return p.join(directory, "$prefix$token$suffix");
}

/// Replaces [path] only after all bytes have reached durable storage.
Future<void> atomicWrite(String path, List<int> contents) async {
  final directory = p.dirname(path);
  await Directory(directory).create(recursive: true);
  final temporary = File(
    _temporaryName(directory, ".${p.basename(path)}.", ".tmp"),
  );
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
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } on FileSystemException catch (error) {
        debugPrint("Could not remove temporary file ${temporary.path}: $error");
      }
    }
  }
}

/// Copies across filesystems without exposing a partial destination file.
Future<void> atomicCopy(String source, String destination) async {
  final temporary = _temporaryName(
    p.dirname(destination),
    ".melody-import-",
    ".tmp",
  );
  try {
    await Isolate.run(() => _copyAndSync(source, temporary));
    await File(temporary).rename(destination);
  } finally {
    final leftover = File(temporary);
    if (await leftover.exists()) {
      try {
        await leftover.delete();
      } on FileSystemException catch (error) {
        debugPrint("Could not remove temporary file $temporary: $error");
      }
    }
  }
}

void _copyAndSync(String source, String destination) {
  final input = File(source).openSync();
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
    input.closeSync();
    output.closeSync();
  }
}

/// SHA-256 of a file, computed off the UI isolate.
Future<String> sha256File(String path) => Isolate.run(() => sha256FileSync(path));

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
