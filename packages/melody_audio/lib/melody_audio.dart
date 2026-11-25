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
export "src/equalizer.dart"
    show EqualizerBand, EqualizerSettings, equalizerGainAt;
export "src/notification_artwork.dart" show useNotificationArtworkDirectory;
export "src/system_media_session.dart"
    show
        MediaActionListener,
        MediaSessionState,
        MediaShortcut,
        SystemMediaSession;

import "package:flutter/foundation.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:just_audio_media_kit/just_audio_media_kit.dart";

import "src/mpris_media_session.dart";

/// Registers desktop decoders, and on Linux the MPRIS media session. Call
/// once before the first player is created.
void ensureMelodyAudioInitialized() {
  JustAudioMediaKit.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    FlutterMediaSessionPlatform.instance = MprisMediaSessionPlatform();
  }
}
