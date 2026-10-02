/// Durable handoff from download-owned files to application registration.
library;

import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../storage.dart";

String receiptPath(String directory, String taskId) =>
    p.join(directory, ".melody-download-$taskId.json");

Future<void> writeReceipt(
  String directory,
  String taskId,
  String url,
  List<Map<String, String>> files,
) => atomicWrite(
  receiptPath(directory, taskId),
  utf8.encode(
    jsonEncode({"schema": 1, "task_id": taskId, "url": url, "files": files}),
  ),
);

class Receipt {
  const Receipt(this.taskId, this.url, this.files);

  final String taskId;
  final String url;
  final List<String> files;
}

/// Reads and verifies a receipt. Throws [FormatException] for anything that
/// is malformed, escapes its folder, or no longer matches its checksums.
Future<Receipt> readReceipt(String path) async {
  final link = await FileSystemEntity.isLink(path);
  if (link || await File(path).length() > 128 * 1024) {
    throw const FormatException("Invalid download receipt");
  }
  final data = jsonDecode(await File(path).readAsString());
  if (data is! Map) throw const FormatException("Invalid download receipt");
  final taskId = data["task_id"];
  if (taskId is! String ||
      data["schema"] != 1 ||
      !p.equals(path, receiptPath(p.dirname(path), taskId))) {
    throw const FormatException("Invalid download receipt identity");
  }
  final url = data["url"];
  final entries = data["files"];
  if (url is! String || entries is! List) {
    throw const FormatException("Invalid download receipt");
  }
  final files = <String>[];
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
    final candidate = p.join(p.dirname(path), name);
    if (await FileSystemEntity.isLink(candidate) ||
        !await File(candidate).exists() ||
        await sha256File(candidate) != digest) {
      throw const FormatException("Download handoff is missing or corrupt");
    }
    files.add(candidate);
  }
  if (files.isEmpty) throw const FormatException("Empty download receipt");
  return Receipt(taskId, url, files);
}
