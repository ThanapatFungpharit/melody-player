import "dart:async";
import "dart:io";

import "package:dbus/dbus.dart";
import "package:flutter/foundation.dart";
import "package:flutter_media_session/flutter_media_session.dart";

const _rootInterface = "org.mpris.MediaPlayer2";
const _playerInterface = "org.mpris.MediaPlayer2.Player";
const _propertiesInterface = "org.freedesktop.DBus.Properties";
final _objectPath = DBusObjectPath("/org/mpris/MediaPlayer2");

/// Signals [MprisPlayer] sends; the MPRIS object in production.
typedef MprisSignalSink =
    Future<void> Function(String interface, String name, List<DBusValue>);

/// flutter_media_session's interface for Linux, as an MPRIS player on the
/// session bus (https://specifications.freedesktop.org/mpris-spec/latest/).
///
/// The plugin has no Linux implementation. Desktop media applets, media keys
/// (through the desktop), and tools such as playerctl all talk MPRIS, so this
/// lets [SystemMediaSession] drive Linux exactly as it drives the others.
///
/// A missing or refusing session bus is not an error: activation logs it and
/// every later update is kept but not sent, since system controls never stop
/// the actual audio path.
class MprisMediaSessionPlatform extends FlutterMediaSessionPlatform {
  MprisMediaSessionPlatform({
    DBusClient Function()? connect,
    this.busName = "org.mpris.MediaPlayer2.melody",
    this.desktopEntry = "com.flet.musicplayer",
  }) : _connect = connect ?? DBusClient.session;

  final DBusClient Function() _connect;

  /// The well-known name; a second instance takes `<busName>.instance<pid>`.
  final String busName;

  /// The .desktop file's basename, which applets use for the app's icon.
  final String desktopEntry;

  final StreamController<MediaAction> _actions =
      StreamController<MediaAction>.broadcast();
  late final MprisPlayer player = MprisPlayer(
    identity: "Melody",
    desktopEntry: desktopEntry,
    onAction: _actions.add,
  );

  DBusClient? _client;
  _MprisObject? _object;
  String? _ownedName;
  Future<void> _lifecycle = Future<void>.value();

  /// The bus name Melody owns, or null while it is not on a bus.
  String? get ownedName => _ownedName;

  @override
  Stream<MediaAction> get onMediaAction => _actions.stream;

  @override
  Future<void> activate() => _serialize(_activate);

  @override
  Future<void> deactivate() => _serialize(_deactivate);

  Future<void> _serialize(Future<void> Function() step) {
    final next = _lifecycle.then((_) => step());
    _lifecycle = next.catchError((Object _) {});
    return next;
  }

  Future<void> _activate() async {
    if (_client != null) return;
    final client = _connect();
    final object = _MprisObject(player);
    try {
      await client.registerObject(object);
      var name = busName;
      var reply = await client.requestName(
        name,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply == DBusRequestNameReply.exists) {
        // Another Melody holds the name; the spec's suffix keeps both visible.
        name = "$busName.instance$pid";
        reply = await client.requestName(
          name,
          flags: {DBusRequestNameFlag.doNotQueue},
        );
      }
      if (reply != DBusRequestNameReply.primaryOwner &&
          reply != DBusRequestNameReply.alreadyOwner) {
        throw StateError("the bus refused $name ($reply)");
      }
      _client = client;
      _object = object;
      _ownedName = name;
      player.sink = object.emitSignal;
    } catch (error) {
      debugPrint("MPRIS is unavailable, so no media controls: $error");
      try {
        await client.close();
      } catch (_) {
        // The connection may never have opened.
      }
    }
  }

  Future<void> _deactivate() async {
    player.sink = null;
    player.reset();
    final client = _client;
    final object = _object;
    final name = _ownedName;
    _client = null;
    _object = null;
    _ownedName = null;
    if (client == null) return;
    try {
      if (name != null) await client.releaseName(name);
      if (object != null) await client.unregisterObject(object);
    } finally {
      await client.close();
    }
  }

  @override
  Future<void> updateMetadata(MediaMetadata metadata) =>
      player.updateMetadata(metadata);

  @override
  Future<void> updatePlaybackState(PlaybackState state) =>
      player.updatePlaybackState(state);

  @override
  Future<void> updateAvailableActions(Set<MediaAction>? actions) =>
      player.updateAvailableActions(actions);

  // The rest of the interface is for other platforms.

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> setWindowsAppUserModelId(
    String id, {
    String? displayName,
    String? iconPath,
  }) async {}

  @override
  Future<void> setSkipIntervals({
    int forwardSeconds = 10,
    int backwardSeconds = 10,
  }) async {}

  @override
  Future<void> setAutoHandleInterruptions(bool enabled) async {}
}

/// The MPRIS root and player interfaces, apart from the bus connection.
@visibleForTesting
class MprisPlayer {
  MprisPlayer({
    required this.identity,
    required this.desktopEntry,
    required this.onAction,
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start());

  final String identity;
  final String desktopEntry;
  final void Function(MediaAction action) onAction;
  final Stopwatch _clock;

  /// Where signals go; null while not on a bus.
  MprisSignalSink? sink;

  MediaMetadata? _metadata;
  int _track = 0;
  int _stateTrack = 0;
  (String?, String?, String?)? _trackKey;
  PlaybackStatus _status = PlaybackStatus.paused;
  MediaRepeatMode _repeat = MediaRepeatMode.none;
  Duration _position = Duration.zero;
  Duration _positionAt = Duration.zero;
  Set<String> _actions = const {};
  bool _hasState = false;

  /// Forgets the session, as a newly started player would.
  void reset() {
    _metadata = null;
    _trackKey = null;
    _status = PlaybackStatus.paused;
    _repeat = MediaRepeatMode.none;
    _position = Duration.zero;
    _positionAt = _clock.elapsed;
    _actions = const {};
    _hasState = false;
  }

  bool get _playing =>
      _status == PlaybackStatus.playing || _status == PlaybackStatus.buffering;

  /// The position now, advancing while playing.
  Duration get position {
    if (!_playing) return _position;
    final position = _position + (_clock.elapsed - _positionAt);
    final length = _metadata?.duration ?? Duration.zero;
    return length > Duration.zero && position > length ? length : position;
  }

  Duration get _length => _metadata?.duration ?? Duration.zero;

  DBusObjectPath get trackId => _metadata == null
      ? DBusObjectPath("/org/mpris/MediaPlayer2/TrackList/NoTrack")
      : DBusObjectPath("/org/mpris/MediaPlayer2/melody/track/$_track");

  Future<void> updateMetadata(MediaMetadata metadata) async {
    final key = (metadata.title, metadata.artist, metadata.album);
    final before = _capabilities;
    // Duration and artwork arrive in later updates for the same track.
    if (key != _trackKey) {
      _trackKey = key;
      _track++;
    }
    _metadata = metadata;
    await _changed(_playerInterface, {
      "Metadata": metadataValue,
      ..._capabilityChanges(before),
    });
  }

  Future<void> updatePlaybackState(PlaybackState state) async {
    final expected = position;
    final sameTrack = _stateTrack == _track;
    _stateTrack = _track;
    // MPRIS has no buffering status; a stalled track is still "Playing".
    final status = state.status == PlaybackStatus.buffering
        ? PlaybackStatus.playing
        : state.status;
    _position = state.position < Duration.zero ? Duration.zero : state.position;
    _positionAt = _clock.elapsed;
    final changed = <String, DBusValue>{};
    if (!_hasState || status != _status) {
      _status = status;
      changed["PlaybackStatus"] = DBusString(_statusName);
    }
    if (!_hasState || state.repeatMode != _repeat) {
      _repeat = state.repeatMode;
      changed["LoopStatus"] = DBusString(_loopName);
    }
    // Melody's shuffle is a one-shot command, so the toggle snaps back.
    changed["Shuffle"] = const DBusBoolean(false);
    final jumped = (_position - expected).abs() > const Duration(seconds: 1);
    final first = !_hasState;
    _hasState = true;
    await _changed(_playerInterface, changed);
    // Clients extrapolate Position themselves and only learn of a jump here.
    // A new track starting over is not a seek.
    if (!first && sameTrack && jumped) {
      await sink?.call(_playerInterface, "Seeked", [
        DBusInt64(_position.inMicroseconds),
      ]);
    }
  }

  Future<void> updateAvailableActions(Set<MediaAction>? actions) async {
    final before = _capabilities;
    _actions = actions == null
        ? {"play", "pause", "skipToNext", "skipToPrevious", "seekTo"}
        : {for (final action in actions) action.name};
    await _changed(_playerInterface, _capabilityChanges(before));
  }

  Map<String, DBusValue> _capabilityChanges(Map<String, bool> before) => {
    for (final entry in _capabilities.entries)
      if (before[entry.key] != entry.value) entry.key: DBusBoolean(entry.value),
  };

  Map<String, bool> get _capabilities => {
    "CanGoNext": _actions.contains("skipToNext"),
    "CanGoPrevious": _actions.contains("skipToPrevious"),
    // Melody publishes only the one of Play and Pause that applies now, but
    // a client must be able to toggle either way while a track is loaded.
    "CanPlay": _metadata != null,
    "CanPause": _metadata != null,
    "CanSeek": _actions.contains("seekTo") && _length > Duration.zero,
  };

  String get _statusName => switch (_status) {
    PlaybackStatus.playing || PlaybackStatus.buffering => "Playing",
    PlaybackStatus.idle => "Stopped",
    PlaybackStatus.paused ||
    PlaybackStatus.ended ||
    PlaybackStatus.error => "Paused",
  };

  String get _loopName => switch (_repeat) {
    MediaRepeatMode.one => "Track",
    MediaRepeatMode.all => "Playlist",
    MediaRepeatMode.none => "None",
  };

  DBusValue get metadataValue {
    final metadata = _metadata;
    if (metadata == null) {
      return DBusDict.stringVariant({"mpris:trackid": trackId});
    }
    final artwork = artUrl(metadata.artworkUri);
    return DBusDict.stringVariant({
      "mpris:trackid": trackId,
      if (_length > Duration.zero)
        "mpris:length": DBusInt64(_length.inMicroseconds),
      if (metadata.title != null) "xesam:title": DBusString(metadata.title!),
      if (metadata.artist != null)
        "xesam:artist": DBusArray.string([metadata.artist!]),
      if (metadata.album != null) "xesam:album": DBusString(metadata.album!),
      if (artwork != null) "mpris:artUrl": DBusString(artwork),
    });
  }

  Map<String, DBusValue> get rootProperties => {
    "CanQuit": const DBusBoolean(false),
    "CanRaise": const DBusBoolean(false),
    "HasTrackList": const DBusBoolean(false),
    "Identity": DBusString(identity),
    "DesktopEntry": DBusString(desktopEntry),
    "SupportedUriSchemes": DBusArray.string(const []),
    "SupportedMimeTypes": DBusArray.string(const []),
  };

  Map<String, DBusValue> get playerProperties => {
    "PlaybackStatus": DBusString(_statusName),
    "LoopStatus": DBusString(_loopName),
    "Rate": const DBusDouble(1),
    "Shuffle": const DBusBoolean(false),
    "Metadata": metadataValue,
    // Melody's volume is its own mixer and stays in the app.
    "Volume": const DBusDouble(1),
    "Position": DBusInt64(position.inMicroseconds),
    "MinimumRate": const DBusDouble(1),
    "MaximumRate": const DBusDouble(1),
    for (final entry in _capabilities.entries)
      entry.key: DBusBoolean(entry.value),
    "CanControl": const DBusBoolean(true),
  };

  Map<String, DBusValue>? properties(String interface) => switch (interface) {
    _rootInterface => rootProperties,
    _playerInterface => playerProperties,
    _ => null,
  };

  /// A remote client's method call; returns null for an unknown method.
  DBusMethodResponse? call(
    String interface,
    String name,
    List<DBusValue> args,
  ) {
    if (interface == _rootInterface) {
      // CanRaise and CanQuit are false, so these have no effect.
      if (name == "Raise" || name == "Quit") {
        return DBusMethodSuccessResponse();
      }
      return null;
    }
    if (interface != _playerInterface) return null;
    switch (name) {
      case "Play":
        _send("play");
      case "Pause":
        _send("pause");
      case "PlayPause":
        _send(_playing ? "pause" : "play");
      case "Stop":
        _send("stop");
      case "Next":
        if (_actions.contains("skipToNext")) _send("skipToNext");
      case "Previous":
        if (_actions.contains("skipToPrevious")) _send("skipToPrevious");
      case "Seek":
        if (args.length != 1 || args.first is! DBusInt64) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        _seekBy(Duration(microseconds: args.first.asInt64()));
      case "SetPosition":
        if (args.length != 2 ||
            args[0] is! DBusObjectPath ||
            args[1] is! DBusInt64) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        _setPosition(
          args[0] as DBusObjectPath,
          Duration(microseconds: args[1].asInt64()),
        );
      case "OpenUri":
        return DBusMethodErrorResponse.failed("Melody does not open URIs.");
      default:
        return null;
    }
    return DBusMethodSuccessResponse();
  }

  /// A remote client's property write.
  DBusMethodResponse setProperty(
    String interface,
    String name,
    DBusValue value,
  ) {
    if (interface != _playerInterface) {
      return DBusMethodErrorResponse.propertyReadOnly();
    }
    switch (name) {
      case "Shuffle":
        if (value is! DBusBoolean) return DBusMethodErrorResponse.invalidArgs();
        // Turning shuffle on shuffles what is upcoming once.
        if (value.value && _actions.contains("shuffle")) _send("shuffle");
        unawaited(
          _changed(_playerInterface, {"Shuffle": const DBusBoolean(false)}),
        );
      case "LoopStatus":
        if (value is! DBusString) return DBusMethodErrorResponse.invalidArgs();
        // Melody repeats by cycling, so any different mode advances it once;
        // LoopStatus then reports where it landed.
        if (value.value != _loopName && _actions.contains("repeat")) {
          _send("repeat");
        }
      case "Rate" || "Volume":
        // Only 1.0 is supported; a client may still try to set it.
        break;
      default:
        return DBusMethodErrorResponse.propertyReadOnly();
    }
    return DBusMethodSuccessResponse();
  }

  void _seekBy(Duration offset) {
    if (!_actions.contains("seekTo") || _length <= Duration.zero) return;
    final target = position + offset;
    if (target > _length) {
      // The spec: seeking past the end acts like Next.
      if (_actions.contains("skipToNext")) _send("skipToNext");
      return;
    }
    _seek(target < Duration.zero ? Duration.zero : target);
  }

  void _setPosition(DBusObjectPath track, Duration target) {
    // A stale track ID means the track changed since the client looked.
    if (track != trackId || _metadata == null) return;
    if (!_actions.contains("seekTo")) return;
    if (target < Duration.zero || target > _length) return;
    _seek(target);
  }

  void _seek(Duration target) =>
      onAction(MediaAction("seekTo", seekPosition: target));

  void _send(String name) => onAction(MediaAction(name));

  Future<void> _changed(String interface, Map<String, DBusValue> values) async {
    final send = sink;
    if (send == null || values.isEmpty) return;
    await send(_propertiesInterface, "PropertiesChanged", [
      DBusString(interface),
      DBusDict.stringVariant(values),
      DBusArray.string(const []),
    ]);
  }
}

/// MPRIS wants a URI; prepared artwork can be a plain path.
@visibleForTesting
String? artUrl(String? artwork) {
  if (artwork == null || artwork.isEmpty) return null;
  if (artwork.startsWith("/")) return Uri.file(artwork).toString();
  return artwork;
}

class _MprisObject extends DBusObject {
  _MprisObject(this.player) : super(_objectPath);

  final MprisPlayer player;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    return player.call(
          methodCall.interface ?? "",
          methodCall.name,
          methodCall.values,
        ) ??
        DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = player.properties(interface)?[name];
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    final values = player.properties(interface);
    if (values == null) return DBusMethodErrorResponse.unknownInterface();
    return DBusGetAllPropertiesResponse(values);
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async => player.setProperty(interface, name, value);

  /// Some clients (Qt's dynamic interfaces, bus browsers) look a player up
  /// through introspection before using it.
  @override
  List<DBusIntrospectInterface> introspect() => _introspection;
}

final _introspection = parseDBusIntrospectXml(_introspectionXml).interfaces;

/// The two MPRIS interfaces Melody implements, as the spec defines them.
const _introspectionXml = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek">
      <arg name="Offset" type="x" direction="in"/>
    </method>
    <method name="SetPosition">
      <arg name="TrackId" type="o" direction="in"/>
      <arg name="Position" type="x" direction="in"/>
    </method>
    <method name="OpenUri">
      <arg name="Uri" type="s" direction="in"/>
    </method>
    <signal name="Seeked">
      <arg name="Position" type="x"/>
    </signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>
""";
