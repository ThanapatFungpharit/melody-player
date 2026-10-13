import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/package_runtime.dart";
import "package:melody/application/store.dart";
import "package:path/path.dart" as p;

void main() {
  group("release versions", () {
    test("compare numerically, part by part", () {
      expect(compareReleaseVersions("2026.10.2", "2026.8.19"), 1);
      expect(compareReleaseVersions("2026.8.19", "2026.8.19.1"), -1);
      expect(compareReleaseVersions("1.12.3", "1.12.3.0"), 0);
      expect(compareReleaseVersions("1.9.0", "1.12.3"), -1);
    });
  });

  group("scheduled updates", () {
    late Directory root;
    late ApplicationStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp("melody-runtime");
      store = ApplicationStore.open(
        p.join(root.path, "state.db"),
        defaultDownloadDirectory: p.join(root.path, "music"),
      );
    });

    tearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });

    test("each request installs at one launch only", () {
      store.set(ytDlpRuntimeInfo.requestKey, "2026.10.2");
      const packages = [ytDlpRuntimeInfo, ytMusicRuntimeInfo];

      expect(PackageRuntime.consumeUpdateRequests(store, packages), {
        ytDlpRuntimeInfo.package,
      });
      expect(PackageRuntime.consumeUpdateRequests(store, packages), isEmpty);
    });
  });
}
