import "../support/temp.dart";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/thumbnails.dart";
import "package:path/path.dart" as p;

const _track = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
const _other = "1b4e28ba-2fa1-41d2-883f-0016d3cca428";
final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
]);

void main() {
  late Directory root;
  late ThumbnailCache cache;

  setUp(() async {
    root = await createTestDirectory("melody-thumbnails");
    cache = ThumbnailCache(root.path);
  });

  tearDown(() => root.delete(recursive: true));

  test("lookups follow the cache's own writes and removals", () async {
    expect(cache.cachedPath(_track), isNull);
    expect(cache.known(_track), isFalse);
    await cache.store(_track, _png);
    final path = cache.cachedPath(_track);
    expect(path, isNotNull);
    expect(cache.known(_track), isTrue);
    expect(File(path!).existsSync(), isTrue);

    await cache.remove(_track);
    expect(cache.cachedPath(_track), isNull);
    expect(cache.known(_track), isFalse);

    await cache.store(_track, _png);
    expect(await cache.retainOnly(const []), 1);
    expect(cache.cachedPath(_track), isNull);
  });

  test("a file without artwork is remembered, not read again", () async {
    await cache.store(_track, Uint8List(0));
    expect(cache.known(_track), isTrue);
    expect(cache.cachedPath(_track), isNull);
    expect(cache.artworkUri(_track), isNull);

    final opened = await ThumbnailCache.open(root.path);
    expect(opened.known(_track), isTrue);
    expect(opened.cachedPath(_track), isNull);
  });

  test("something that is not an image counts as no artwork", () async {
    await cache.store(_track, Uint8List.fromList([1, 2, 3]));
    expect(cache.known(_track), isTrue);
    expect(cache.cachedPath(_track), isNull);
  });

  test("open indexes existing entries once, off the UI isolate", () async {
    await cache.store(_track, _png);
    await cache.store(_other, _png);

    final opened = await ThumbnailCache.open(root.path);
    final path = opened.cachedPath(_track)!;
    expect(opened.cachedPath(_other), isNotNull);
    // Indexed answers come from memory, not from the disk.
    await File(path).delete();
    expect(opened.cachedPath(_track), path);

    // The cache's own writes and removals keep the index current.
    await opened.remove(_other);
    expect(opened.cachedPath(_other), isNull);
    await opened.store(_other, _png);
    expect(opened.cachedPath(_other), isNotNull);
    expect(await opened.retainOnly(const [_track]), 1);
    expect(opened.cachedPath(_other), isNull);
  });

  test("entries of earlier releases and other files are handled", () async {
    final legacy = File(p.join(root.path, "${"a" * 64}.thumb"))
      ..writeAsBytesSync(_png);
    final notes = File(p.join(root.path, "notes.txt"))
      ..writeAsStringSync("kept");
    final opened = await ThumbnailCache.open(root.path);
    expect(await opened.retainOnly(const []), 1);
    expect(legacy.existsSync(), isFalse);
    expect(notes.existsSync(), isTrue);
  });

  test("open creates a missing folder", () async {
    final folder = "${root.path}/nested/thumbnails";
    final opened = await ThumbnailCache.open(folder);
    expect(Directory(folder).existsSync(), isTrue);
    expect(opened.cachedPath(_track), isNull);
    await opened.store(_track, _png);
    expect(opened.cachedPath(_track), isNotNull);
  });

  test("repeated lookups do not touch the disk", () async {
    await cache.store(_track, _png);
    final path = cache.cachedPath(_track)!;
    // Artwork widgets ask on every build; the answer is remembered.
    await File(path).delete();
    expect(cache.cachedPath(_track), path);
  });

  test("an entry's URI is the file URI of its path", () async {
    await cache.store(_track, _png);
    expect(
      cache.artworkUri(_track),
      Uri.file(File(cache.cachedPath(_track)!).absolute.path).toString(),
    );
    expect(cache.artworkUri(_other), isNull);
  });
}
