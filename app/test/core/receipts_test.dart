import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/core/downloader/receipts.dart";
import "package:melody/core/storage.dart";
import "package:path/path.dart" as p;

const _url = "https://music.youtube.com/watch?v=abc";

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-receipts");
  });

  tearDown(() => root.delete(recursive: true));

  Future<Map<String, String>> owned(String name, String contents) async {
    final path = p.join(root.path, name);
    await File(path).writeAsString(contents);
    return {"filename": name, "sha256": await sha256File(path)};
  }

  Future<void> write(String taskId, List<Map<String, String>> files) =>
      writeReceipt(root.path, taskId, _url, files, filesDirectory: root.path);

  Future<String> rawReceipt(String taskId, Object? data) async {
    final path = receiptPath(root.path, taskId);
    await File(path).writeAsString(jsonEncode(data));
    return path;
  }

  Matcher rejects(String message) => throwsA(
    isA<FormatException>().having((e) => e.message, "message", message),
  );

  test("receipt paths are keyed by task", () {
    expect(receiptPath(root.path, "t1"), p.join(root.path, "t1.json"));
  });

  test("round-trips verified files", () async {
    final song = await owned("song.mp3", "audio");
    final cover = await owned("song.jpg", "image");
    await write("t1", [song, cover]);
    final receipt = await readReceipt(receiptPath(root.path, "t1"));
    expect(receipt.taskId, "t1");
    expect(receipt.url, _url);
    expect(receipt.files, [
      p.join(root.path, "song.mp3"),
      p.join(root.path, "song.jpg"),
    ]);
    expect(receipt.unverified, 0);
  });

  test("receipts vouch for files in another folder", () async {
    final song = await owned("song.mp3", "audio");
    final elsewhere = p.join(root.path, "staging");
    await writeReceipt(elsewhere, "t1", _url, [
      song,
    ], filesDirectory: root.path);
    final receipt = await readReceipt(receiptPath(elsewhere, "t1"));
    expect(receipt.files, [p.join(p.absolute(root.path), "song.mp3")]);
  });

  test("counts missing and changed files as unverified", () async {
    final kept = await owned("kept.mp3", "audio");
    final changed = await owned("changed.mp3", "before");
    await File(p.join(root.path, "changed.mp3")).writeAsString("after");
    await write("t1", [
      kept,
      changed,
      {"filename": "missing.mp3", "sha256": "0" * 64},
    ]);
    final receipt = await readReceipt(receiptPath(root.path, "t1"));
    expect(receipt.files, [p.join(root.path, "kept.mp3")]);
    expect(receipt.unverified, 2);
  });

  test("rejects a receipt whose name does not match its task", () async {
    final song = await owned("song.mp3", "audio");
    final path = await rawReceipt("t1", {
      "schema": 1,
      "task_id": "t2",
      "url": _url,
      "directory": root.absolute.path,
      "files": [song],
    });
    await expectLater(
      () => readReceipt(path),
      rejects("Invalid download receipt identity"),
    );
  });

  test("rejects unknown schemas and malformed contents", () async {
    final song = await owned("song.mp3", "audio");
    await expectLater(
      () async => readReceipt(
        await rawReceipt("t1", {
          "schema": 2,
          "task_id": "t1",
          "url": _url,
          "directory": root.absolute.path,
          "files": [song],
        }),
      ),
      rejects("Invalid download receipt"),
    );
    await expectLater(
      () async => readReceipt(await rawReceipt("t2", ["not", "a", "map"])),
      rejects("Invalid download receipt"),
    );
    await expectLater(
      () async => readReceipt(
        await rawReceipt("t3", {
          "schema": 1,
          "task_id": "t3",
          "directory": root.absolute.path,
          "files": [song],
        }),
      ),
      rejects("Invalid download receipt"),
    );
    // The files' folder must be recorded, and absolute.
    for (final folder in [null, "relative"]) {
      await expectLater(
        () async => readReceipt(
          await rawReceipt("t6", {
            "schema": 1,
            "task_id": "t6",
            "url": _url,
            "directory": ?folder,
            "files": [song],
          }),
        ),
        rejects("Invalid download receipt folder"),
      );
    }
    await expectLater(
      () async => readReceipt(
        await rawReceipt("t4", {
          "schema": 1,
          "task_id": "t4",
          "url": _url,
          "directory": root.absolute.path,
          "files": [],
        }),
      ),
      rejects("Empty download receipt"),
    );
    // Invalid UTF-8 is malformed content, not a retryable read failure.
    final garbled = receiptPath(root.path, "t5");
    await File(garbled).writeAsBytes([0x7b, 0xff, 0xfe, 0x7d]);
    await expectLater(() => readReceipt(garbled), throwsFormatException);
  });

  test("rejects files outside the receipt's folder", () async {
    for (final name in ["../song.mp3", "sub/song.mp3", r"sub\song.mp3", ""]) {
      await write("t1", [
        {"filename": name, "sha256": "0" * 64},
      ]);
      await expectLater(
        () => readReceipt(receiptPath(root.path, "t1")),
        rejects("Download receipt escaped its owned folder"),
        reason: name,
      );
    }
  });

  test("rejects oversized receipts before parsing them", () async {
    final path = receiptPath(root.path, "t1");
    await File(path).writeAsString(" " * (128 * 1024 + 1));
    await expectLater(
      () => readReceipt(path),
      rejects("Invalid download receipt"),
    );
  });
}
