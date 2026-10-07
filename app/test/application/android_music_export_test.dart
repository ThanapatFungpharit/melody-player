import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/android_music_export.dart";
import "package:melody/core/library/manager.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory root;
  late String data;
  late String private;
  late String public;
  late MusicManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("melody-export");
    data = p.join(root.path, "data");
    private = p.join(data, "Music");
    public = p.join(root.path, "Music", "Melody");
    await Directory(public).create(recursive: true);
    manager = MusicManager.open(
      p.join(data, "library.db"),
      private,
      additionalMusicFolders: [public],
    );
  });

  tearDown(() async {
    manager.close();
    await root.delete(recursive: true);
  });

  AndroidMusicExport export() => AndroidMusicExport(
    manager,
    privateRoot: data,
    publicRoot: public,
    isPlaying: (_) => false,
    onFailure: (_) {},
  );

  test("a published track's leftover private copy is removed", () async {
    // The process ended while the track played, so its private copy stayed.
    final published = File(p.join(public, "Song.mp3"))
      ..writeAsStringSync("song bytes");
    await manager.addTrack(published.path, title: "Song");
    final leftover = File(p.join(private, "Song.mp3"))
      ..writeAsStringSync("song bytes");
    // Unregistered audio without a twin in the library is not provably a
    // copy, and a registered private file is the library's own.
    final unknown = File(p.join(private, "Other.mp3"))
      ..writeAsStringSync("other bytes");
    final registered = File(p.join(private, "Private.mp3"))
      ..writeAsStringSync("private bytes");
    await manager.addTrack(registered.path, title: "Private");
    final receipt = File(p.join(private, ".melody-download-x.json"))
      ..writeAsStringSync("{}");

    expect(await export().removeOrphanedCopies(), 1);
    expect(leftover.existsSync(), isFalse);
    expect(published.existsSync(), isTrue);
    expect(unknown.existsSync(), isTrue);
    expect(registered.existsSync(), isTrue);
    expect(receipt.existsSync(), isTrue);
    expect(await export().removeOrphanedCopies(), 0);
  });

  test("a music folder outside private storage is never swept", () async {
    final shared = p.join(root.path, "Shared");
    final other = MusicManager.open(p.join(data, "other.db"), shared);
    addTearDown(other.close);
    final original = File(p.join(shared, "Song.mp3"))
      ..writeAsStringSync("song bytes");
    await other.addTrack(original.path);
    final twin = File(p.join(shared, "Song copy.mp3"))
      ..writeAsStringSync("song bytes");
    final sweep = AndroidMusicExport(
      other,
      privateRoot: data,
      publicRoot: public,
      isPlaying: (_) => false,
      onFailure: (_) {},
    );
    expect(await sweep.removeOrphanedCopies(), 0);
    expect(twin.existsSync(), isTrue);
  });
}
