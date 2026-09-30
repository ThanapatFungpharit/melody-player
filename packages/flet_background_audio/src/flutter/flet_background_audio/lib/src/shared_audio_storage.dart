import "package:flet/flet.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Copies completed Android downloads into the public Music/Melody collection.
class SharedAudioStorageService extends FletService {
  SharedAudioStorageService({required super.control});

  static const MethodChannel _channel = MethodChannel(
    "com.melodyplayer.flet_background_audio/shared_storage",
  );

  @override
  void init() {
    super.init();
    control.addInvokeMethodListener(_invokeMethod);
  }

  Future<dynamic> _invokeMethod(String name, dynamic args) async {
    if (name != "publish") {
      throw ArgumentError("Unknown SharedAudioStorage method: $name");
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError("Shared audio publishing is Android-only");
    }
    final data = Map<String, dynamic>.from(args as Map);
    return _channel.invokeMapMethod<String, dynamic>("publishAudio", {
      "source": data["source"] as String,
      "relativePath": data["relative_path"] as String? ?? "Melody",
    });
  }

  @override
  void dispose() {
    control.removeInvokeMethodListener(_invokeMethod);
    super.dispose();
  }
}
