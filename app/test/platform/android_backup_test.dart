import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/platform/paths.dart";
import "package:path/path.dart" as p;

/// Android backs up the application support folder (`files/`) unless told
/// otherwise. The rules keep the user's signed-in cookies and this device's
/// Python, runtime updates, cache, and staging out of backups and transfers.
void main() {
  // On Android, data lives in "<application support>/data" (AppPaths.resolve).
  const files = "/files";
  const paths = AppPaths(
    dataDirectory: "$files/data",
    defaultMusicDirectory: "/music",
  );
  // AppPaths joins with the host's separator; Android paths always use "/".
  String relative(String path) =>
      p.posix.relative(path.split(p.separator).join("/"), from: files);

  final excluded = {
    "flet/", // serious_python's extracted interpreter and packages
    relative(paths.cookieFile),
    "${p.posix.dirname(relative(paths.runtime("yt-dlp")))}/",
    "${relative(paths.cache)}/",
    "${p.posix.dirname(relative(paths.downloadStaging))}/",
    relative(paths.musicMoveJournal),
  };

  Set<String> exclusions(String xml) => {
    for (final match in RegExp(
      r'<exclude domain="file" path="([^"]+)" />',
    ).allMatches(xml))
      match.group(1)!,
  };

  String read(String name) =>
      File("android/app/src/main/res/xml/$name").readAsStringSync();

  test("the manifest names both rule files", () {
    final manifest = File(
      "android/app/src/main/AndroidManifest.xml",
    ).readAsStringSync();
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test("Android 11 backups leave out secrets and rebuilt state", () {
    expect(exclusions(read("backup_rules.xml")), excluded);
  });

  test("Android 12+ backups and transfers leave out the same", () {
    final xml = read("data_extraction_rules.xml");
    for (final section in ["cloud-backup", "device-transfer"]) {
      final body = RegExp(
        "<$section>(.*?)</$section>",
        dotAll: true,
      ).firstMatch(xml)?.group(1);
      expect(body, isNotNull, reason: section);
      expect(exclusions(body!), excluded, reason: section);
    }
  });

  test("the library database and lyrics are still backed up", () {
    for (final kept in [paths.database, paths.lyrics]) {
      final path = relative(kept);
      expect(
        excluded.any((rule) => path == rule || path.startsWith(rule)),
        isFalse,
        reason: path,
      );
    }
  });
}
