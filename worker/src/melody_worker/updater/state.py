"""The shape of ``state.json`` and how its entries map to wheel records."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any

from packaging.version import InvalidVersion, Version

from .constants import SHA256_HEX
from .packages import RuntimePackage
from .records import WheelRecord
from .wheels import parse_wheel_name


def entry_shape(value: object, package: RuntimePackage) -> bool:
    if value is None:
        return True
    if not isinstance(value, dict):
        return False
    if not all(
        isinstance(value.get(key), str) for key in ("version", "filename", "sha256")
    ):
        return False
    try:
        version = Version(value["version"])
    except InvalidVersion, TypeError:
        return False
    parsed = parse_wheel_name(value["filename"], package)
    return (
        parsed is not None
        and parsed[0] == version
        and SHA256_HEX.fullmatch(value["sha256"]) is not None
        and Path(value["filename"]).name == value["filename"]
        and "/" not in value["filename"]
        and "\\" not in value["filename"]
    )


def state_records(
    state: Mapping[str, Any], package: RuntimePackage
) -> dict[str, WheelRecord]:
    result: dict[str, WheelRecord] = {}
    entries = [state.get("current"), state.get("previous")]
    pending = state.get("pending")
    if isinstance(pending, dict) and pending.get("status") == "validated":
        entries.append(pending.get("wheel"))
    for value in entries:
        if not isinstance(value, dict) or not entry_shape(value, package):
            continue
        version = Version(value["version"])
        result[value["filename"]] = WheelRecord(
            version, value["filename"], value["sha256"].lower()
        )
    return result


def record_for_state(
    records: Mapping[str, WheelRecord], value: object
) -> WheelRecord | None:
    if not isinstance(value, dict):
        return None
    filename = value.get("filename")
    if not isinstance(filename, str):
        return None
    return records.get(filename)


def same_roles(
    state: Mapping[str, Any],
    current: WheelRecord | None,
    previous: WheelRecord | None,
) -> bool:
    return _state_entry_matches(state.get("current"), current) and _state_entry_matches(
        state.get("previous"), previous
    )


def _state_entry_matches(value: object, record: WheelRecord | None) -> bool:
    if record is None:
        return value is None
    return isinstance(value, dict) and value == record.as_json()
