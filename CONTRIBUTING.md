# Contributing to Melody

Start with [architecture and invariants](docs/architecture.md) and
[release/dependency policy](docs/releases-and-dependencies.md). Preserve named
capabilities and state owners; file or line-count reduction alone is not an
architectural improvement. Python is reserved for the worker that hosts
ytmusicapi and yt-dlp: anything that does not need one of them belongs in Dart.

## Local validation

```console
uv sync --locked
uv run melody-check                # every check CI runs; --list shows the commands
uv run melody-integration          # network tests against YouTube Music
```

`melody-check` formats, lints, type-checks (ruff and ty for Python), and
tests; CI runs exactly these steps. It takes components (`audio`, `app`,
`worker`, `tools`), `--no-tests`, `--fix`, and `--fail-fast`. To poke at the
worker directly, use `uv run melody-worker` (for example
`melody-worker search "query"` or `melody-worker ytmusic get_lyrics
browseId=...`); to try a change in the real app, `uv run melody-run`.

Tooling lives in `tools/build/` (release artifacts), `tools/dev/` (running from
source), and `tools/checks/` (validation), with shared helpers in
`tools/common.py` and tests in `tools/tests/`. Register a new tool under
`[project.scripts]` in the root `pyproject.toml` and run `uv sync`.

- `app/test/core` covers storage, the library manager, embedded artwork, and
  loudness measurement (real FFmpeg runs when `MELODY_FFMPEG_DIR` is set or
  FFmpeg is staged under `app/media/`; otherwise those tests are skipped).
  The data-compatibility fixtures were written by earlier releases; never
  regenerate them with the current code.
- `app/test/application` covers downloads (with a fake worker transport),
  the catalog, lyrics (saved, embedded, `.lrc`, LRC parsing), playback, the
  queue, loudness normalization (with a fake meter), the application store, and scheduled package updates. `app/test/core` covers reading artwork and lyrics from every
  container and writing MP3 lyrics.
- `app/test/worker` covers the worker client's typed status and its behavior
  when Python stops or never starts.
- `app/test/ui/screens_test.dart` renders every screen of both presentations.
- `app/test/integration` talks to YouTube Music through the real worker and runs
  only when `MELODY_WORKER_PYTHON` is set (`melody-integration worker`).
- `app/integration_test` drives the real desktop app (lyrics while playing,
  lyrics inside the downloaded file, offline, imported files); its header
  lists the environment it needs, including a throwaway `MELODY_DATA_DIR`
  (`melody-integration app` provides it).
- `tools/tests` covers the build, development, and check tools, including the
  worker console against a fake worker.
- `packages/melody_audio/test` covers the audio engine, the media session, and
  notification artwork.
- `worker/tests` covers the request loop, app-session restarts, the bridge
  transport, and the runtime updater.

New Python boundary operations belong in `WorkerClient` with typed results;
UI and application code never build frames or touch serious_python.

Tests must not use the user's library, live cookies, or (outside
`app/test/integration` and `app/integration_test`) the network. When running
the app from source, use `melody-run` or set `MELODY_DATA_DIR` so it never
opens your real data.

For stateful changes, test failure boundaries: persistence failing after bytes
are written, a callback from an obsolete decoder generation, simultaneous
commands, cancellation just before completion, and restart with an interrupted
receipt. Include native-device checks for background audio changes; headless
tests cannot validate OS audio focus, process recreation, or lock-screen
controls.

## Licensing status

No project license has been selected in this checkout. This documentation does
not grant new modification or redistribution permissions. The maintainer must
choose a license for Melody and its local plugin before presenting the project
as licensed open source. Third-party components retain their own licenses.
