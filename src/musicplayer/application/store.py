from __future__ import annotations

import json
import threading
import time
from collections import deque
from collections.abc import Collection, Iterable
from copy import deepcopy
from itertools import chain, islice
from pathlib import Path
from typing import Any

from musicplayer.core.storage import atomic_write

from .models import AppSettings, DownloadRecord, TrackDetails

_MISSING = object()


class ApplicationStore:
    """Thread-safe JSON persistence for state outside MusicManager's domain.

    MusicManager continues to own tracks and playlists. This store contains UI
    preferences, playback/session state, enriched metadata, favorites, history,
    and durable download history.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._data = self._load()
        # Pending play batches may arrive after a track is removed. Keep their
        # IDs for this process lifetime so those writes cannot recreate it.
        self._deleted_track_ids: set[str] = set()

    def _load(self) -> dict[str, Any]:
        try:
            contents = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return self._defaults()
        except OSError as error:
            raise ValueError(f"Could not read application settings: {error}") from error
        if not contents:
            return self._defaults()
        try:
            raw = json.loads(contents)
        except json.JSONDecodeError as error:
            raise ValueError(f"Could not read application settings: {error}") from error
        if not isinstance(raw, dict):
            raise TypeError("Application settings must contain a JSON object")
        merged = self._defaults()
        merged.update(raw)
        return self._migrate(merged)

    @staticmethod
    def _migrate(data: dict[str, Any]) -> dict[str, Any]:
        if int(data.get("version", 1)) < 2:
            for details in data.get("track_details", {}).values():
                if not isinstance(details, dict):
                    continue
                if "uploader" not in details and "artist" in details:
                    details["uploader"] = details["artist"]
                details.pop("artist", None)
                details.pop("album", None)
            for record in data.get("downloads", []):
                if not isinstance(record, dict):
                    continue
                if "uploader" not in record and "artist" in record:
                    record["uploader"] = record["artist"]
                record.pop("artist", None)
            data["version"] = 2
        if int(data.get("version", 1)) < 3:
            settings = data.get("settings")
            if isinstance(settings, dict):
                # Browser database extraction was removed in version 3. A user
                # must explicitly upload a cookie file before authenticated
                # yt-dlp requests are enabled again.
                settings.pop("use_browser_cookies", None)
                settings.pop("cookie_browser", None)
                settings.pop("cookie_profile", None)
                settings.setdefault("cookie_file", "")
            data["version"] = 3
        playback = data.get("playback")
        if isinstance(playback, dict):
            playback.pop("shuffle", None)
        return data

    @staticmethod
    def _defaults() -> dict[str, Any]:
        return {
            "version": 3,
            "settings": AppSettings().to_dict(),
            "track_details": {},
            "recent_tracks": [],
            "playback_history": [],
            "search_history": [],
            "downloads": [],
            "playback": {
                "queue": [],
                "current_index": -1,
                "position_ms": 0,
                "repeat": "off",
            },
        }

    @property
    def settings(self) -> AppSettings:
        # from_dict constructs a new settings object and only reads the
        # stored primitives, so copying the mapping first is redundant.
        return AppSettings.from_dict(self._data["settings"])

    def save_settings(self, settings: AppSettings) -> None:
        with self._lock:
            self._commit_locked({"settings": settings.to_dict()})

    def track_details(self, track_id: str) -> TrackDetails:
        raw = self._data["track_details"].get(str(track_id), {})
        # TrackDetails owns the values it receives; no mutable value is
        # shared with the store by this conversion.
        return TrackDetails.from_dict(raw)

    def track_details_many(self, track_ids: Iterable[str]) -> dict[str, TrackDetails]:
        """Materialize one metadata snapshot for a multi-row UI render."""
        raw_details = self._data["track_details"]
        return {
            key: TrackDetails.from_dict(raw_details.get(key, {}))
            for track_id in track_ids
            if (key := str(track_id))
        }

    def has_track_details(self, track_id: str) -> bool:
        return track_id in self._data["track_details"]

    def favorite_track_ids(self) -> frozenset[str]:
        """Return favorite identifiers with one lock acquisition and no aliases."""
        return frozenset(
            str(track_id)
            for track_id, details in self._data["track_details"].items()
            if isinstance(details, dict) and bool(details.get("favorite"))
        )

    def save_track_details(self, track_id: str, details: TrackDetails) -> None:
        with self._lock:
            key = str(track_id)
            self._commit_locked({}, track_details={key: details.to_dict()})
            self._deleted_track_ids.discard(key)

    def remove_track_details(self, track_id: str) -> None:
        with self._lock:
            key = str(track_id)
            histories = {
                name: [item for item in self._data.get(name, []) if item != key]
                for name in ("recent_tracks", "playback_history")
            }
            self._commit_locked(histories, track_details={key: _MISSING})
            self._deleted_track_ids.add(key)

    def clear_library_data(self) -> None:
        """Clear state that refers to library tracks, preserving other app data."""
        with self._lock:
            removed_ids = set(self._data["track_details"])
            removed_ids.update(self._data.get("recent_tracks", []))
            removed_ids.update(self._data.get("playback_history", []))
            playback = self._data.get("playback", {})
            if isinstance(playback, dict):
                queue = playback.get("queue")
                if isinstance(queue, list):
                    removed_ids.update(item for item in queue if isinstance(item, str))
                cleared_playback = {
                    **playback,
                    "queue": [],
                    "current_index": -1,
                    "position_ms": 0,
                }
                cleared_playback.pop("shuffle", None)
            else:
                cleared_playback = self._defaults()["playback"]
            replacements = {
                "track_details": {},
                "recent_tracks": [],
                "playback_history": [],
                "playback": cleared_playback,
            }
            self._commit_locked(replacements)
            self._deleted_track_ids.update(removed_ids)

    def get(self, key: str, default: Any = None) -> Any:
        return deepcopy(self._data.get(key, default))

    def set(self, key: str, value: Any) -> None:
        with self._lock:
            self._commit_locked({key: deepcopy(value)})

    def add_recent(self, key: str, value: str, *, limit: int = 50) -> None:
        with self._lock:
            self._commit_locked(
                {key: self._recent_items_locked(key, value, limit=limit)}
            )

    def record_play(
        self,
        track_id: str,
        *,
        played_at: float,
        playback: dict[str, Any] | None = None,
    ) -> None:
        """Update play metadata, histories, and optional session state atomically."""
        key = str(track_id)
        with self._lock:
            if key in self._deleted_track_ids:
                return
            details = TrackDetails.from_dict(self._data["track_details"].get(key, {}))
            details.play_count += 1
            details.last_played = float(played_at)
            changes = {
                "recent_tracks": self._recent_items_locked(
                    "recent_tracks", key, limit=20
                ),
                "playback_history": self._recent_items_locked(
                    "playback_history", key, limit=100
                ),
            }
            if playback is not None:
                changes["playback"] = deepcopy(playback)
            self._commit_locked(changes, track_details={key: details.to_dict()})

    def downloads(self) -> list[DownloadRecord]:
        return [
            DownloadRecord.from_dict(item) for item in self._data.get("downloads", [])
        ]

    def save_downloads(self, records: Iterable[DownloadRecord]) -> None:
        value = [record.to_dict() for record in deque(records, maxlen=250)]
        with self._lock:
            self._commit_locked({"downloads": value})

    def favorite_tracks(self, track_ids: Iterable[str]) -> int:
        """Mark several tracks as favorites with one atomic state write."""
        with self._lock:
            changes = {}
            for key in dict.fromkeys(str(track_id) for track_id in track_ids):
                details = TrackDetails.from_dict(
                    self._data["track_details"].get(key, {})
                )
                if details.favorite:
                    continue
                details.favorite = True
                changes[key] = details.to_dict()
            self._commit_locked({}, track_details=changes)
            return len(changes)

    def reconcile_track_references(self, valid_ids: Collection[str]) -> int:
        """Remove references to tracks the library no longer has.

        Returns the number of distinct track IDs whose references were removed.
        """
        with self._lock:
            stale = {
                key: _MISSING
                for key in self._data["track_details"]
                if key not in valid_ids
            }
            histories = {
                key: [item for item in self._data.get(key, []) if item in valid_ids]
                for key in ("recent_tracks", "playback_history")
            }
            stale_history_ids = {
                item
                for name in histories
                for item in self._data.get(name, [])
                if item not in valid_ids
            }
            self._commit_locked(histories, track_details=stale)
            self._deleted_track_ids.update(stale)
            self._deleted_track_ids.update(stale_history_ids)
            return len(stale_history_ids.union(stale))

    def _recent_items_locked(self, key: str, value: str, *, limit: int) -> list[str]:
        remaining = (item for item in self._data.get(key, []) if item != value)
        return list(islice(chain((value,), remaining), max(0, limit)))

    def _commit_locked(
        self,
        changes: dict[str, Any],
        *,
        track_details: dict[str, Any] | None = None,
    ) -> None:
        """Persist changed entries once, preserving the old state on failure.

        Callers hold the lock and supply owned values, never in-place mutations.
        Compare only touched entries before copying the catalog for a changed
        track detail, avoiding a second full equality pass.
        _MISSING represents deletion as well as an absent previous value.
        """
        updates = {
            key: value
            for key, value in changes.items()
            if not track_details or key != "track_details"
            if self._data.get(key, _MISSING) != value
        }
        if track_details:
            current_details = self._data["track_details"]
            changed_details = {}
            for key, value in track_details.items():
                if value is _MISSING:
                    if key in current_details:
                        changed_details[key] = value
                elif current_details.get(key, _MISSING) != value:
                    changed_details[key] = value
            if changed_details:
                details = dict(current_details)
                for key, value in changed_details.items():
                    if value is _MISSING:
                        details.pop(key)
                    else:
                        details[key] = value
                updates["track_details"] = details
        if not updates:
            return
        candidate = {**self._data, **updates}
        self._save_locked(candidate)
        self._data = candidate

    def save_playback_updates(
        self, changes: dict[str, Any], plays: dict[str, int]
    ) -> None:
        """Commit coalesced session/volume changes and exact play counts once."""
        with self._lock:
            updates = {}
            if "playback" in changes:
                updates["playback"] = changes["playback"]
            if "volume" in changes:
                updates["settings"] = {**self._data["settings"], **changes["volume"]}
            details = {}
            accepted_plays = {
                key: count
                for key, count in plays.items()
                if key not in self._deleted_track_ids
            }
            if not self._data["playback"].get("queue") and "playback" not in updates:
                accepted_plays.clear()
            if accepted_plays:
                for key, count in accepted_plays.items():
                    item = TrackDetails.from_dict(
                        self._data["track_details"].get(key, {})
                    )
                    item.play_count += count
                    item.last_played = time.time()
                    details[key] = item.to_dict()
                for name, limit in (("recent_tracks", 20), ("playback_history", 100)):
                    updates[name] = list(
                        dict.fromkeys(
                            [*reversed(accepted_plays), *self._data.get(name, [])]
                        )
                    )[:limit]
            self._commit_locked(updates, track_details=details)

    def _save_locked(self, data: dict[str, Any]) -> None:
        # Compact JSON materially reduces bytes encoded and flushed for hot
        # state updates. Human readability is provided through typed APIs and
        # documentation rather than whitespace in this private state file.
        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        atomic_write(self.path, payload.encode("utf-8"))
