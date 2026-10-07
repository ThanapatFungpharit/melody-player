"""Placing a runtime release on ``sys.path``, and taking it off again."""

from __future__ import annotations

import importlib
import logging
import sys
from pathlib import Path

from .packages import RuntimePackage
from .records import WheelRecord
from .wheels import extract_wheel, extracted_name, owned_by

logger = logging.getLogger(__name__)


def activate(storage: Path, record: WheelRecord, package: RuntimePackage) -> None:
    deactivate(storage, package)
    wheel = storage / record.filename
    path = (
        wheel
        if package.zip_safe
        else extract_wheel(wheel, storage / extracted_name(record.filename))
    )
    sys.path.insert(0, str(path))
    importlib.invalidate_caches()
    logger.info("Activated runtime %s %s", package.distribution, path.name)


def deactivate(storage: Path | None, package: RuntimePackage) -> None:
    """Remove ``package``'s runtime entries from ``sys.path``.

    Only activation adds entries inside ``storage``: a wheel, or a wheel
    extracted into a directory. Other entries there are left alone, so a
    storage directory placed beside the bundle can never unlist it.
    """
    if storage is None:
        return
    try:
        root = storage.resolve()
    except OSError:
        return
    retained: list[str] = []
    for entry in sys.path:
        if isinstance(entry, str) and entry:
            try:
                resolved: Path | None = Path(entry).resolve()
            except OSError, ValueError:
                resolved = None
            if (
                resolved is not None
                and resolved.parent == root
                and owned_by(resolved.name, package)
            ):
                continue
        retained.append(entry)
    sys.path[:] = retained
    importlib.invalidate_caches()
