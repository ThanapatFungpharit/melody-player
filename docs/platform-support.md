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
| System media controls (lock screen, notification, media keys, Now Playing) | Yes | Yes | No | Yes |
| Center notification artwork on its subject | Yes | Yes | Disabled | Yes (model) |
| Notification shortcut buttons (shuffle, repeat, favorite) | Disabled | Disabled | Disabled | Yes |
| Shuffle and repeat in system controls | Built-in buttons | Built-in buttons | No | Custom buttons |
| Favorite in system controls | No | No | No | Yes |
| Choose the download folder | Yes | Yes | Yes | Inside `Music` (default `Music/Melody`) |
| Import AIFF, WMA, APE, WavPack | Yes | Yes | Yes | No |
| Embed lyrics into tracks already in the library | Yes | Yes | Yes | No |
| ytmusicapi and yt-dlp engine updates | Yes | Yes | Yes | Yes |

"Disabled" means the setting is shown greyed out, with a note explaining why.

## Details

### Linux

- **No system media controls.** The media-session plugin has no Linux (MPRIS)
  implementation, so Melody does not appear in the desktop's media applet
  and hardware media keys do nothing. Playback, background playback, and
  Melody's own keyboard shortcuts work normally. The notification-artwork
  setting is disabled because nothing shows that artwork.
- **File dialogs need a helper.** Importing music, uploading a cookie file,
  and exporting playlists use the desktop's file dialog through `zenity`,
  `kdialog`, or `qarma`. Install one if the dialogs do not open.

### Windows and macOS

- System controls offer only their built-in buttons. Shuffle and repeat map
  to those buttons; favorite has no counterpart, and the Android shortcut
  setting is disabled.
- Artwork focal points use the built-in edge detector instead of the
  Android saliency model.

### Android

- Android 11 or newer is required.
- Downloads are saved straight to a folder inside the public `Music` folder
  (`Music/Melody` by default). Settings can choose another folder there and
  open it in the Files app; folders outside `Music` are refused. Changing it
  moves the library like on desktop.
- Each download stages in private app data, as on desktop (Android would
  refuse partial streams, thumbnails, and receipts in `Music`), and removes
  its staging when it ends.
- Only formats the Android audio decoders play can be imported: AIFF, WMA,
  APE, and WavPack need the desktop FFmpeg decoders.
- Lyrics are written into new downloads, but tracks already in the library
  are not rewritten in the background. Their lyrics still show in Melody and
  work offline.
- Notification shortcut buttons appear beside the playback controls; choose
  which two in **Settings → Appearance → Notifications**.
