/// Durable handoff from download-owned files to application registration.
library;

import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../storage.dart";

/// The receipt for [taskId] in [directory], a folder that holds only
/// receipts.
String receiptPath(String directory, String taskId) =>
    p.join(directory, "$taskId.json");

/// Writes the receipt for files that are in [filesDirectory].
Future<void> writeReceipt(
  String directory,
  String taskId,
  String url,
  List<Map<String, String>> files, {
  required String filesDirectory,
}) => atomicWrite(
  receiptPath(directory, taskId),
  utf8.encode(
    jsonEncode({
      "schema": 1,
      "task_id": taskId,
      "url": url,
      "directory": p.absolute(filesDirectory),
      "files": files,
    }),
  ),
);

class Receipt {
  const Receipt(this.taskId, this.url, this.files, {this.unverified = 0});

  final String taskId;
  final String url;

  /// Listed files that are present and still match their checksums.
  final List<String> files;

  /// Listed files that are missing (the process ended before moving them)
  /// or no longer match their checksums (changed since; no longer provably
  /// the download's). Neither kind is imported or deleted.
  final int unverified;
}

/// Reads a receipt's JSON without checking its files. Throws
/// [FormatException] when it is not a receipt.
Future<Map<String, Object?>> readReceiptData(String path) async {
  final link = await FileSystemEntity.isLink(path);
  if (link || await File(path).length() > 128 * 1024) {
    throw const FormatException("Invalid download receipt");
  }
  // Decoded here so invalid UTF-8 is a FormatException like invalid JSON,
  // not an I/O failure that would keep the receipt for retry forever.
  final data = jsonDecode(utf8.decode(await File(path).readAsBytes()));
  if (data is! Map<String, Object?> ||
      data["schema"] != 1 ||
      data["task_id"] is! String) {
    throw const FormatException("Invalid download receipt");
  }
  return data;
}

/// Reads a receipt and verifies each file it lists. Throws
/// [FormatException] when the receipt itself is malformed or names a file
/// outside its folder.
Future<Receipt> readReceipt(String path) async {
  final data = await readReceiptData(path);
  final taskId = data["task_id"] as String;
  if (!p.equals(path, receiptPath(p.dirname(path), taskId))) {
    throw const FormatException("Invalid download receipt identity");
  }
  final url = data["url"];
  final entries = data["files"];
  final folder = data["directory"];
  if (url is! String || entries is! List) {
    throw const FormatException("Invalid download receipt");
  }
  if (folder is! String || !p.isAbsolute(folder)) {
    throw const FormatException("Invalid download receipt folder");
  }
  if (entries.isEmpty) throw const FormatException("Empty download receipt");
  final files = <String>[];
  var unverified = 0;
  for (final entry in entries) {
    final name = entry is Map ? entry["filename"] : null;
    final digest = entry is Map ? entry["sha256"] : null;
    if (name is! String ||
        digest is! String ||
        name.isEmpty ||
        p.basename(name) != name ||
        name.contains("/") ||
        name.contains(r"\")) {
      throw const FormatException("Download receipt escaped its owned folder");
    }
    final candidate = p.join(folder, name);
    if (await FileSystemEntity.isLink(candidate) ||
        !await File(candidate).exists() ||
        await sha256File(candidate) != digest) {
      unverified++;
    } else {
      files.add(candidate);
    }
  }
  return Receipt(taskId, url, files, unverified: unverified);
}
