/// Melody's process-scoped audio engine, system media session, and Android
/// storage services.
library melody_audio;

export "src/android_platform.dart" show AndroidPlatform;
export "src/audio_engine.dart"
    show
        AudioDurationChanged,
        AudioEngine,
        AudioEngineEvent,
        AudioEngineListener,
        AudioEngineSnapshot,
        AudioFailed,
        AudioLoaded,
        AudioPlaybackState,
        AudioPositionChanged,
        AudioQueueItem,
        AudioRepeatMode,
        AudioStateChanged,
        AudioTrackChanged,
        MediaCommand;
export "src/system_media_session.dart"
    show
        MediaActionListener,
        MediaSessionState,
        MediaShortcut,
        SystemMediaSession;

import "package:just_audio_media_kit/just_audio_media_kit.dart";

/// Registers desktop decoders. Call once before the first player is created.
void ensureMelodyAudioInitialized() {
  JustAudioMediaKit.ensureInitialized();
}
