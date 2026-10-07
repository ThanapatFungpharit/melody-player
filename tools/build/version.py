"""Read the sole release version from the Flutter app's pubspec."""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from tools.common import APP

PUBSPEC = APP / "pubspec.yaml"
_VERSION_LINE = re.compile(
    r"^version:\s*(?P<version>(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*))"
    r"\+(?P<build>\d+)\s*$",
    re.MULTILINE,
)


def build_number(version: str) -> int:
    major, minor, patch = map(int, version.split("."))
    if major > 2099 or minor >= 1000 or patch >= 1000:
        raise ValueError("Version exceeds the Android build-number allocation")
    return major * 1_000_000 + minor * 1_000 + patch


def release_version(pubspec: Path = PUBSPEC) -> str:
    """Return major.minor.patch, checking that the build number agrees."""
    match = _VERSION_LINE.search(pubspec.read_text("utf-8"))
    if match is None:
        raise ValueError("app/pubspec.yaml must declare version: X.Y.Z+BUILD")
    version = match["version"]
    expected = build_number(version)
    if int(match["build"]) != expected:
        raise ValueError(
            f"app/pubspec.yaml build number must be {expected} for version {version}"
        )
    return version


def validate_tag(version: str, ref: str) -> None:
    if ref.startswith("refs/tags/") and ref != f"refs/tags/v{version}":
        raise ValueError(f"Release tag {ref!r} must match v{version}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="melody-version", description=__doc__)
    parser.add_argument("--ref", default=os.environ.get("GITHUB_REF", ""))
    args = parser.parse_args(argv)
    version = release_version()
    validate_tag(version, args.ref)
    print(version)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with Path(output).open("a", encoding="utf-8") as stream:
            stream.write(f"version={version}\nbuild_number={build_number(version)}\n")


if __name__ == "__main__":
    main()
