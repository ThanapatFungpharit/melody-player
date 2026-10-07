"""Value types shared across the updater."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from packaging.version import Version


@dataclass(frozen=True)
class WheelRecord:
    """Trusted metadata for one installed runtime wheel."""

    version: Version
    filename: str
    sha256: str

    def __post_init__(self) -> None:
        # Digests compare as lowercase hex everywhere: state, probes, PyPI.
        if isinstance(self.sha256, str):
            object.__setattr__(self, "sha256", self.sha256.lower())

    def as_json(self) -> dict[str, str]:
        return {
            "version": str(self.version),
            "filename": self.filename,
            "sha256": self.sha256,
        }


@dataclass(frozen=True)
class RemoteRelease:
    version: Version
    filename: str
    url: str
    sha256: str

    def __post_init__(self) -> None:
        if isinstance(self.sha256, str):
            object.__setattr__(self, "sha256", self.sha256.lower())


@dataclass(frozen=True)
class UpdateResult:
    """Non-fatal selection diagnostics returned by :func:`prepare_package`."""

    active_version: str
    bundled_version: str
    current_version: str | None
    previous_version: str | None
    remote_version: str | None
    updated: bool
    recovered: bool
    rolled_back: bool
    active_source: str
    errors: tuple[str, ...] = ()


DownloadFunction = Callable[[str, Path], object]
RemoteFunction = Callable[[str], RemoteRelease | None]


def coerce_version(value: str | Version) -> Version:
    return value if isinstance(value, Version) else Version(str(value))
