# Contributing to Melody

Start with [architecture and invariants](docs/architecture.md) and
[release/dependency policy](docs/releases-and-dependencies.md). Preserve named
capabilities and state owners; file or line-count reduction alone is not an
architectural improvement. Python is reserved for the yt-dlp worker: anything
that does not need yt-dlp belongs in Dart.

## Local validation

```console
cd packages/melody_audio && flutter pub get && flutter analyze && flutter test
cd app && flutter pub get && flutter analyze && flutter test
cd worker && uv sync --locked && uv run ruff check src tests && uv run ruff format --check src tests && uv run pytest
uv sync --locked && uv run ruff check tools && uv run pytest
```

- `app/test/core` covers storage, the library manager, and embedded artwork.
  The data-compatibility fixtures were written by the previous Python stores;
  never regenerate them with the Dart code.
- `app/test/application` covers downloads (with a fake worker transport),
  playback, and the queue.
- `app/test/ui/screens_test.dart` renders every screen of both presentations.
- `app/test/integration` talks to YouTube Music through the real worker and runs
  only when `MELODY_WORKER_PYTHON` is set.
- `worker/tests` covers the request loop and the runtime updater.

Tests must not use the user's library, live cookies, or (outside
`app/test/integration`) the network. When running the app from source, set
`MELODY_DATA_DIR` so it never opens your real data.

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
