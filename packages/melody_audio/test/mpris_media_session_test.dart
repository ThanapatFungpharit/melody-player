// MPRIS exists only on Linux, and these tests need a private D-Bus server on
// a Unix socket. Elsewhere the dbus package cannot complete its handshake, so
// `activate()` never returns and `tearDown`'s `deactivate()`, queued behind
// it, hangs the whole run (Windows CI hit its job timeout this way).
@TestOn("linux")
library;

import "dart:async";
import "dart:io";

import "package:dbus/dbus.dart";
import "package:flutter/foundation.dart";
import "package:flutter_media_session/flutter_media_session.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/src/audio_engine.dart";
import "package:melody_audio/src/mpris_media_session.dart";
import "package:melody_audio/src/system_media_session.dart";

const _root = "org.mpris.MediaPlayer2";
const _player = "org.mpris.MediaPlayer2.Player";
const _name = "org.mpris.MediaPlayer2.melody";
final _path = DBusObjectPath("/org/mpris/MediaPlayer2");

/// A private bus on a socket in a temporary folder, never the user's.
class _Bus {
  _Bus._(this._server, this._dir, this.address);

  static Future<_Bus> start() async {
    final dir = await Directory.systemTemp.createTemp("melody-mpris-");
    final server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    return _Bus._(server, dir, address);
  }

  final DBusServer _server;
  final Directory _dir;
  final DBusAddress address;
  final List<DBusClient> _clients = [];

  DBusClient client() {
    final client = DBusClient(address);
    _clients.add(client);
    return client;
  }

  /// What a desktop applet or playerctl sees of [name].
  DBusRemoteObject remote([String name = _name]) =>
      DBusRemoteObject(client(), name: name, path: _path);

  Future<void> close() async {
    for (final client in _clients) {
      await client.close();
    }
    await _server.close();
    await _dir.delete(recursive: true);
  }
}

final _playable = <MediaAction>{
  MediaAction.play,
  MediaAction.pause,
  MediaAction.skipToNext,
  MediaAction.skipToPrevious,
  MediaAction.seekTo,
  MediaAction("shuffle"),
  MediaAction("repeat"),
};

Future<void> _publishTrack(
  MprisMediaSessionPlatform platform, {
  String title = "Song",
  Duration position = Duration.zero,
  PlaybackStatus status = PlaybackStatus.playing,
}) async {
  await platform.updateMetadata(
    MediaMetadata(
      title: title,
      artist: "Artist",
      album: "Album",
      artworkUri: "/tmp/art cover.png",
      duration: const Duration(minutes: 3),
    ),
  );
  await platform.updateAvailableActions(_playable);
  await platform.updatePlaybackState(
    PlaybackState(status: status, position: position),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Bus bus;
  late MprisMediaSessionPlatform platform;
  late List<MediaAction> actions;
  StreamSubscription<MediaAction>? subscription;

  MprisMediaSessionPlatform newPlatform() =>
      MprisMediaSessionPlatform(connect: bus.client);

  setUp(() async {
    bus = await _Bus.start();
    platform = newPlatform();
    actions = [];
    subscription = platform.onMediaAction.listen(actions.add);
  });

  tearDown(() async {
    await subscription?.cancel();
    await platform.deactivate();
    await bus.close();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test("claims the MPRIS name and identifies as Melody", () async {
    await platform.activate();
    expect(platform.ownedName, _name);

    final root = await bus.remote().getAllProperties(_root);
    expect(root["Identity"], const DBusString("Melody"));
    expect(root["DesktopEntry"], const DBusString("com.flet.musicplayer"));
    expect(root["CanRaise"], const DBusBoolean(false));

    final node = await bus.remote().introspect();
    expect([
      for (final interface in node.interfaces) interface.name,
    ], containsAll([_root, _player]));
  });

  test("publishes the track, status, and what the queue allows", () async {
    await platform.activate();
    await _publishTrack(platform, position: const Duration(seconds: 30));

    final props = await bus.remote().getAllProperties(_player);
    expect(props["PlaybackStatus"], const DBusString("Playing"));
    expect(props["LoopStatus"], const DBusString("None"));
    expect(props["Shuffle"], const DBusBoolean(false));
    expect(props["CanGoNext"], const DBusBoolean(true));
    expect(props["CanSeek"], const DBusBoolean(true));
    final metadata = props["Metadata"]!.asStringVariantDict();
    expect(metadata["xesam:title"], const DBusString("Song"));
    expect(metadata["xesam:artist"], DBusArray.string(["Artist"]));
    expect(metadata["xesam:album"], const DBusString("Album"));
    expect(
      metadata["mpris:length"],
      DBusInt64(const Duration(minutes: 3).inMicroseconds),
    );
    expect(
      metadata["mpris:artUrl"],
      const DBusString("file:///tmp/art%20cover.png"),
    );
    expect(metadata["mpris:trackid"], isA<DBusObjectPath>());
    final position = props["Position"]!.asInt64();
    expect(position, greaterThanOrEqualTo(30 * 1000000));
    expect(position, lessThan(31 * 1000000));
  });

  test("a paused position stays put", () async {
    await platform.activate();
    await _publishTrack(
      platform,
      position: const Duration(seconds: 12),
      status: PlaybackStatus.paused,
    );
    await settle();
    final position = await bus.remote().getProperty(_player, "Position");
    expect(position, DBusInt64(const Duration(seconds: 12).inMicroseconds));
    expect(
      await bus.remote().getProperty(_player, "PlaybackStatus"),
      const DBusString("Paused"),
    );
  });

  test(
    "announces changes, and Seeked only for a jump within a track",
    () async {
      await platform.activate();
      await _publishTrack(platform, status: PlaybackStatus.paused);
      final remote = bus.remote();
      final changes = <Map<String, DBusValue>>[];
      final seeks = <int>[];
      final changed = remote.propertiesChanged.listen(
        (signal) => changes.add(signal.changedProperties),
      );
      final seeked = DBusRemoteObjectSignalStream(
        object: remote,
        interface: _player,
        name: "Seeked",
      ).listen((signal) => seeks.add(signal.values.single.asInt64()));
      addTearDown(changed.cancel);
      addTearDown(seeked.cancel);
      // A round trip after subscribing makes sure the bus has the match rules.
      await remote.getProperty(_root, "Identity");

      await platform.updatePlaybackState(
        const PlaybackState(status: PlaybackStatus.playing),
      );
      await platform.updatePlaybackState(
        const PlaybackState(
          status: PlaybackStatus.playing,
          position: Duration(minutes: 1),
        ),
      );
      await _publishTrack(platform, title: "Next song");
      await settle();

      expect(
        changes.any((c) => c["PlaybackStatus"] == const DBusString("Playing")),
        isTrue,
      );
      expect(changes.any((c) => c.containsKey("Metadata")), isTrue);
      expect(seeks, [
        const Duration(minutes: 1).inMicroseconds,
      ], reason: "the new track starting at 0 is not a seek");
    },
  );

  group("remote commands", () {
    late DBusRemoteObject remote;

    setUp(() async {
      await platform.activate();
      await _publishTrack(platform, position: const Duration(seconds: 10));
      remote = bus.remote();
    });

    Future<void> call(String name, [List<DBusValue> values = const []]) =>
        remote.callMethod(_player, name, values);

    List<String> names() => [for (final action in actions) action.name];

    test("transport methods become media actions", () async {
      await call("PlayPause");
      await call("Play");
      await call("Next");
      await call("Previous");
      await call("Stop");
      await settle();
      expect(names(), [
        "pause",
        "play",
        "skipToNext",
        "skipToPrevious",
        "stop",
      ]);
    });

    test("Next does nothing when the queue has no next row", () async {
      await platform.updateAvailableActions({
        MediaAction.pause,
        MediaAction.seekTo,
      });
      expect(
        await remote.getProperty(_player, "CanGoNext"),
        const DBusBoolean(false),
      );
      await call("Next");
      await settle();
      expect(actions, isEmpty);
    });

    test("SetPosition seeks only the current track", () async {
      final metadata = (await remote.getProperty(
        _player,
        "Metadata",
      )).asStringVariantDict();
      final track = metadata["mpris:trackid"]!;
      await call("SetPosition", [
        DBusObjectPath("/org/mpris/MediaPlayer2/melody/track/999"),
        DBusInt64(const Duration(seconds: 5).inMicroseconds),
      ]);
      await call("SetPosition", [
        track,
        DBusInt64(const Duration(seconds: 90).inMicroseconds),
      ]);
      await settle();
      expect(names(), ["seekTo"]);
      expect(actions.single.seekPosition, const Duration(seconds: 90));
    });

    test("Seek moves relative to now, and past the end acts as Next", () async {
      await platform.updatePlaybackState(
        const PlaybackState(
          status: PlaybackStatus.paused,
          position: Duration(seconds: 10),
        ),
      );
      await call("Seek", [
        DBusInt64(-const Duration(seconds: 30).inMicroseconds),
      ]);
      await call("Seek", [
        DBusInt64(const Duration(seconds: 5).inMicroseconds),
      ]);
      await call("Seek", [DBusInt64(const Duration(hours: 1).inMicroseconds)]);
      await settle();
      expect(names(), ["seekTo", "seekTo", "skipToNext"]);
      expect(actions[0].seekPosition, Duration.zero);
      expect(actions[1].seekPosition, const Duration(seconds: 15));
    });

    test("shuffle is one-shot and repeat cycles", () async {
      await remote.setProperty(_player, "Shuffle", const DBusBoolean(true));
      await remote.setProperty(
        _player,
        "LoopStatus",
        const DBusString("Playlist"),
      );
      // Asking for the mode already set is not a step through the cycle.
      await remote.setProperty(_player, "LoopStatus", const DBusString("None"));
      await settle();
      expect(names(), ["shuffle", "repeat"]);
      expect(
        await remote.getProperty(_player, "Shuffle"),
        const DBusBoolean(false),
      );
    });

    test("read-only properties refuse writes", () async {
      await expectLater(
        remote.setProperty(
          _player,
          "PlaybackStatus",
          const DBusString("Stopped"),
        ),
        throwsA(isA<DBusMethodResponseException>()),
      );
    });
  });

  test("a second Melody takes an instance name", () async {
    await platform.activate();
    final second = newPlatform();
    addTearDown(second.deactivate);
    await second.activate();
    expect(second.ownedName, "$_name.instance$pid");
  });

  test("deactivating releases the name and forgets the track", () async {
    await platform.activate();
    await _publishTrack(platform);
    await platform.deactivate();
    expect(platform.ownedName, isNull);
    final dbus = DBusRemoteObject(
      bus.client(),
      name: "org.freedesktop.DBus",
      path: DBusObjectPath("/org/freedesktop/DBus"),
    );
    final owned = await dbus.callMethod(
      "org.freedesktop.DBus",
      "NameHasOwner",
      [const DBusString(_name)],
    );
    expect(owned.values.single, const DBusBoolean(false));

    await platform.activate();
    final metadata = (await bus.remote().getProperty(
      _player,
      "Metadata",
    )).asStringVariantDict();
    expect(metadata.keys, ["mpris:trackid"]);
  });

  test("no session bus leaves playback alone", () async {
    final missing = MprisMediaSessionPlatform(
      connect: () =>
          DBusClient(DBusAddress.unix(path: "${bus._dir.path}/no-such-bus")),
    );
    await missing.activate();
    expect(missing.ownedName, isNull);
    await _publishTrack(missing);
    await missing.deactivate();
  });

  group("SystemMediaSession on Linux", () {
    final originalPlatform = FlutterMediaSessionPlatform.instance;
    final session = SystemMediaSession.instance;
    final commands = <MediaCommand>[];
    void listener(MediaCommand command, Duration? _) => commands.add(command);

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      FlutterMediaSessionPlatform.instance = platform;
      commands.clear();
      session.attach(listener);
    });

    tearDown(() async {
      await session.deactivateForStop();
      session.detach(listener);
      FlutterMediaSessionPlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = null;
    });

    test("publishes through MPRIS and hears its commands", () async {
      await session.sync(
        const MediaSessionState(
          title: "Track",
          artist: "Artist",
          duration: Duration(minutes: 2),
          playing: true,
          hasNext: true,
          canShuffle: true,
        ),
      );
      final remote = bus.remote();
      final metadata = (await remote.getProperty(
        _player,
        "Metadata",
      )).asStringVariantDict();
      expect(metadata["xesam:title"], const DBusString("Track"));
      expect(
        await remote.getProperty(_player, "PlaybackStatus"),
        const DBusString("Playing"),
      );

      // With no decoder loaded, the engine passes commands to the app.
      await remote.callMethod(_player, "Next", const []);
      await remote.setProperty(_player, "Shuffle", const DBusBoolean(true));
      await settle();
      expect(commands, [MediaCommand.skipToNext, MediaCommand.shuffleUpcoming]);

      await session.deactivateForStop();
      expect(platform.ownedName, isNull);
    });
  });
}
