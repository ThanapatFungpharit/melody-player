import "package:flet/flet.dart";
import "package:flutter/widgets.dart";
import "package:just_audio_media_kit/just_audio_media_kit.dart";

import "background_audio_session.dart";
import "managed_audio.dart";
import "shared_audio_storage.dart";

class Extension extends FletExtension {
  @override
  void ensureInitialized() {
    JustAudioMediaKit.ensureInitialized();
  }

  @override
  FletService? createService(Control control) {
    return switch (control.type) {
      "ManagedAudio" => ManagedAudioService(control: control),
      "BackgroundAudioSession" => BackgroundAudioSessionService(
          control: control,
        ),
      "SharedAudioStorage" => SharedAudioStorageService(control: control),
      _ => null,
    };
  }

  @override
  Widget? createWidget(Key? key, Control control) => null;
}
