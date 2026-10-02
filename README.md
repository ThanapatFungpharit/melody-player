# Melody

Melody is a cross-platform music player and downloader. The application is a
Flutter app written in Dart; Python is embedded only to run
[`yt-dlp`](https://github.com/yt-dlp/yt-dlp), which has no Dart equivalent. It
provides one continuous workflow for searching, previewing, downloading,
organizing, queueing, and playing music, with dedicated desktop and mobile
interfaces for the same shared capabilities.

## What is implemented

- Paged YouTube Music song search with track-list and artwork-grid views; pasted playlist URLs load their tracks with playlist-aware pagination
- Optional manually uploaded cookie-file sessions for personalized YouTube Music search, signed-in playlists, stream previews, and downloads
- Stream previews directly from Search
- Individual, multi-URL batch, and YouTube Music playlist downloads with concurrent workers, per-song progress, cancel, retry, isolated failure details, persistent history, and cover artwork embedded in every downloaded media file plus a derived offline UI cache
- Search actions have one clear intent: Play reuses the intact library file or downloads it and starts playback when ready; Download stores it without playing. Both reuse an existing file or join an in-flight request instead of creating another copy.
- Automatic import of completed audio into the SQLite music library
- Native multi-file import for MP3, M4A, Opus, WAV, FLAC, OGG, and AAC, with content-hash duplicate detection
- Persistent playlists with duplicate-aware YouTube Music playlist import, bulk multi-select track adding, ordered tracks, desktop drag-to-reorder, touch move-up/down actions, rename/delete, copy/move, and safe removal that does not delete audio files
- Searchable/sortable track library, favorites, title editing, explicit uploader/channel credits, duplicate-by-source detection, and integrity-aware file paths
- Persistent playback queue with play-next, append, reorder, remove, clear-upcoming, a visible one-time shuffle reorder, repeat-track, and repeat-queue
- Background playback while Melody is minimized, another app is active, or a mobile device is locked
- Lock-screen, notification-panel, Control Center, and desktop system-media controls with synchronized artwork, title, artist, playback state, seeking, and previous/next actions; Pause keeps the session available and explicit Stop removes it
- Desktop seek, precise volume, media keys, and keyboard shortcuts; mobile touch controls with mute/restore while the device provides media volume buttons
- Separate desktop (navigation rail, docked queue, hover states, menus, drag-to-reorder) and mobile (bottom navigation, full-screen panels, touch targets, bottom-sheet menus) presentations
- Recent tracks, playback/search history, session queue state, light/dark/system themes, accent palettes, and YouTube Music/download settings

## Layout

| Path | Contents |
| --- | --- |
| `app/` | The Flutter application: UI, SQLite stores, library, queue, playback, downloads, artwork verification |
| `packages/melody_audio/` | Flutter plugin: process-scoped `just_audio` engine, system media session, notification artwork, Android MediaStore bridge |
| `worker/` | The embedded Python worker: runs yt-dlp and selects/updates its runtime wheel |
| `tools/` | Build and release scripts (FFmpeg fetching, worker packaging, `flutter build`) |

See [Architecture and invariants](docs/architecture.md) for state owners and
contracts, [Contributing](CONTRIBUTING.md) for tests, and
[Release and dependency policy](docs/releases-and-dependencies.md) for versions
and runtime yt-dlp updates.

## Run from source

Requirements: Flutter 3.44.8, [uv](https://docs.astral.sh/uv/), and on Windows
Visual Studio with the C++ desktop workload.

During development the worker can run in a normal Python interpreter instead of
the embedded one. Point the app at it, and at a throwaway data folder so your
real library and music folder are never touched:

```console
cd worker && uv sync && cd ..
python tools/fetch_media_binaries.py windows x86_64
cd app
set MELODY_WORKER_PYTHON=..\worker\.venv\Scripts\python.exe
set MELODY_FFMPEG_DIR=media\windows\x86_64
set MELODY_DATA_DIR=%TEMP%\melody-dev
flutter run -d windows
```

| Variable | Effect |
| --- | --- |
| `MELODY_WORKER_PYTHON` | Run the worker in this interpreter over stdio instead of the embedded runtime |
| `MELODY_WORKER_SOURCE` | Worker source folder (defaults to `../worker/src`) |
| `MELODY_FFMPEG_DIR` | Folder containing `ffmpeg` and `ffprobe` |
| `MELODY_DATA_DIR` | Keep all state and the default music folder in this directory |

Application state uses the same per-user locations as earlier releases, so an
installed Melody upgrades in place with its library, playlists, and settings:

- Windows: `%LOCALAPPDATA%\MelodyPlayer`
- Linux: `$XDG_DATA_HOME/MelodyPlayer`, falling back to `~/.local/share/MelodyPlayer`
- macOS: `~/Library/Application Support/MelodyPlayer`
- Android and iOS: the app's application-support directory (`…/data`)

Downloaded audio defaults to `~/Music/Melody` on desktop. On Android, downloads
are prepared in recoverable private staging and then published through
MediaStore to the public `Music/Melody` folder without broad storage permission.

YouTube Music access is anonymous by default. To use a signed-in session, export
a UTF-8 Netscape-format `cookies.txt` file and upload it in Settings. Melody
validates it and copies it to private application storage; it never reads
browser cookie databases. Cookie files contain session credentials and should
not be shared.

Melody ships a release-tested yt-dlp and never modifies it. Settings →
Maintenance checks PyPI for a newer compatible release and schedules it; the
next launch downloads, verifies, and activates it before yt-dlp is imported, and
keeps the working version if anything fails. Maintenance also offers **Clean up
library**, which removes references to deleted tracks and lists stray audio
files without deleting anything.

## Test

```console
cd packages/melody_audio && flutter test
cd app && flutter analyze && flutter test
cd worker && uv run pytest
uv run pytest            # build tools
```

`app/test/ui/screens_test.dart` renders every page and panel of both shells and
fails on any layout or framework error. With `MELODY_SCREENSHOTS=1` and
`--update-goldens` it also writes PNGs to `app/test/ui/screenshots/` for review.

`app/test/integration` exercises the real worker against YouTube Music (search
and a full download with artwork verification). It needs network access and
runs only when `MELODY_WORKER_PYTHON` (and `MELODY_FFMPEG_DIR` for downloads)
are set.

## Build

`tools/build_app.py` fetches and verifies FFmpeg for the target, packages the
worker and its pinned requirements with
[serious_python](https://pub.dev/packages/serious_python), and runs
`flutter build` with the version from `app/pubspec.yaml`:

```console
uv sync --locked --no-dev
uv run python tools/build_app.py windows --architecture x86_64
uv run python tools/build_app.py linux --architecture x86_64
uv run python tools/build_app.py macos --architecture arm64
uv run python tools/build_app.py apk
uv run python tools/build_app.py aab
```

Outputs are collected in `build/<target>`. Run each desktop build on its own
operating system. Arguments after `--` go to `flutter build`.

Android 10 and newer cannot execute programs from writable storage, so FFmpeg
ships as `libffmpeg.so`/`libffprobe.so` native libraries that the installer
extracts to the read-only native-library directory. The launcher activity is
`singleTask` and keeps its Flutter engine cached, so the media notification
reconnects to the same decoder after the task is removed. Android builds need
release signing through `MELODY_ANDROID_KEY_STORE`,
`MELODY_ANDROID_KEY_STORE_PASSWORD`, `MELODY_ANDROID_KEY_PASSWORD`, and
`MELODY_ANDROID_KEY_ALIAS`, or the four `ANDROID_KEY_*` values written to `.env`
by `generate-android-key.ps1`. `--allow-debug-signing` is for local testing only.

The **Application builds** workflow builds Windows, Linux, Intel and Apple
Silicon macOS, Android APKs, and the Android App Bundle on tagged releases.

## License status

A project license has not yet been selected. See [Contributing](CONTRIBUTING.md#licensing-status); this repository currently contains no new license grant for Melody or its local plugin.
