import "dart:io";
import "dart:typed_data";

Future<String> artworkVersion(Uri uri) async {
  if (uri.scheme != "file") return uri.toString();
  final file = File.fromUri(uri);
  final stat = await file.stat();
  return "${uri.toString()}:${stat.modified.microsecondsSinceEpoch}:${stat.size}";
}

Future<Uint8List?> readNotificationArtwork(Uri uri) async {
  if (uri.scheme == "file") {
    final file = File.fromUri(uri);
    if (await file.length() > 8 * 1024 * 1024) return null;
    return file.readAsBytes().timeout(const Duration(seconds: 5));
  }
  if (uri.scheme != "https" && uri.scheme != "http") return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    return await _readRemoteArtwork(
      client,
      uri,
    ).timeout(const Duration(seconds: 8));
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List?> _readRemoteArtwork(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  if (response.statusCode != HttpStatus.ok ||
      response.contentLength > 8 * 1024 * 1024) {
    return null;
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
    if (bytes.length > 8 * 1024 * 1024) return null;
  }
  return bytes.takeBytes();
}

Future<bool> preparedArtworkExists(String uri) async {
  final parsed = Uri.tryParse(uri);
  if (parsed?.scheme != "file") return true;
  return File.fromUri(parsed!).exists();
}

Future<String?> saveNotificationArtwork(Uint8List png, String key) async {
  final directory = Directory(
    "${Directory.systemTemp.path}/melody-notification-artwork",
  );
  await directory.create(recursive: true);
  final file = File("${directory.path}/$key.png");
  await file.writeAsBytes(png, flush: true);
  await _pruneArtwork(directory, keep: file);
  return file.uri.toString();
}

Future<void> _pruneArtwork(Directory directory, {required File keep}) async {
  try {
    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith(".png"))
        .cast<File>()
        .toList();
    final dated = <(File, DateTime)>[];
    for (final file in files) {
      dated.add((file, (await file.stat()).modified));
    }
    dated.sort((a, b) => b.$2.compareTo(a.$2));
    for (var index = 64; index < dated.length; index++) {
      if (dated[index].$1.path != keep.path) {
        await dated[index].$1.delete();
      }
    }
  } catch (_) {
    // Artwork cleanup must never fail playback or notification updates.
  }
}
