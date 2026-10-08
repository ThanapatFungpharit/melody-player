import "package:flutter/services.dart";

Future<String> artworkVersion(Uri uri) async => uri.toString();

Future<Uint8List?> readNotificationArtwork(Uri uri) async {
  if (uri.scheme == "data") return uri.data?.contentAsBytes();
  if (uri.scheme != "http" && uri.scheme != "https") return null;
  final data = await NetworkAssetBundle(uri).load(uri.toString());
  return data.buffer.asUint8List();
}

/// Web artwork lives in data URIs; there is no folder.
void useNotificationArtworkDirectory(String path) {}

/// Web artwork lives in data URIs, so nothing survives a reload.
Future<String?> existingNotificationArtwork(String key) async => null;

Future<String?> saveNotificationArtwork(Uint8List png, String key) async =>
    Uri.dataFromBytes(png, mimeType: "image/png").toString();

Future<bool> preparedArtworkExists(String uri) async => true;
