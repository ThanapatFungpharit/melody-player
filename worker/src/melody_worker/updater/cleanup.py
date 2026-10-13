"""Removing temporary and obsolete runtime files from storage.

Only one package's files are touched; anything else in storage (including
the state and lock files) is left alone.
"""

from __future__ import annotations

import logging
from pathlib import Path

from packaging.version import Version

from .constants import PROBED_FILE
from .files import remove
from .packages import RuntimePackage
from .records import WheelRecord
from .wheels import extracted_name, owned_by, parse_wheel_name

logger = logging.getLogger(__name__)


def is_temporary(name: str, package: RuntimePackage) -> bool:
    """A temporary file the updater made: a download, an extraction, or
    a state record being written."""
    return name.endswith((".tmp", ".part")) and (
        owned_by(name, package) or name.startswith(("state.json", PROBED_FILE))
    )


def remove_temporary_files(storage: Path, package: RuntimePackage) -> bool:
    """Remove stale temporary files; returns whether any were found."""
    found = False
    for path in storage.iterdir():
        if is_temporary(path.name, package):
            logger.info(
                "Removing stale %s temporary file %s", package.distribution, path.name
            )
            found = True
            remove(path)
    return found


def remove_obsolete(
    storage: Path,
    package: RuntimePackage,
    bundled: Version,
    current: WheelRecord | None,
    previous: WheelRecord | None,
) -> None:
    keep = {
        name
        for record in (current, previous)
        if record
        for name in (record.filename, extracted_name(record.filename))
    }
    for path in storage.iterdir():
        if path.name in keep:
            continue
        if is_temporary(path.name, package):
            remove(path)
        elif owned_by(path.name, package):
            parsed = parse_wheel_name(path.name, package)
            if parsed is not None and parsed[0] <= bundled:
                logger.info(
                    "Removing obsolete bundled-era %s %s",
                    package.distribution,
                    path.name,
                )
            else:
                logger.info(
                    "Removing obsolete %s runtime file %s",
                    package.distribution,
                    path.name,
                )
            remove(path)
