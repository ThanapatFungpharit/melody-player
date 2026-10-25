# Melody

Melody is a cross-platform music player and downloader. The application is a
Flutter app written in Dart; Python is embedded only to run two libraries with
no Dart equivalent: [`ytmusicapi`](https://github.com/sigma67/ytmusicapi),
which finds songs, radio mixes, playlists, and lyrics on YouTube Music, and
[`yt-dlp`](https://github.com/yt-dlp/yt-dlp), which downloads them. It
provides one continuous workflow for searching, previewing, downloading,
organizing, queueing, and playing music, with dedicated desktop and mobile
interfaces for the same shared capabilities.

## What is implemented

- Paged YouTube Music song search (YouTube Music's own song results, with artists, album artwork, and durations) with track-list and artwork-grid views; pasted playlist URLs load their tracks with playlist-aware pagination
- Lyrics, timed when available: the current line follows playback and tapping a line seeks to it. Lyrics download with each track and are saved inside its audio file (a standard `USLT` frame in MP3, `©lyr` in M4A, `LYRICS` in FLAC/Ogg/Opus), not in a separate file, so other players see them too. On desktop, tracks already in the library get their lyrics embedded automatically in the background. Imported files show lyrics from their own tags or a `.lrc` with the same name; everything works offline
- Optional manually uploaded cookie-file sessions for stream previews and downloads that need a signed-in session
- Stream previews directly from Search
- Individual, multi-URL batch, and YouTube Music playlist downloads with concurrent workers, per-song progress, cancel, retry, isolated failure details, persistent history, and cover artwork embedded in every downloaded media file plus a derived offline UI cache
- Search actions have one clear intent: Play reuses the intact library file or downloads it and starts playback when ready; Download stores it without playing. Both reuse an existing file or join an in-flight request instead of creating another copy.
- Automatic import of completed audio into the SQLite music library
- Native multi-file import for MP3, M4A, Opus, WAV, FLAC, OGG, and AAC, with content-hash duplicate detection
- Persistent playlists with duplicate-aware YouTube Music playlist import, bulk multi-select track adding, ordered tracks, desktop drag-to-reorder, touch move-up/down actions, rename/delete, copy/move, and safe removal that does not delete audio files
- Searchable/sortable track library, favorites, title editing, explicit uploader/channel credits, duplicate-by-source detection, and integrity-aware file paths
- Persistent playback queue with play-next, append, reorder, remove and clear-upcoming (both undoable), a visible one-time shuffle reorder, repeat-track, and repeat-queue
- Sleep timer that pauses playback after 15–90 minutes or when the playing track ends
- Background playback while Melody is minimized, another app is active, or a mobile device is locked
- Android lock-screen and notification-panel controls, plus Windows and macOS system-media controls (not on Linux), with synchronized artwork, title, artist, playback state, seeking, and previous/next actions; Pause keeps the session available and explicit Stop removes it
- Desktop seek, precise volume, media keys, and keyboard shortcuts for playback, volume, seeking, and navigation (Ctrl+/ lists them); mobile touch controls with mute/restore while the device provides media volume buttons
- Separate desktop (navigation rail, docked queue, hover states, menus, drag-to-reorder) and mobile (bottom navigation, full-screen panels, touch targets, bottom-sheet menus) presentations
- Recent tracks, playback/search history, session queue state, light/dark/system themes, accent palettes, and YouTube Music/download settings

## Layout

| Path | Contents |
| --- | --- |
| `app/lib/ui/` | Flutter UI: desktop and mobile shells and pages, shared widgets, feature controllers |
| `app/lib/application/`, `app/lib/core/` | Dart application and domain logic: stores, library, queue, playback, catalog, downloads, artwork verification |
| `app/lib/worker/` | The only Dart code that talks to Python: the serious_python FFI transport and a typed client |
| `app/lib/audio/`, `app/lib/platform/` | Adapter onto the audio plugin; per-platform paths |
| `packages/melody_audio/` | Flutter plugin: process-scoped `just_audio` engine, system media session, notification artwork, Android folders (Kotlin) |
| `worker/` | The embedded Python worker: runs ytmusicapi and yt-dlp and selects/updates their runtime wheels |
| `tools/` | uv-registered tooling: `build/` (FFmpeg, worker packaging, `flutter build`, versions, signing key), `dev/` (run from source, worker console), `checks/` (all test suites) |

Some features depend on the operating system; see
[Platform support and limitations](docs/platform-support.md) for what each
platform has and which settings are disabled where.

See [Architecture and invariants](docs/architecture.md) for the boundaries,
state owners, and the Python lifecycle, [Contributing](CONTRIBUTING.md) for
tests, and [Release and dependency policy](docs/releases-and-dependencies.md)
for versions and runtime ytmusicapi/yt-dlp updates.

## Run from source

Requirements: Flutter 3.47.7, [uv](https://docs.astral.sh/uv/), and on Windows
Visual Studio with the C++ desktop workload.

During development the worker runs in a normal Python interpreter instead of
the embedded one, and the app keeps its state in a throwaway folder so your
real library and music folder are never touched. `melody-run` sets that up and
starts the app on this desktop:

```console
uv sync
uv run melody-run            # state in build/dev-data
uv run melody-run --fresh    # start from an empty data folder
uv run melody-run --layout mobile                  # the phone UI in a phone-sized window
uv run melody-run --layout mobile --size tablet    # ...or another device: small-phone, phone-landscape
uv run melody-run --size narrow-desktop            # the desktop UI at another window size (or WxH)
```

The development tools are registered with uv in the root `pyproject.toml`; run
any of them with `uv run <name> --help` for details:

| Command | Folder | Purpose |
| --- | --- | --- |
| `melody-run` | `tools/dev/` | Run the app from source with the dev worker, FFmpeg, and an isolated data folder |
| `melody-env` | `tools/dev/` | Print those variables for your shell (`uv run melody-env \| Invoke-Expression`, or `eval "$(uv run melody-env --shell bash)"`) for IDE launches and manual `flutter` commands |
| `melody-worker` | `tools/dev/` | Talk to the real worker from a terminal: `status`, `search`, any whitelisted `ytmusic` method, `extract`, or a raw frame |
| `melody-check` | `tools/checks/` | Every format, lint, and test suite that CI runs, with a summary |
| `melody-integration` | `tools/checks/` | The network integration tests, with their environment |
| `melody-build` | `tools/build/` | Release builds (see [Build](#build)) |
| `melody-fetch-media` | `tools/build/` | Download and verify FFmpeg bundles |
| `melody-version` | `tools/build/` | Print and validate the release version |
| `melody-android-key` | `tools/build/` | Create an Android release keystore |

The app icon is the in-app `BrandMark` in the saved accent color. Android
switches between per-accent launcher entries (`icon.<accent>` aliases in the
manifest) once Melody leaves the screen; desktop builds draw it for the window,
taskbar, or Dock at run time, while shortcuts and the bundle keep the violet
icon. `tools/build/icons.py` renders the bundled icons from
`tools/build/icon_accents.json` with the Flutter SDK's Material Icons font;
after changing `BrandMark` or the accents, regenerate them with
`uv run python -m tools.build.icons` (`app/test/ui/app_icon_test.dart`
fails until the table matches the theme).

Flutter tools are found on `PATH`, or in `$FLUTTER_ROOT/bin`. Every tool loads
local settings such as `FLUTTER_ROOT` and `JAVA_HOME` from `.env` in the
repository root (copy [.env.example](.env.example)); variables exported in your
shell take precedence. The variables `melody-run` and `melody-env` set:

| Variable | Effect |
| --- | --- |
| `MELODY_WORKER_PYTHON` | Run the worker in this interpreter over stdio instead of the embedded runtime |
| `MELODY_WORKER_SOURCE` | Worker source folder (defaults to `../worker/src`) |
| `MELODY_FFMPEG_DIR` | Folder containing `ffmpeg` and `ffprobe` |
| `MELODY_DATA_DIR` | Keep all state and the default music folder in this directory |
| `MELODY_LAYOUT` | `mobile` or `desktop`: show that UI on any platform (`--layout`) |
| `MELODY_WINDOW_SIZE` | Initial desktop window size as `WIDTHxHEIGHT` in logical pixels (`--size`) |

Application state uses the same per-user locations as earlier releases, so an
installed Melody upgrades in place with its library, playlists, and settings:

- Windows: `%LOCALAPPDATA%\MelodyPlayer`
- Linux: `$XDG_DATA_HOME/MelodyPlayer`, falling back to `~/.local/share/MelodyPlayer`
- macOS: `~/Library/Application Support/MelodyPlayer`
- Android: the app's application-support directory (`…/data`)

Downloaded audio defaults to `~/Music/Melody` on desktop. On Android (11 or newer),
downloads are saved straight to the public `Music/Melody` folder, or another
folder inside `Music` chosen in Settings, without any storage permission. The
music folder only ever receives finished audio: each download stages in the app
data folder (partial streams, thumbnails, receipts), and that staging is
removed when the download ends. On desktop, Settings shows the app data folder
with buttons to open it or copy its path. Its `cache` folder is safe to delete
while Melody is closed.

YouTube Music access is anonymous by default. To use a signed-in session, export
a UTF-8 Netscape-format `cookies.txt` file and upload it in Settings. Melody
validates it and copies it to private application storage; it never reads
browser cookie databases. Cookie files contain session credentials and should
not be shared.

Melody ships release-tested ytmusicapi and yt-dlp and never modifies them.
Settings → Maintenance checks PyPI for a newer compatible release of each and
schedules it; the next launch downloads, verifies, and activates it before the
package is imported, and keeps the working version if anything fails. YouTube
Music changes its private API often, so updating ytmusicapi is the first step
when search, recommendations, or lyrics stop working. Maintenance also offers **Clean up
library**, which removes references to deleted tracks and lists stray audio
files without deleting anything.

## Test

```console
uv run melody-check                    # all of it, as CI runs it
uv run melody-check app worker         # components: audio, app, worker, tools
uv run melody-check --no-tests         # format, lint, and analyze only
uv run melody-check --fix              # apply formatting and safe lint fixes
uv run melody-check --list             # show the commands without running them
```

`app/test/ui/screens_test.dart` renders every page and panel of both shells and
fails on any layout or framework error. With `MELODY_SCREENSHOTS=1` and
`--update-goldens` it also writes PNGs to `app/test/ui/screenshots/` for review.

The network integration tests need YouTube Music and are skipped by
`melody-check`. `melody-integration` runs them with the worker's interpreter,
FFmpeg, and (for the app suite) a temporary data folder:

```console
uv run melody-integration              # both suites
uv run melody-integration worker       # app/test/integration: search, downloads, lyrics
uv run melody-integration app --screenshots build/screens   # the real desktop app
```

## Build

`melody-build` (`tools/build/app.py`) fetches and verifies FFmpeg for the
target, packages the worker and its pinned requirements with
[serious_python](https://pub.dev/packages/serious_python), and runs
`flutter build` with the version from `app/pubspec.yaml`:

```console
uv sync --locked --no-dev
uv run melody-build windows --architecture x86_64
uv run melody-build linux --architecture x86_64
uv run melody-build macos --architecture arm64
uv run melody-build apk
uv run melody-build aab
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
`MELODY_ANDROID_KEY_ALIAS`, or the four `ANDROID_KEY_*` values written to
`.signing` by `uv run melody-android-key` (requires a JDK's `keytool`).
`.signing` is git-ignored and read only by the Android signing step; never
commit it. `--allow-debug-signing` is for local testing only.

The **Application builds** workflow builds Windows, Linux, Intel and Apple
Silicon macOS, Android APKs, and the Android App Bundle on tagged releases.

## License status

A project license has not yet been selected. See [Contributing](CONTRIBUTING.md#licensing-status); this repository currently contains no new license grant for Melody or its local plugin.
