"""Wheel filenames, archive validation, and extraction."""

from __future__ import annotations

import importlib.metadata
import os
import sys
import uuid
import zipfile
import zlib
from email.parser import BytesParser
from pathlib import Path, PurePosixPath

from packaging.requirements import Requirement
from packaging.specifiers import InvalidSpecifier, SpecifierSet
from packaging.version import InvalidVersion, Version

from .constants import EXTRACTED_MARKER, MAX_EXPANDED_BYTES
from .files import remove, sha256_file
from .packages import RuntimePackage


def parse_wheel_name(name: str, package: RuntimePackage) -> tuple[Version, str] | None:
    match = package.wheel_name.fullmatch(name)
    if match is None:
        return None
    try:
        version = Version(match.group("version"))
    except InvalidVersion:
        return None
    return version, name


def owned_by(name: str, package: RuntimePackage) -> bool:
    """Whether ``name`` is one of ``package``'s runtime files: a wheel, its
    extraction, or a temporary file made from either."""
    normalized = name.casefold().lstrip(".").replace("-", "_")
    prefix = package.wheel_prefix.casefold().replace("-", "_")
    # A version follows the project name; this keeps ``yt_dlp_ejs-...`` out.
    return (
        normalized.startswith(prefix)
        and normalized[len(prefix) : len(prefix) + 1].isdigit()
    )


def extracted_name(filename: str) -> str:
    """The directory a non-zip-safe wheel is extracted into."""
    return filename.removesuffix(".whl")


def python_compatible(constraint: str) -> bool:
    try:
        specifier = SpecifierSet(constraint)
    except InvalidSpecifier:
        return False
    return Version(".".join(map(str, sys.version_info[:3]))) in specifier


def validate_archive(
    archive: zipfile.ZipFile, version: Version, package: RuntimePackage
) -> None:
    entries = archive.infolist()
    names = [entry.filename for entry in entries]
    if (
        len(set(names)) != len(names)
        or sum(entry.file_size for entry in entries) > MAX_EXPANDED_BYTES
    ):
        raise ValueError("Wheel contains duplicate members or excessive expanded data")
    for name in names:
        if name.startswith("/") or "\\" in name or ".." in name.split("/"):
            raise ValueError("Wheel contains an unsafe path")
    if not package.required_members.issubset(names):
        raise ValueError(f"Wheel is missing {package.distribution}'s package modules")
    metadata_names = [name for name in names if name.endswith(".dist-info/METADATA")]
    if len(metadata_names) != 1:
        raise ValueError("Wheel must contain exactly one distribution metadata record")
    metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
    if (
        str(metadata.get("Name", "")).replace("_", "-").lower() != package.distribution
        or Version(str(metadata.get("Version", ""))) != version
    ):
        raise ValueError(
            "Wheel metadata does not match the selected distribution/version"
        )
    python_constraint = str(metadata.get("Requires-Python", "")).strip()
    if python_constraint and not python_compatible(python_constraint):
        raise ValueError("Wheel requires an incompatible Python version")
    for value in metadata.get_all("Requires-Dist", []):
        requirement = Requirement(str(value))
        if requirement.marker is not None and not requirement.marker.evaluate(
            {"extra": ""}
        ):
            continue
        installed = Version(importlib.metadata.version(requirement.name))
        if installed not in requirement.specifier:
            raise ValueError(
                f"Wheel requires an incompatible dependency: {requirement.name}"
            )


def extract_wheel(wheel: Path, target: Path) -> Path:
    """Extract a validated wheel into ``target``, reusing an intact copy.

    An existing directory is reused only when it was made from this exact
    wheel and every archive member still matches by size and CRC-32, so a
    damaged or edited extraction is replaced rather than imported.
    """
    digest = sha256_file(wheel)
    with zipfile.ZipFile(wheel) as archive:
        if _extraction_matches(archive, target, digest):
            return target
        temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}.tmp")
        try:
            archive.extractall(temporary)
            (temporary / EXTRACTED_MARKER).write_text(digest, encoding="ascii")
            remove(target)
            os.replace(temporary, target)
        finally:
            remove(temporary)
    return target


def _extraction_matches(archive: zipfile.ZipFile, target: Path, digest: str) -> bool:
    """Whether ``target`` holds exactly ``archive``'s files, byte for byte,
    plus nothing but the marker and bytecode caches."""
    try:
        if (target / EXTRACTED_MARKER).read_text(encoding="ascii").strip() != digest:
            return False
        members = {
            entry.filename: entry for entry in archive.infolist() if not entry.is_dir()
        }
        for path in target.rglob("*"):
            if path.is_symlink():
                return False
            if path.is_dir():
                continue
            relative = PurePosixPath(path.relative_to(target).as_posix())
            if str(relative) == EXTRACTED_MARKER or str(relative) in members:
                continue
            if relative.parent.name == "__pycache__" and relative.suffix == ".pyc":
                continue
            # Any other file could add or shadow a module.
            return False
        for entry in members.values():
            path = target / entry.filename
            if path.is_symlink() or path.stat().st_size != entry.file_size:
                return False
            crc = 0
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    crc = zlib.crc32(chunk, crc)
            if crc != entry.CRC:
                return False
    except OSError, ValueError:
        return False
    return True


class temporary_extraction:
    """Extract a wheel beside itself for probing; removed afterwards."""

    def __init__(self, wheel: Path) -> None:
        self._wheel = wheel
        self._directory = wheel.with_name(f".{wheel.name}.{uuid.uuid4().hex}.tmp")

    def __enter__(self) -> Path:
        try:
            with zipfile.ZipFile(self._wheel) as archive:
                archive.extractall(self._directory)
        except BaseException:
            # __exit__ does not run when __enter__ raises.
            remove(self._directory)
            raise
        return self._directory

    def __exit__(self, *_: object) -> None:
        remove(self._directory)
