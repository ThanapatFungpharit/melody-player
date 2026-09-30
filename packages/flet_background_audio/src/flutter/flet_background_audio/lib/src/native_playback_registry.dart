/// The one live native playback engine mounted by Melody's Flet page.
///
/// The media-session service uses this process-local registry so lock-screen
/// actions operate the decoder directly. Falling back to Python is reserved
/// for actions that need application policy, such as skipping an ephemeral
/// stream into a library queue that is not installed in the native engine.
abstract interface class NativePlaybackEngine {
  Future<bool> handleMediaAction(String action, {Duration? seekPosition});
}

NativePlaybackEngine? activeNativePlaybackEngine;
