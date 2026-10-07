import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/thumbnails.dart";

const _url = "https://i.ytimg.com/vi/abcdefghijk/hq.jpg";
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
    root = await Directory.systemTemp.createTemp("melody-thumbnails");
    cache = ThumbnailCache(root.path);
  });

  tearDown(() => root.delete(recursive: true));

  test("lookups follow the cache's own writes and removals", () async {
    expect(cache.cachedPath(_url), isNull);
    expect(await cache.storeBytes(_url, _png), isTrue);
    final path = cache.cachedPath(_url);
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);

    await cache.remove(_url);
    expect(cache.cachedPath(_url), isNull);

    await cache.storeBytes(_url, _png);
    expect(await cache.retainOnly(const []), 1);
    expect(cache.cachedPath(_url), isNull);
  });

  test("open indexes existing entries once, off the UI isolate", () async {
    await cache.storeBytes(_url, _png);
    const other = "https://i.ytimg.com/vi/zyxwvutsrqp/hq.jpg";
    const empty = "https://i.ytimg.com/vi/emptyentry0/hq.jpg";
    await cache.storeBytes(other, _png);
    // An empty entry, as an interrupted copy by another program might leave.
    await cache.storeBytes(empty, _png);
    File(cache.cachedPath(empty)!).writeAsBytesSync(const []);

    final opened = await ThumbnailCache.open(root.path);
    final path = opened.cachedPath(_url)!;
    expect(opened.cachedPath(other), isNotNull);
    expect(opened.cachedPath(empty), isNull);
    expect(opened.cachedPath("not a url"), isNull);
    // Indexed answers come from memory, not from the disk.
    await File(path).delete();
    expect(opened.cachedPath(_url), path);

    // The cache's own writes and removals keep the index current.
    await opened.remove(other);
    expect(opened.cachedPath(other), isNull);
    await opened.storeBytes(other, _png);
    expect(opened.cachedPath(other), isNotNull);
    // The empty entry goes too.
    expect(await opened.retainOnly(const [_url]), 2);
    expect(opened.cachedPath(other), isNull);
  });

  test("open creates a missing folder", () async {
    final folder = "${root.path}/nested/thumbnails";
    final opened = await ThumbnailCache.open(folder);
    expect(Directory(folder).existsSync(), isTrue);
    expect(opened.cachedPath(_url), isNull);
    expect(await opened.storeBytes(_url, _png), isTrue);
    expect(opened.cachedPath(_url), isNotNull);
  });

  test("repeated lookups do not touch the disk", () async {
    await cache.storeBytes(_url, _png);
    final path = cache.cachedPath(_url)!;
    // Artwork widgets ask on every build; the answer is remembered.
    await File(path).delete();
    expect(cache.cachedPath(_url), path);
  });
}
