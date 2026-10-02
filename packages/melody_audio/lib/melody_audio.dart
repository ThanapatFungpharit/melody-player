/// Melody's process-scoped audio engine, media session, and native helpers.
library melody_audio;

export "src/background_audio_session.dart"
    show MediaActionListener, NativeMediaSessionRuntime;
export "src/managed_audio.dart" show NativeAudioRuntime, NativeAudioListener;
export "src/native_bridge.dart" show MelodyNative;

import "package:just_audio_media_kit/just_audio_media_kit.dart";

/// Registers desktop decoders. Call once before the first player is created.
void ensureMelodyAudioInitialized() {
  JustAudioMediaKit.ensureInitialized();
}
