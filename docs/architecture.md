# Architecture and invariants

Melody is a Flutter application. Dart owns the UI, the application lifecycle,
durable state, the library, the queue, playback policy, download coordination,
and artwork verification. Python runs exactly one thing: the worker in
`worker/`, which hosts ytmusicapi and yt-dlp, embedded with
[serious_python](https://pub.dev/packages/serious_python)
and reached only through `app/lib/worker/`. Audio playback and system media
controls live in the repository-owned `packages/melody_audio` plugin.

```mermaid
flowchart TD
    Shell[Desktop or mobile shell] --> Controllers[ui/controllers]
    Shell --> AppState[ui/app_state.dart: MelodyApp]
    Controllers --> AppState
    AppState --> Application[application/: use cases]
    Controllers --> Application
    Application --> Core[core/: library, storage, identity, artwork, downloader]
    Application --> AudioBackend[audio/: NativeAudioBackend]
    AudioBackend --> Plugin[melody_audio: AudioEngine + SystemMediaSession]
    Core --> Client[worker/: WorkerClient]
    Application --> Client
    Client -->|JSON frames over serious_python's FFI bridge| Python[worker/: ytmusicapi + yt-dlp + runtime updater]
```

## Where things live

| Concern | Location |
| --- | --- |
| Entry point, startup, app lifecycle | `app/lib/main.dart` |
| Service composition (stores, library, worker, coordinators) | `app/lib/services.dart` |
| Flutter UI: shells, pages, widgets, dialogs | `app/lib/ui/` (`desktop/`, `mobile/`, `shared/`) |
| UI state and feature workflows | `app/lib/ui/app_state.dart`, `app/lib/ui/controllers/` |
| Application use cases | `app/lib/application/` |
| Domain capabilities | `app/lib/core/` |
| Python boundary (FFI transport, typed client) | `app/lib/worker/` |
| Audio adapter onto the plugin | `app/lib/audio/` |
| Per-platform data, music, and FFmpeg paths | `app/lib/platform/` |
| Audio engine, media session, Android folders (Dart + Kotlin) | `packages/melody_audio/` |
| Python code | `worker/src/melody_worker/` (entry point `worker/src/main.py`) |
| Native runner projects | `app/{android,linux,macos,windows}/` |
| Tests | `app/test/`, `packages/melody_audio/test/`, `worker/tests/`, `tools/tests/` |
| Assets | `packages/melody_audio/assets/` (saliency model); app icons in the runner projects |
| Build, development, and validation tooling (`uv run melody-*`) | `tools/{build,dev,checks}/`, `.github/workflows/` |

Generated files are not committed: the Flutter `ephemeral/` folders, the
generated plugin registrants for Android, `.dart_tool/`, and the FFmpeg
and Python staging under `app/media/`, `app/build/`, and
`app/android/app/src/main/jniLibs/`. The desktop plugin registrants are
committed, as Flutter's templates expect, and so are the `pubspec.lock` and
`uv.lock` files.

## Dependency rules

- `core/` owns independently usable capabilities: SQLite and filesystem
  primitives (`storage.dart`), the music library (`library/`), canonical media
  identity (`media.dart`), embedded-artwork reading, failure classification
  (`errors.dart`), and the downloader. It never imports `application/` or UI.
- `application/` owns use cases that cross capabilities: the application store
  and settings models, the YouTube Music catalog, saved lyrics, the download
  coordinator, the library service, the queue and playback controller, the
  thumbnail cache, cookie validation, the ytmusicapi and yt-dlp runtime
  status, and upgrades of older storage layouts (`storage_upgrade.dart`).
  It never imports UI.
- `services.dart` opens everything in order and exposes it as `AppServices`.
- `ui/app_state.dart` (`MelodyApp`) is the UI's root state: messages,
  navigation, panels, system media synchronization, follow-ups for requested
  downloads, and the feature controllers. Controllers receive `MelodyApp`, so
  the two reference each other; the cycle stays inside `ui/`.
- `ui/desktop/` and `ui/mobile/` never import each other. Both use
  `ui/controllers/` and `ui/shared/`.
- Only `worker/` talks to Python, and only `audio/` talks to the audio plugin.
- `worker/` (Python) contains no application policy. It receives yt-dlp
  options and ytmusicapi call arguments from the app, returns trimmed info
  dictionaries, JSON-safe ytmusicapi replies, and raw failure facts, and
  streams download progress. Option building, result mapping, and failure
  classification are Dart.

## The Python boundary

Python remains for what has no Dart equivalent: ytmusicapi (YouTube Music's
private API: song search, radio, playlists, lyrics), yt-dlp (stream URLs and
downloads), and choosing the release of each to import (the updater must run
inside the interpreter, before the first import). Everything else is Dart.

`WorkerClient` (`app/lib/worker/worker_client.dart`) is the app's only API to
Python. It is a small typed request/response client; nothing else sees frames,
ports, or the interpreter. `transport.dart` holds the two transports:

- `BridgeTransport`: the embedded interpreter, started with
  `SeriousPython.run` and reached through serious_python's in-process
  `PythonBridge` (`dart:ffi` calls into `libdart_bridge`; no sockets or
  subprocess). Frames are UTF-8 JSON byte buffers; serious_python copies each
  one into native memory and frees it, so no buffer ownership crosses the
  boundary.
- `ProcessTransport`: a standalone interpreter speaking newline-delimited JSON
  on stdio, used by integration tests and source-tree development
  (`MELODY_WORKER_PYTHON`).

### Protocol

Requests are `{"id", "op", ...}`; each gets exactly one
`{"id", "ok": true, "result"}` or `{"id", "ok": false, "error"}` reply. The
worker also emits `{"event": "ready", "status"}` once and
`{"event": "progress", "task", ...}` during downloads.

| Operation | Purpose |
| --- | --- |
| `ytmusic` | `YTMusic().<method>(**arguments)` for `search`, `get_watch_playlist`, `get_lyrics`, or `get_playlist`, as JSON |
| `extract` | `YoutubeDL(options).extract_info(target, download=False)`, trimmed to the fields Melody reads (stream URLs) |
| `download` | Run yt-dlp into a staging directory owned by the app, emitting `progress` events; optional `metadata` (such as `lyrics`) becomes tags FFmpegMetadata writes |
| `tag` | Copy an audio file with FFmpeg (through yt-dlp, so `ffmpeg_location` applies), keeping every stream and tag and setting `metadata` tags such as `lyrics` |
| `cancel` | Stop a download at its next progress hook; never queued behind other work |
| `latest_release` | Newest compatible release of `package` (`yt-dlp` or `ytmusicapi`) on PyPI (Settings → Maintenance) |

Failures carry the exception chain's messages, types, errno values, and status
codes, so `core/errors.dart` can classify them without Python policy.

### Lifecycle

1. **Start.** `AppServices.load` calls `WorkerClient.start`, which never
   throws. The worker gets each package's runtime folder and whether to
   install a scheduled update through environment variables, selects yt-dlp
   and ytmusicapi on a background thread, and sends `ready` with a
   `WorkerStatus` holding one selection per package.
2. **Requests.** Frames sent before the worker registers its handler are
   queued and delivered in order. Python runs requests on a bounded thread
   pool; the app enforces the user's download concurrency.
3. **Failure.** The transport's `stopped` future completes when the
   interpreter fails to start (`SeriousPython.run` reports a failure or
   throws), when queued frames cannot be delivered for 30 seconds after the
   interpreter started, or when the development process exits. The client then
   fails every waiting request with a `WorkerFailure`, answers `ready` with an
   unavailable status (Settings shows it), and fails new requests immediately.
   Nothing waits forever, and the rest of the app keeps working.
4. **Process reuse (Android).** If the OS keeps the process, and so the
   interpreter, alive across a Dart VM restart, the transport does not start
   Python again. It calls `DartBridge.signalDartSession({"worker": port})`;
   the worker's restart handler serves the new port, drops replies to requests
   from the old session, cancels its downloads, and sends `ready` again.
5. **Shutdown.** CPython cannot be finalized and restarted safely in one
   process, so the interpreter lives until the process exits. On close the app
   cancels its downloads (each stops at its next progress hook) and stops
   listening.

serious_python changes the working directory to `<application support>/data`
when it starts Python. Melody uses absolute paths everywhere.

## The audio boundary

`melody_audio` exposes typed Dart APIs; the app's `NativeAudioBackend` adapts
them to the playback controller.

- `AudioEngine` is the process-scoped just_audio player. Requests (`setQueue`,
  `updateQueue`, `loadSource`, `play`, `seek`, ...) carry an even generation
  chosen by the app; it reports `AudioEngineEvent`s (`AudioLoaded`,
  `AudioPositionChanged`, `AudioTrackChanged`, ...) tagged with their
  generation. Transitions the engine makes by itself use odd generations.
- `SystemMediaSession` publishes a `MediaSessionState` to lock-screen,
  notification, and desktop controls, and routes `MediaCommand`s: the engine
  carries out transport commands itself, and only commands that need
  application policy (favorite, shuffle, repeat, leaving a stream) reach the
  app.
- `AndroidPlatform` is the Kotlin MethodChannel for the directories Melody
  needs from Android and for opening the Music folder in the Files app.

## State ownership

| State | Authority | Other participants |
| --- | --- | --- |
| Durable queue mirror, requested transport, current selection | `PlaybackController` | UI sends commands; native snapshots are persisted |
| Live queue, automatic transitions, decoder/device state | `AudioEngine` (melody_audio) | `NativeAudioBackend` forwards generation-filtered events to the controller |
| Track UUIDs, file references, hashes, playlists | `MusicManager` (`library.db`) | Services coordinate registration and deletion through `mutation` |
| Settings, track details, history, session queue, download history | `ApplicationStore` (`state.db`) | Writes commit atomically; failure restores in-memory values |
| Staged download files, cancellation, terminal outcome | `Downloader` | The worker writes only inside the staging directory it is given (and yt-dlp's cache folder, also chosen by the app) |
| Download reuse, registration, retry, receipt replay | `DownloadCoordinator` | Core does not know about the library; status changes are saved at once, byte progress never (a download active at startup is reported as interrupted) |
| Embedded cover artwork | The downloaded media container | The downloader reads it back before committing the file |
| Offline UI artwork keyed by remote URL | `ThumbnailCache` | Derived only from verified embedded bytes, cached once the track is registered; entries no library track uses are removed at launch (`LibraryService.removeUnusedCaches`) and with the last track that uses them |
| Runtime ytmusicapi and yt-dlp selection | `worker/src/melody_worker/updater/`, once per launch before import | `PackageRuntime` (one per package) schedules updates and reports status |
| Saved lyrics, keyed by media identity | `LyricsLibrary` (`lyrics/<provider>_<id>.json`) | Saved on download completion, first play, and the library pass at launch; keeps lyrics showing until they are embedded (and on mobile); tracks without lyrics are rechecked weekly |
| Lyrics embedded in downloaded audio | The media file, written in staging before artwork verification and hashing | MP3 gets a `USLT` frame from `core/id3_lyrics.dart` (FFmpeg can only write a non-standard `TXXX`); other formats get FFmpeg's tag through the worker |
| Lyrics embedded in library audio (desktop) | `LyricsEmbedder`, at launch for the whole library, after downloads, and on play | Written into a `.melody-tmp-*` copy, swapped in under the library mutation lock, then rehashed; a playing file waits until playback moves on; files that cannot take lyrics are recorded by content hash in `state.db` (`lyrics_not_embedded`) |
| `.lrc` files beside library audio | Read by `LyricsLibrary`; no longer written | Melody's old ones (marked `[re:Melody]`) are removed once the audio carries the lyrics; a user's `.lrc` is never changed; deleting or replacing the audio removes it; imports copy a `.lrc` beside the original |

Both SQLite schemas are unchanged since the first SQLite release, and fixtures
written by earlier releases are part of the test suite. Pre-SQLite
`library.mmdb` and `state.json` files are still imported once and kept with a
`.migrated` suffix.

### Playback

The controller owns durable playback intent and mirrors the engine's live
queue selection. `playing` reflects requested playback while a load is pending
and is reconciled by engine events; it is not proof that sound was emitted.

The controller always gives the complete library queue to the engine.
just_audio owns decoding, buffering, playlist transitions, and repeat;
`audio_session` configures focus and interruptions. Events from a superseded
generation are ignored, and completion is handled once per generation. Source
and transport commands are serialized separately so Pause stays responsive
while a replacement source prepares, and a load watchdog reports a decoder that
never becomes ready.

The controller must not independently advance a native completion. Queue
mutations replace or update the engine's queue atomically. Pause keeps the
media session; only Stop releases the decoder, keep-alive resources, and system
controls. On Android the launcher activity is `singleTask` and caches its
Flutter engine, so removing the task does not destroy the decoder while the
foreground media service keeps the process alive. Full process death still
loses decoder identity; the persisted queue can be restored, but automatic
continuation is not claimed. Physical-device testing is still required for
background, lock-screen, and lifecycle behavior.

Shuffle is a one-time in-place reorder of the upcoming rows (or the whole
collection when starting shuffled). Next, Previous, repeat, persistence, and
the queue view then follow that visible order. Playlist order is separately
authoritative in `MusicManager`; reordering a playlist never replaces the
active queue.

### Downloads

Coordinator reservations use canonical source keys; requests for one source
share active work. File allocation, duplicate lookup, and registration are
serialized through `MusicManager.mutation`, including local imports. The
downloader's queue is bounded by `concurrent_downloads` active plus as many
pending jobs; overload is reported per song (`WorkerQueueFull`) without
cancelling a batch. Download options (format, quality, concurrency, folder,
cookies) are fixed when the coordinator opens, so changing them applies at the
next launch; catalog requests read the cookie file on every request.

yt-dlp keeps the thumbnail sidecar in staging while metadata is written, and
the cover is burned in as the last postprocessor. Before promotion the
downloader reads the cover back from every audio file with `core/artwork.dart`
(ID3v2, MP4 `covr`, FLAC, Ogg Opus/Vorbis); advertised artwork without a
readable embedded cover fails the download. Only verified bytes reach the
thumbnail cache.

Before completed files are promoted, a checksum receipt
(`downloads/receipts/<task>.json`) records their names, hashes, folder,
source, and task.
Registration acknowledges it. At startup each receipt is resolved: files that
still match their checksums are registered, missing or changed files are left
as they are (a changed file is no longer provably the download's), and the
receipt is deleted, as is one that cannot be read. A receipt survives only
when registering its files fails, so the next launch retries. Cancellation is
cooperative and decided once: cancellation accepted before completion wins and
cleans owned outputs.

### Storage layout

`AppPaths` (`app/lib/platform/paths.dart`) is the only place that names a
location. The data folder is the same in every release (see the README), so
installs upgrade in place; inside it:

| Path | Contents | Owner |
| --- | --- | --- |
| `library.db` | Tracks, file references, hashes, playlists | `MusicManager` |
| `state.db` | Settings, history, queue, download history, small app state | `ApplicationStore` |
| `cookies.txt` | Uploaded cookies; present means yt-dlp uses them | Settings (upload/remove) |
| `music-move.json` | The files of a music folder move in progress | `MusicManager` |
| `lyrics/` | Saved lyrics, `<provider>_<id>.json` | `LyricsLibrary` |
| `downloads/staging/` | One locked `job-*` folder per running download | `Downloader` |
| `downloads/receipts/` | `<task>.json` for completed, unregistered downloads | `Downloader` writes, `DownloadCoordinator` acknowledges |
| `runtime/yt-dlp/`, `runtime/ytmusicapi/` | Runtime package updates, separate from the bundled copies | The worker's updater |
| `cache/artwork/` | Artwork copied out of downloaded files | `ThumbnailCache` |
| `cache/yt-dlp/` | yt-dlp's player and signature cache (`cachedir`) | yt-dlp; pruned by `pruneYtDlpCache` |
| `cache/notification-artwork/` | Square crops for the system media controls | melody_audio; the 64 most recently used are kept |

Rules that keep it predictable:

- **Persistent, runtime, and cache data are separate.** Everything under
  `cache/` can be deleted while Melody is closed; it is rebuilt or fetched
  again. Deleting `runtime/` falls back to the bundled packages.
- **The music folder holds audio only.** Downloads stage and keep receipts in
  `downloads/` on every platform, and only finished audio is moved to the
  music folder (copied when it is on another volume). Melody's only other
  files there are `.melody-tmp-*` copies renamed into place.
- **One temporary-file convention.** Every atomic write and copy goes through
  `temporarySibling` (`.melody-tmp-<16 hex><extension>`, the extension kept
  for Android's `Music`), and `removeStaleTemporaries` recognizes exactly
  those names (plus the Python releases' `mkstemp` names).
- **Stored paths are relative where Melody owns the folder.** Library
  filenames are relative to the music folder; receipt entries are bare names
  inside the receipt's recorded folder. Both are validated against traversal
  before use. Absolute paths remain only for the user-chosen music folder,
  imported originals, and Android tracks inside the public `Music` root.
- **Earlier layouts are upgraded in one place.** `storage_upgrade.dart` holds
  every legacy name: it moves `thumbnails/`, `yt-dlp-runtime/`,
  `ytmusicapi-runtime/`, and `yt-dlp-cache/` into the layout above before
  anything opens them, drops the `cookie_file` setting (an empty one removes
  `cookies.txt`), moves `.melody-download-*.json` receipts from the music
  folder into `downloads/receipts/`, sweeps abandoned `.melody-download-*`
  staging beside the music, and moves Android's private `Music/` tracks to
  the public music folder. Pre-SQLite `state.json` and `library.mmdb` are
  imported by their stores and kept with a `.migrated` suffix until a later
  launch has opened the databases. The old `download-staging/` folder and
  the system-temp `melody-notification-artwork/` folder are removed.

### Disk cleanup

Every file Melody generates has one owner, and each owner removes it on every
outcome and again at the next launch if the process ended first:

- **Download staging.** A job holds an exclusive lock on
  `.melody-staging.lock` inside its staging folder, and a `finally`
  deletes the folder after completion, failure, or cancellation (once more
  two seconds later if a closing FFmpeg still holds a file). Closing the
  app mid-download ends the process before that runs, so
  `DownloadCoordinator.open` calls `Downloader.removeAbandonedStaging` before
  any job starts. It deletes staging whose lock it can take: the operating
  system releases a lock when its process ends, while another running
  Melody still holds its own. Staging without a lock is deleted once nothing
  in it has changed for an hour.
- **Removed tracks.** Deleting a track, clearing the library, and a
  download that repairs or duplicates a track all remove the audio Melody
  downloaded (with its `.lrc`) through `OwnedFiles`, which records each
  path before the entry changes and retries at every launch until the file
  is gone. Imported copies are kept unless the full reset asks otherwise.
  The artwork and saved lyrics of a removed track go with its last entry,
  and at launch if anything was missed.
- **Receipts.** Acknowledged when their files are registered, deleted when
  their download fails or is cancelled, and resolved at launch otherwise. A
  receipt whose files are in an earlier music folder moves them into the
  current one first; one that can never be registered is retired, leaving
  its audio as an unregistered file that Maintenance lists.
- **Temporary files** (`.melody-tmp-*`, including the ID3 lyrics writer's)
  untouched for an hour are removed at launch from the data, lyrics,
  receipt, and artwork folders and from every folder holding library tracks
  (`removeStaleTemporaries`). Nothing else matches those names.
- **Music folder moves.** `MusicManager.moveMusicFolder` records its files
  in `music-move.json` first. If the process ends before the new folder is
  saved, the next launch moves them back to the saved folder (or, after a
  completed move, just deletes the journal).
- **Saved lyrics and cached artwork** that no library track uses (previews,
  failed downloads, removed tracks) are removed at launch
  (`LibraryService.removeUnusedCaches`) and with the last track that uses
  them. Embedder records of removed tracks are dropped at launch.
- **yt-dlp's cache** lives in `cache/yt-dlp/` instead of `~/.cache/yt-dlp`.
  At launch, entries older than 30 days are removed, and then the oldest
  until the folder is at most 64 MB (`pruneYtDlpCache`).
- **Notification artwork** keeps the 64 most recently used crops, written
  atomically; an interrupted write is removed by the next prune.
- **Runtime packages.** The worker's updater keeps the current and previous
  release of each package and removes its own interrupted downloads.
- **Databases.** History lists are capped (250 downloads, 100 plays, 20
  searches), deleted tracks take their rows with them, and a database whose
  free pages exceed a quarter of a file of 4 MB or more is compacted
  (`VACUUM`) when it opens.

Cleanup never follows names alone into user data. Unregistered audio
without a receipt, a user's `.lrc`, and imported originals are never deleted.

## Track identity and files

A library UUID is the durable identity of a saved record. Remote identity is
provider plus stable media ID (`MediaIdentity`); YouTube Music and YouTube
watch, short, live, embed, and youtu.be URLs normalize to `youtube:<id>`.
Titles and filenames never determine remote equality; local files use a
content hash.

| File class | Owner and lifecycle |
| --- | --- |
| Preview stream | Ephemeral URL; never creates a library track |
| Download staging | `Downloader`-owned, locked `downloads/staging/job-*` folder; removed after every outcome, or at the next launch once its process has ended |
| Completed, unregistered download | Its checksum receipt owns the handoff until the next launch resolves it |
| Managed library audio | `MusicManager`; desktop uses the music folder, on Android the music folder is inside public `Music` (`Music/Melody` by default); tracks earlier releases kept in private storage move there once at launch |
| Downloaded audio of a removed entry | `OwnedFiles`: recorded in `state.db` (`pending_file_deletions`) before the entry goes, then deleted with its `.lrc`; a file that cannot be deleted yet (held open, or a crash in between) is deleted at a later launch, unless an entry still uses it |
| Imported local original | The user's; Melody copies it and never deletes the original |
| Copied import, lyrics rewrite | A `.melody-tmp-*` file beside the destination; an atomic rename exposes only complete files; an abandoned one is removed at launch |
| yt-dlp cache | `cache/yt-dlp/`; disposable, pruned at launch by age and size |
| Cached artwork | `cache/artwork/`; derived from downloaded files, pruned to what library tracks use |
| Uploaded cookies | `cookies.txt`; explicit upload/remove only (restoring default settings removes it) |
| Runtime yt-dlp wheels | `runtime/yt-dlp/`, separate from the bundled yt-dlp |
| Runtime ytmusicapi wheels and their extracted copies | `runtime/ytmusicapi/`, separate from the bundled ytmusicapi |
| Saved lyrics | `lyrics/`; written atomically; removed with the last track of the same song, and at launch when no library track uses them |
| `.lrc` beside an audio file | The user's (Melody's old ones are marked `[re:Melody]` and cleaned up); removed with its audio file |

## Crash consistency

Both databases use write-ahead logging. A change writes only its rows in one
transaction; a failure rolls back and the owner restores its in-memory model.
The library's commits are flushed to durable storage; application state uses
`NORMAL`, which survives application crashes and may lose only the latest
session saves on power loss. A library commit does not wait for that flush on
the UI isolate: it runs at `NORMAL` and a background isolate flushes the log
right after it (`SqliteStore` with `syncInBackground`), so a commit becomes
power-loss durable within milliseconds of returning instead of before. If that
isolate cannot start or fails, commits fall back to `FULL`. Each database
opens with an integrity quick check. Cookies, receipts, saved lyrics, and
artwork are written to a `.melody-tmp-*` file, flushed, and renamed; a
temporary file a crash leaves behind is removed at a later launch.

The two databases are not a distributed transaction. Startup marks completed
history with missing audio as repairable, replays verified receipts, and
filters the restored queue by file availability. `LibraryService.reconcile`
(Settings → Maintenance) removes stale secondary references and lists
unregistered files without deleting them.

## Keeping the UI isolate responsive

Everything below runs on the UI isolate unless it says otherwise, so slow
work stays out of builds and event handlers:

- Network, yt-dlp, and tagging run in the Python worker; audio decoding runs
  natively.
- Hashing, file copies, artwork and lyrics tag reads, and MP3 lyrics writes
  run in `Isolate.run`. The lyrics writer keeps only the tag in memory and
  streams the audio through a fixed buffer.
- Library and state reads come from in-memory models; only writes reach
  SQLite, and library writes do not wait for the disk (see Crash
  consistency).
- `ThumbnailCache.open` lists the thumbnail folder once in a background
  isolate; afterwards artwork widgets and queue activation answer from
  memory, and the cache's own writes keep that index current.
- Startup checks many files at once with `existingFiles`, one background
  isolate for the whole batch (the resumed queue, completed downloads).
- Widgets do not touch the filesystem while building: a missing local
  artwork file shows the placeholder through the image's error path, and
  the cookie file's presence is checked when settings are opened.

Known limits: opening the two databases (an integrity quick check and loading
the library model) is synchronous during the loading view, and a SQLite
checkpoint, about once per 1000 written pages, flushes on the committing
isolate. Both are bounded by the size of the databases, not by the music.

## Remaining engineering work

- Physical-device lifecycle tests for background playback, notification
  reattachment, and interpreter reuse on Android.
- macOS bundles copy FFmpeg into `Contents/Resources/ffmpeg` after
  `flutter build`; signing and notarization must cover those executables.
- A complete locked native dependency graph per target for reproducible
  artifacts.
