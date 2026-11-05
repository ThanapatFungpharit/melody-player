# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Melody is a cross-platform music player and downloader: a Flutter app, with embedded Python used only to host ytmusicapi and yt-dlp. Read `docs/architecture.md` before changing state ownership, playback, downloads, or storage; it records invariants the code alone doesn't explain. `docs/platform-support.md` says what each OS supports, and `docs/releases-and-dependencies.md` covers versions and pins.

## Commands

Requires Flutter 3.47.7 and uv (Python 3.14). Flutter is found on `PATH` or in `$FLUTTER_ROOT/bin`; tools read local settings from a root `.env` (see `.env.example`).

```console
uv sync --locked
uv run melody-check                  # every format, lint, type, and test step CI runs
uv run melody-check app worker       # components: audio, app, worker, tools
uv run melody-check --no-tests       # format, lint, and analyze only
uv run melody-check --fix            # apply formatting and safe lint fixes
uv run melody-check --list           # show the underlying commands

uv run melody-integration            # network tests against YouTube Music (not in melody-check)
uv run melody-run                    # run the app from source with isolated data in build/dev-data
uv run melody-run --layout mobile    # phone UI in a phone-sized window (also --fresh, --size)
uv run melody-worker search "query"  # talk to the real worker from a terminal
uv run melody-build <windows|linux|macos|apk|aab>   # release build, into build/<target>
```

There are four separate projects, so run a single test from the right directory:

```console
cd app && flutter test test/application/queue_test.dart --name "shuffle"
cd packages/melody_audio && flutter test test/audio_engine_test.dart
cd worker && uv run --locked pytest tests/test_updater.py -k name
uv run --locked pytest tools/tests/test_check.py        # from the repo root
```

New tools go in `[project.scripts]` in the root `pyproject.toml`, followed by `uv sync`. After changing `BrandMark` or the default accent, regenerate icons with `uv run python -m tools.build.icons`; `app/test/ui/app_icon_test.dart` fails until they match.

## Architecture

The dependency direction is `ui/` → `application/` → `core/`, in `app/lib/`. `services.dart` composes everything into `AppServices`; `ui/app_state.dart` (`MelodyApp`) is the UI's root state.

Boundaries to keep:

- `core/` never imports `application/` or UI, and `application/` never imports UI.
- `ui/desktop/` and `ui/mobile/` never import each other. Both presentations use `ui/controllers/` and `ui/shared/`, so a feature usually needs both shells updated.
- Only `app/lib/worker/` talks to Python, and only `app/lib/audio/` talks to the `melody_audio` plugin.
- `AppPaths` (`platform/paths.dart`) is the only place that names a location.

**Python boundary.** Anything that doesn't need ytmusicapi or yt-dlp belongs in Dart. The worker (`worker/src/melody_worker/`) holds no application policy: option building, result mapping, and failure classification (`core/errors.dart`) are all Dart. New operations go in `WorkerClient` with typed results; UI and application code never build frames or touch serious_python. Production uses `BridgeTransport` (FFI to the embedded interpreter), while development and integration tests use `ProcessTransport` (stdio, enabled by `MELODY_WORKER_PYTHON`).

**Playback.** `PlaybackController` owns durable intent and `AudioEngine` (in `packages/melody_audio`) owns the live queue and automatic transitions. The controller must not advance a native completion itself. Engine events carry a generation (the app's requests use even numbers, the engine's own transitions odd) and events from a superseded generation are ignored. The decoder holds only the playing row and a small window after it, and a queue edit never replaces the decoder or touches the playing row.

**Downloads.** A flow runs `DownloadCoordinator` (reuse, retry, resume, registration) → `Downloader` (staging, cancellation) → worker. Each song stages in `downloads/staging/job-<song>`; only finished audio reaches the music folder. File allocation, duplicate lookup, and registration are serialized through `MusicManager.mutation`.

**State.** `library.db` is shared by `MusicManager` (tracks, playlists; `FULL` durability) and `ApplicationStore` (settings, history, queue; `NORMAL`), each on its own connection. A change is one transaction; if it fails, it rolls back and the owner restores its in-memory model.

**Identity.** A library UUID identifies a saved record; remote identity is `MediaIdentity` (`youtube:<id>`), and local files use a content hash. Titles and filenames never determine equality. `MusicSource` changes only where music is found and fetched, never what a stored track is.

## Rules that are easy to break

- **Don't change the application ID** `com.flet.musicplayer` or the signing key, even though the name looks like a leftover. It's kept so installs upgrade in place and keep their data.
- **Don't regenerate the data-compatibility fixtures** (`app/test/fixtures/data/`) with current code. Earlier releases wrote them, and that's what they test.
- **Keep the UI isolate responsive.** Widgets don't touch the filesystem while building; hashing, file copies, and tag reads run in `Isolate.run`.
- **Atomic writes go through `temporarySibling`** (`.melody-tmp-*`), the only names `removeStaleTemporaries` recognizes. Every generated file has one owner that removes it on every outcome and again at next launch. Cleanup never deletes unregistered audio, a user's `.lrc`, or imported originals.
- **Tests must not use the user's library, live cookies, or the network**, except `app/test/integration` and `app/integration_test`, which are tagged `network`. Never run the app against real data: use `melody-run` or set `MELODY_DATA_DIR`.
- **Test failure boundaries in stateful changes:** persistence failing after bytes are written, a callback from an obsolete decoder generation, simultaneous commands, cancellation just before completion, and restart with an interrupted download.
- **Headless tests can't validate** audio focus, process recreation, or lock-screen controls, so those changes need a physical-device check. Say so rather than claiming they're verified.
- **Releases:** `version:` in `app/pubspec.yaml` is authoritative. The build number must equal `major*1000000 + minor*1000 + patch`, the tag must be exactly `v<version>`, and `melody-version` enforces both. Commit `pubspec.lock` and `uv.lock` changes, including `worker/uv.lock`, which pins what ships.

Commits use Conventional Commit prefixes with an optional scope, such as `fix(android): ...` or `feat(search): ...`, and a plain-language summary of the behavior.
