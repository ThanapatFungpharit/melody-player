import "dart:async";

import "package:flutter_media_session/flutter_media_session.dart";
import "package:just_audio_platform_interface/just_audio_platform_interface.dart";

/// Records media-session calls without a native plugin.
class RecordingMediaSessionPlatform extends FlutterMediaSessionPlatform {
  final List<PlaybackState> states = [];
  final List<MediaMetadata> metadata = [];
  final List<Set<MediaAction>?> availableActions = [];
  Completer<MediaMetadata>? nextMetadata;
  bool failNextDeactivate = false;

  /// Holds the next activation until completed.
  Completer<void>? activateGate;

  @override
  Future<void> activate() async {
    final gate = activateGate;
    activateGate = null;
    await gate?.future;
  }

  @override
  Future<void> deactivate() async {
    if (failNextDeactivate) {
      failNextDeactivate = false;
      throw StateError("deactivate failed");
    }
  }

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {
    this.metadata.add(metadata);
    final waiting = nextMetadata;
    if (waiting != null && !waiting.isCompleted) waiting.complete(metadata);
  }

  @override
  Future<void> updatePlaybackState(PlaybackState state) async {
    states.add(state);
  }

  @override
  Future<void> updateAvailableActions(Set<MediaAction>? actions) async {
    availableActions.add(actions);
  }

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> setSkipIntervals({
    int forwardSeconds = 10,
    int backwardSeconds = 10,
  }) async {}

  @override
  Future<void> setAutoHandleInterruptions(bool enabled) async {}

  @override
  Future<void> setBackgroundKeepAlive(bool enabled) async {}

  @override
  Future<void> setWindowsAppUserModelId(
    String id, {
    String? displayName,
    String? iconPath,
  }) async {}

  /// Actions pressed on lock-screen, notification, or desktop controls.
  final StreamController<MediaAction> actions = StreamController.broadcast();

  @override
  Stream<MediaAction> get onMediaAction => actions.stream;
}

/// A just_audio platform whose decoders load instantly unless blocked.
class FakeJustAudioPlatform extends JustAudioPlatform {
  final List<FakeAudioPlayer> players = [];

  /// Holds the next decoder's load until completed.
  Completer<void>? loadGate;

  /// Makes the next decoder stay completed after a seek, like media_kit.
  bool completionOutlivesSeek = false;

  FakeAudioPlayer get last => players.last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = FakeAudioPlayer(request.id, loadGate)
      ..completionOutlivesSeek = completionOutlivesSeek;
    for (final effect in request.androidAudioEffects) {
      if (effect is AndroidLoudnessEnhancerMessage) {
        player
          ..hasEnhancer = true
          ..boostEnabled = effect.enabled
          ..boostDb = effect.targetGain;
      }
    }
    loadGate = null;
    completionOutlivesSeek = false;
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    for (final player in players.where((player) => player.id == request.id)) {
      player.disposed = true;
    }
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    for (final player in players) {
      player.disposed = true;
    }
    return DisposeAllPlayersResponse();
  }
}

class FakeAudioPlayer extends AudioPlayerPlatform {
  FakeAudioPlayer(super.id, this._loadGate);

  static const trackDuration = Duration(minutes: 3);

  final Completer<void>? _loadGate;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final List<Duration?> seeks = [];
  LoadRequest? loadRequest;
  int sourceCount = 0;
  LoopModeMessage loopMode = LoopModeMessage.off;
  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  int _index = 0;
  bool playing = false;
  int playRequests = 0;
  bool disposed = false;
  bool completionOutlivesSeek = false;
  Completer<void>? _playing;

  Duration get position => _position;
  int get index => _index;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  void _broadcast() {
    if (_events.isClosed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: _state,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: _position,
        duration: trackDuration,
        icyMetadata: null,
        currentIndex: _index,
        androidAudioSessionId: null,
      ),
    );
  }

  /// Moves the playhead as if the decoder had been playing.
  void advanceTo(Duration position) {
    _position = position;
    _broadcast();
  }

  /// Simulates an automatic transition to another playlist row.
  void autoAdvance(int index) {
    _index = index;
    _position = Duration.zero;
    _broadcast();
  }

  /// Stalls the decoder for network data, then resumes where it was.
  void stall() {
    _state = ProcessingStateMessage.buffering;
    _broadcast();
  }

  void recover() {
    _state = ProcessingStateMessage.ready;
    _broadcast();
  }

  void complete() {
    _position = trackDuration;
    _state = ProcessingStateMessage.completed;
    _broadcast();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loadRequest = request;
    final message = request.audioSourceMessage;
    sourceCount = message is ConcatenatingAudioSourceMessage
        ? message.children.length
        : 1;
    _state = ProcessingStateMessage.loading;
    _broadcast();
    await _loadGate?.future;
    _index = request.initialIndex ?? 0;
    _position = request.initialPosition ?? Duration.zero;
    _state = ProcessingStateMessage.ready;
    _broadcast();
    return LoadResponse(duration: trackDuration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    playRequests++;
    playing = true;
    _broadcast();
    await (_playing = Completer<void>()).future;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    playing = false;
    _playing?.complete();
    _playing = null;
    _broadcast();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add(request.position);
    _position = request.position ?? Duration.zero;
    _index = request.index ?? _index;
    if (_state == ProcessingStateMessage.completed && !completionOutlivesSeek) {
      _state = ProcessingStateMessage.ready;
    }
    _broadcast();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    ConcatenatingRemoveRangeRequest request,
  ) async {
    sourceCount -= request.endIndex - request.startIndex;
    if (request.startIndex < _index) {
      _index -= request.endIndex - request.startIndex;
    }
    _broadcast();
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    loopMode = request.loopMode;
    return SetLoopModeResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    disposed = true;
    _playing?.complete();
    _playing = null;
    await _events.close();
    return DisposeResponse();
  }

  /// Every volume the decoder was given, in order.
  final List<double> volumes = [];

  /// The Android LoudnessEnhancer attached to this decoder, if any.
  bool hasEnhancer = false;
  bool boostEnabled = false;
  double boostDb = 0;

  /// The gain the enhancer adds right now, in dB.
  double get activeBoostDb => boostEnabled ? boostDb : 0;

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
    AudioEffectSetEnabledRequest request,
  ) async {
    boostEnabled = request.enabled;
    return AudioEffectSetEnabledResponse();
  }

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse>
  androidLoudnessEnhancerSetTargetGain(
    AndroidLoudnessEnhancerSetTargetGainRequest request,
  ) async {
    boostDb = request.targetGain;
    return AndroidLoudnessEnhancerSetTargetGainResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    volumes.add(request.volume);
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async => SetSkipSilenceResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async => SetShuffleOrderResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async => SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
  setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async => SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
  setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async => SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async => SetPreferredPeakBitRateResponse();

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(
    SetAllowsExternalPlaybackRequest request,
  ) async => SetAllowsExternalPlaybackResponse();

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
    ConcatenatingInsertAllRequest request,
  ) async => ConcatenatingInsertAllResponse();

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) async => ConcatenatingMoveResponse();
}
