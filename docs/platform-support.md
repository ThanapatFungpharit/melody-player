# Platform support and limitations

Melody runs on Windows, Linux, macOS (Intel and Apple Silicon), and Android.
iOS is not supported: it cannot run FFmpeg as a subprocess, which every
download needs.

Some features depend on what the operating system provides. When a platform
lacks a feature, Melody shows its setting disabled with the reason instead of
a control that does nothing. The checks live in `app/lib/platform/features.dart`.

## Feature matrix

| Feature | Windows | macOS | Linux | Android |
| --- | --- | --- | --- | --- |
| System media controls (lock screen, notification, media keys, Now Playing) | Yes | Yes | Yes (MPRIS) | Yes |
| Notification shortcut buttons (shuffle, repeat, favorite) | Disabled | Disabled | Disabled | Yes |
| Shuffle and repeat in system controls | Built-in buttons | Built-in buttons | MPRIS `Shuffle` and `LoopStatus` | Custom buttons |
| Favorite in system controls | No | No | No | Yes |
| Choose the download folder | Yes | Yes | Yes | Inside `Music` (default `Music/Melody`) |
| Import AIFF, WMA, APE, WavPack | Yes | Yes | Yes | No |
| Embed lyrics into tracks already in the library | Yes | Yes | Yes | No |
| ytmusicapi and yt-dlp engine updates | Yes | Yes | Yes | Yes |
| App icon follows the accent color | No | No | No | Yes, once Melody leaves the screen |
| Equalizer (Settings → Sound) | No | No | No | Yes (the system `Equalizer` effect, mapped onto the device's bands) |
| Track and album loudness (track menu → Adjust loudness) | Cuts; raises up to the 6 dB mpv allows, within the track's peaks | Cuts only | Cuts; raises up to the 6 dB mpv allows, within the track's peaks | Cuts; raises up to 12 dB with the limiter |
| Listening statistics, ListenBrainz scrobbling | Yes | Yes | Yes | Yes |
| Low Power Mode follows the system's power saving | Energy Saver, read on return to Melody | Low Power Mode (`pmset`), read on return | Power saver profile (ACPI platform profile or power-profiles-daemon), read on return | Battery Saver, as it changes |

"Disabled" means the setting is shown greyed out, with a note explaining why.
Where there is no equalizer, Settings → Sound says so and keeps its
Loudness group (normalization, and a pointer to the per-track offsets): the bundled libmpv on Windows and Linux has no FFmpeg
filters, and AVPlayer on macOS has no equalizer. On Android the equalizer and
its interaction with audio focus and other apps' effects still need a check on
a physical device; the headless tests drive a fake decoder.

## Details

### Linux

- **System media controls use MPRIS.** The media-session plugin has no Linux
  implementation, so Melody publishes its own MPRIS player
  (`org.mpris.MediaPlayer2.melody`, or `...melody.instance<pid>` for a second
  copy) on the session bus. Desktop media applets, hardware media keys (which
  the desktop routes to MPRIS), and `playerctl` see it. Without a session bus
  Melody plays normally with no system controls.
- **Shuffle and repeat work Melody's way.** Turning MPRIS `Shuffle` on
  shuffles the upcoming tracks once and the toggle returns to off. Setting
  `LoopStatus` to a different value moves Melody's repeat one step through
  its cycle, and `LoopStatus` then reports the mode it landed on. Volume and
  rate stay at 1.0: Melody's volume is its own.
- **File dialogs need a helper.** Importing music, uploading a cookie file,
  and exporting playlists use the desktop's file dialog through `zenity`,
  `kdialog`, or `qarma`. Install one if the dialogs do not open.

### Low Power Mode

**Settings → Power** sets Low Power Mode to off, always on, or on while the
system saves power (the default). Only Android announces a change of its
Battery Saver; on desktop Melody reads the system's state at launch and when
its window comes back, at most every 30 seconds, rather than polling. A
change made while Melody is in the background applies once it returns. A
platform that cannot tell counts as not saving power. The macOS and Windows
readings have not been checked on those systems yet.

### Windows and macOS

- System controls offer only their built-in buttons. Shuffle and repeat map
  to those buttons; favorite has no counterpart, and the Android shortcut
  setting is disabled.

### Android

- Android 11 or newer is required.
- Downloads are saved straight to a folder inside the public `Music` folder
  (`Music/Melody` by default). Settings can choose another folder there and
  open it in the Files app; folders outside `Music` are refused. Changing it
  moves the library like on desktop.
- Each download stages in private app data, as on desktop (Android would
  refuse partial streams and thumbnails in `Music`), and removes
  its staging when it ends, unless it can pick up from there.
- Downloads keep running off screen with a foreground service and its
  notification. Android can refuse to start that service for an app already in
  the background, and allows it six hours a day from Android 15. A download
  Android stops anyway picks up where it left off at the next launch.
- Music is added one file at a time; **Add a folder** is desktop only.
- Melody asks for audio access at launch, because Android otherwise hides music
  it did not create (files added with a file manager, or left by an earlier
  install), so those tracks look missing. Library cleanup does not run without
  that access. Deleting such a file asks for confirmation in an Android dialog.
- Only formats the Android audio decoders play can be imported: AIFF, WMA,
  APE, and WavPack need the desktop FFmpeg decoders.
- Lyrics are written into new downloads, but tracks already in the library
  are not rewritten: **Write lyrics into files** is desktop only. Their lyrics
  still show in Melody and work offline.
- Notification shortcut buttons appear beside the playback controls; choose
  which two in **Settings → Appearance → Notifications**.
