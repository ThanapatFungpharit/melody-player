# `flet_background_audio`

Melody's in-repository Flet extension for playback and system media controls.
Its Python controls and Flutter implementation form one versioned bridge. The
package ships with Melody; it is not maintained as a general-purpose Flet
extension or published to Dart's package registry.

| Python service | Responsibility | Melody usage |
| --- | --- | --- |
| `ManagedAudio` | Commands and events for the process-scoped native decoder and queue | Desktop, mobile, and web |
| `BackgroundAudioSession` | Metadata and policy for the process-scoped native media session | Native platforms |
| `SharedAudioStorage` | Publish staged audio to public `Music/Melody` | Android only |

The player does not use Flet's stock Audio control. Melody's Python application
owns the durable library, saved queue, download policy, and UI presentation.
Dart owns the decoder, live queue, buffering, audio focus, current track and
position, background playback, media session, and transport. Its state survives
Flet page and service disposal while the Flutter process lives. The Flet
services are command and event bridges to that runtime. See the
repository [architecture](../../docs/architecture.md) for the full ownership
contract.

## Mounting and using the services

The root [`pyproject.toml`](../../pyproject.toml) resolves this Python package
through `tool.uv.sources` and registers its Flutter half through
`tool.flet.dev_packages`. Keep both entries when moving the package. Melody
normally mounts the services through
[`ManagedAudioBackend`](../../src/musicplayer/ui/audio_backend.py), which also
orders RPCs, ignores stale generations, and bounds operations with timeouts.
Application code should use that adapter unless it implements the same
lifecycle rules.

A direct control call looks like this once `ManagedAudio` is mounted:

```python
from flet_background_audio import ManagedAudio

audio = ManagedAudio()
page.services.append(audio)
page.update()

# Run awaited calls in a Flet-managed async task after the service is mounted.
await audio.set_queue(
    [
        {"track_id": "track-1", "source": "/music/first.mp3"},
        {"track_id": "track-2", "source": "/music/second.mp3"},
    ],
    current_index=0,
    generation=2,
    repeat_mode="off",
    autoplay=True,
)
```

The native runtime starts playback when the selected decoder is ready. Play
intent travels with source selection. Replace the paths with existing files.

## `ManagedAudio` API

`ManagedAudio` is a page-scoped `ft.Service` attached to the persistent native
runtime; `volume` defaults to `1.0`.
`load_source` accepts a local path, an HTTP(S) URL, or bytes. A queue row must
have nonempty string `track_id` and `source` keys. Queue sources are paths or
HTTP(S) URLs; Dart treats other strings as device file paths. Python rejects
malformed rows with `ValueError` before sending them to Dart.
Optional `title`, `artist`, `album`, and `artwork_uri` fields let the native
session update notification metadata when it advances the queue while Python
is suspended.
For `play(position)` and `seek(position)`, an integer is milliseconds; Flet
`Duration` values are also accepted.

| Method | Effect |
| --- | --- |
| `load_source(source, generation, autoplay=False, position_ms=0)` | Select one source and clear the live queue. Autoplay starts it when ready. |
| `set_queue(items, current_index, generation, repeat_mode, autoplay=False, position_ms=0)` | Replace the live queue and select its current row. Autoplay starts it when ready. An empty list clears the source. |
| `update_queue(items, current_index, repeat_mode)` | Change ordering and repeat policy without reloading. If the active track is removed, it continues until completion and then advances to `current_index`. An empty list leaves the current track playing until completion. |
| `play(position=0)` | Start the prepared decoder, seeking first if `position` is positive. |
| `pause()` / `resume()` | Pause or resume while retaining the source. |
| `seek(position)` | Seek the current decoder. |
| `stop()` | Stop playback, release the source, and remove native media controls. |
| `skip_next()` / `skip_previous()` | Move within the installed native queue. |
| `get_playback_state()` | Return native source, track ID, generation, metadata, position, duration, and playing state for reattachment. |
| `cancel_load()` | Invalidate pending preparation without discarding the active decoder. |
| `clear_source()` | Clear the queue and release the decoders. |

`repeat_mode` accepts `"off"`, `"track"`, or `"playlist"`. Track repeat
replays the current row on automatic completion; playlist repeat wraps after
the last row. Indices are zero-based. Dart bounds an out-of-range index, but
the caller should send its actual selection so the durable queue mirror agrees.

The caller supplies a nonnegative even `generation` for each new selection.
Native queue transitions use odd generations. Source events include it;
native transitions emit
`on_track_change`. Ignore superseded generations and mirror the new selection
before processing its timeline events. `update_queue` keeps the generation.

| Event | Fields | Meaning |
| --- | --- | --- |
| `on_loaded` | `generation` | A decoder became active; duration may arrive later. |
| `on_duration_change` | `duration`, `generation` | Duration in milliseconds. |
| `on_position_change` | `position`, `generation` | Position in milliseconds, about once per second. |
| `on_state_change` | `state`, `generation` | Native state such as `playing`, `paused`, `stopped`, or terminal `completed`. |
| `on_track_change` | `track_id`, `index`, `generation` | Native queue selected another row. |
| `on_error` | `message`, `generation` | Native background or transition failure; ignore errors from superseded generations. Direct RPC failures also raise to their caller. |

`just_audio` owns decoding, buffering, and the loaded playlist's automatic
transitions. Explicit selections and queue edits prepare a replacement player
beside the active one. A Pause intent during preparation prevents the replacement
from starting when it becomes ready. Queue edits can briefly rebuffer the active
track while its position is transferred to the replacement.

## `BackgroundAudioSession` API

Mount this companion alongside the player on platforms with a supported media
session. `sync(...)` supplies metadata and control policy to the native session.
Native decoder events update its position and playback state while Python is
suspended.
Call `deactivate()` when system controls should disappear after explicit Stop.
Pausing can retain the controls. `keep_alive=True` keeps Android's foreground
playback service attached while media remains active. Send `reattach=True`
after an activity or page reattachment to refresh metadata and action handling.

`sync` requires `title`. Optional `artist`, `album`, and `artwork_uri` describe
the current media. `auto_focal_point_live_notifications` prepares a square
artwork copy in Flutter by finding the crop that retains the most local color
and edge detail; equal-scoring crops favor the image center. This lightweight
visual-detail estimate does not recognize faces. When false, Flutter crops
around the center. The operating system still draws the media panel from the
prepared artwork. `duration_ms` and `position_ms` are
clamped to nonnegative integer milliseconds; `playing` and `loading` describe
the current state.

| Argument | Meaning |
| --- | --- |
| `has_next`, `has_previous` | Advertise skip controls; both default to `False`. |
| `repeat_mode` | `"off"`, `"track"`, or `"playlist"` for the system indicator. |
| `can_repeat`, `can_shuffle`, `can_favorite`, `favorite` | Availability and favorite state for Android notification shortcuts. |
| `notification_action_pair` | Priority for Android's two shortcut slots: `"shuffle_favorite"`, `"shuffle_repeat"`, or `"repeat_favorite"`. |
| `keep_alive`, `reattach` | Android background retention and lifecycle reattachment. |

`on_action` events contain `action` and optional `seek_position_ms`. Standard
names include `play`, `pause`, `skipToNext`, `skipToPrevious`, `seekTo`,
`rewind`, `fastForward`, and `stop`. Android shortcut names are
`shuffleUpcoming`, `cycleRepeat`, and `toggleFavorite`. The companion offers
transport actions to the native player first. It forwards an action to Python
when native playback cannot handle it or Melody policy is needed, such as a
queue-less preview or a custom shortcut. Do not expect an `on_action` event for
every media button press.

## `SharedAudioStorage` API

`await SharedAudioStorage.publish(source)` copies an existing, nonempty staged
file into Android MediaStore under public `Music/Melody` and returns the
published `Path`. Android can resolve a filename collision to a different name,
so use the returned path. The caller still owns the staged source; publishing
does not delete it. On failure the plugin attempts to remove its pending
MediaStore entry.
The Python binding intentionally fixes the subfolder to `Melody` even though
the lower-level channel accepts a relative path.

This service requires Android API 29 or later. Melody does not mount it on web.

## Platform support

| Platform | Playback | System media session | Shared storage |
| --- | --- | --- | --- |
| Android (API 29+) | Native decoder and queue | Notification and foreground service | Public `Music/Melody` |
| Windows, macOS, iOS | Native decoder and queue | `flutter_media_session` implementation | Unavailable |
| Linux | Native decoder and queue | No Linux implementation in `flutter_media_session` 3.0.3; Melody treats sync failure as nonfatal | Unavailable |
| Web | Browser decoder, including byte sources | Melody does not mount this companion | Unavailable |

Background behavior still needs release-build tests on real devices. Process
death destroys the in-memory decoder; Melody can restore its saved queue, but
automatic continuation after process death is not promised. The Android build
wrapper also configures launcher lifecycle behavior.

## Versioning and validation

The Python and Dart manifests are both `0.7.0`. Python Flet and Dart Flet are
pinned to `0.86.5`; Dart pins `just_audio` to `0.10.6`, `audio_session` to
`0.2.4`, `just_audio_media_kit` to `2.1.0`, and `flutter_media_session` to
`3.0.3`. Windows and Linux use the pinned `media_kit` native libraries. A bridge protocol change requires matching
Python and Dart changes, a shared version bump, an updated Melody dependency
and lock, and platform validation. The bridge version differs from Melody's
application version. See the [release and dependency
policy](../../docs/releases-and-dependencies.md).

From the repository root:

```text
uv run --locked --python 3.14 --group build python -m unittest discover -s tests -t .
uv run --locked --python 3.14 --group build ruff check src tests tools packages/flet_background_audio/src/flet_background_audio
uv run --locked --python 3.14 --group build ty check src tests tools
uv run --locked --python 3.14 --group build python tools/build_desktop.py windows
```

From `packages/flet_background_audio/src/flutter/flet_background_audio`, run
`flutter analyze` and `dart format --output=none --set-exit-if-changed lib`.
Use the repository's `tools/build_android.py` for Android release builds; it
requires release signing configuration. Headless tests and desktop compilation
cannot replace device checks for audio focus, notification actions, background
playback, and activity reattachment.
