"""Download and verify the FFmpeg/FFprobe bundles used by application builds."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import stat
import tarfile
import tempfile
import urllib.request
import zipfile
from dataclasses import dataclass
from functools import cache
from pathlib import Path, PurePosixPath
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BINARY_ROOT = PROJECT_ROOT / "src" / "musicplayer" / "bin"


@dataclass(frozen=True)
class Archive:
    """A stable selector for an asset in a provider's latest GitHub release."""

    repository: str
    filename: str | None = None
    filename_suffix: str | None = None
    license: str = "GPL-2.0-or-later"

    @property
    def selector(self) -> str:
        if self.filename is not None:
            return self.filename
        if self.filename_suffix is not None:
            return f"*{self.filename_suffix}"
        raise ValueError("An FFmpeg archive needs an asset filename selector")


@dataclass(frozen=True)
class ReleaseAsset:
    filename: str
    url: str
    sha256: str


@dataclass(frozen=True)
class ResolvedArchive:
    archive: Archive
    filename: str
    url: str
    sha256: str
    version: str

    @property
    def source_code(self) -> str:
        return f"https://github.com/{self.archive.repository}/tree/{self.version}"


ARCHIVES: dict[tuple[str, str], Archive] = {
    ("windows", "x86_64"): Archive(
        "binmgr/ffmpeg",
        "ffmpeg-windows-amd64.zip",
    ),
    ("windows", "arm64"): Archive(
        "binmgr/ffmpeg",
        "ffmpeg-windows-arm64.zip",
    ),
    ("linux", "x86_64"): Archive(
        "binmgr/ffmpeg",
        "ffmpeg-linux-amd64.tar.gz",
    ),
    ("linux", "arm64"): Archive(
        "binmgr/ffmpeg",
        "ffmpeg-linux-arm64.tar.gz",
    ),
    ("macos", "x86_64"): Archive(
        "binmgr/ffmpeg",
        "ffmpeg-darwin-amd64.tar.gz",
    ),
    ("macos", "arm64"): Archive(
        "binmgr/ffmpeg",
        "ffmpeg-darwin-arm64.tar.gz",
    ),
    ("android", "arm64"): Archive(
        "rhythmcache/ffmpeg-android",
        filename_suffix="-Static-android-arm64-v8a.zip",
        license="GPL-3.0-or-later",
    ),
    ("android", "arm"): Archive(
        "rhythmcache/ffmpeg-android",
        filename_suffix="-Static-android-armeabi-v7a.zip",
        license="GPL-3.0-or-later",
    ),
    ("android", "x86_64"): Archive(
        "rhythmcache/ffmpeg-android",
        filename_suffix="-Static-android-x86_64.zip",
        license="GPL-3.0-or-later",
    ),
}


@cache
def _latest_release(repository: str) -> tuple[str, tuple[ReleaseAsset, ...]]:
    """Read GitHub's current release manifest once for each artifact provider."""
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/releases/latest",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "Melody-build/1",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload: Any = json.load(response)

    tag = payload.get("tag_name")
    assets = payload.get("assets")
    if not isinstance(tag, str) or not isinstance(assets, list):
        raise TypeError(f"GitHub returned an invalid release manifest for {repository}")

    resolved_assets: list[ReleaseAsset] = []
    for asset in assets:
        if not isinstance(asset, dict):
            continue
        filename = asset.get("name")
        url = asset.get("browser_download_url")
        digest = asset.get("digest")
        if not isinstance(filename, str) or not isinstance(url, str):
            continue
        if not isinstance(digest, str) or not digest.startswith("sha256:"):
            continue
        sha256 = digest.removeprefix("sha256:")
        if len(sha256) != 64 or any(
            character not in "0123456789abcdef" for character in sha256
        ):
            continue
        resolved_assets.append(ReleaseAsset(filename, url, sha256))

    return tag, tuple(resolved_assets)


def _resolve_archive(archive: Archive) -> ResolvedArchive:
    """Resolve a stable filename selector without embedding a release tag in code."""
    version, assets = _latest_release(archive.repository)
    if archive.filename is not None:
        matches = [asset for asset in assets if asset.filename == archive.filename]
    else:
        suffix = archive.filename_suffix
        matches = [
            asset
            for asset in assets
            if suffix is not None and asset.filename.endswith(suffix)
        ]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one asset matching {archive.selector!r} in "
            f"{archive.repository}'s latest release, found {len(matches)}"
        )
    asset = matches[0]
    return ResolvedArchive(archive, asset.filename, asset.url, asset.sha256, version)


def fetch_bundle(
    platform_name: str,
    architecture: str,
    *,
    binary_root: Path = DEFAULT_BINARY_ROOT,
) -> Path:
    """Download, verify, and extract a single target bundle."""
    try:
        archive = ARCHIVES[(platform_name, architecture)]
    except KeyError:
        raise ValueError(
            f"No supported media bundle for {platform_name}/{architecture}"
        ) from None
    target = binary_root / platform_name / architecture
    suffix = ".exe" if platform_name == "windows" else ""
    expected = (target / f"ffmpeg{suffix}", target / f"ffprobe{suffix}")
    metadata_path = target / "bundle.json"
    if all(path.is_file() for path in expected) and metadata_path.is_file():
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if (
            metadata.get("source_repository") == archive.repository
            and metadata.get("asset_selector") == archive.selector
            and isinstance(metadata.get("archive_sha256"), str)
        ):
            print(f"Using cached media tools for {platform_name}/{architecture}")
            return target

    resolved = _resolve_archive(archive)
    target.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="melody-ffmpeg-") as temporary:
        download = Path(temporary) / resolved.filename
        print(f"Downloading {resolved.url}")
        _download(resolved.url, download)
        actual_digest = _sha256(download)
        if actual_digest != resolved.sha256:
            raise RuntimeError(
                f"Checksum mismatch for {resolved.filename}: expected "
                f"{resolved.sha256}, received {actual_digest}"
            )
        extracted = _extract_programs(download, Path(temporary) / "extracted")
        for program in (f"ffmpeg{suffix}", f"ffprobe{suffix}"):
            source = extracted[program]
            destination = target / program
            shutil.copy2(source, destination)
            if platform_name != "windows":
                destination.chmod(
                    destination.stat().st_mode
                    | stat.S_IXUSR
                    | stat.S_IXGRP
                    | stat.S_IXOTH
                )

    metadata_path.write_text(
        json.dumps(
            {
                "version": resolved.version,
                "source_repository": archive.repository,
                "asset_selector": archive.selector,
                "source": resolved.url,
                "archive_sha256": resolved.sha256,
                "license": archive.license,
                "source_code": resolved.source_code,
            },
            indent=2,
        )
        + os.linesep,
        encoding="utf-8",
    )
    print(f"Prepared media tools in {target}")
    return target


def _download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "Melody-build/1"})
    with (
        urllib.request.urlopen(request, timeout=60) as response,
        destination.open("wb") as output,
    ):
        shutil.copyfileobj(response, output)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _extract_programs(archive: Path, destination: Path) -> dict[str, Path]:
    destination.mkdir(parents=True, exist_ok=True)
    expected_names = {"ffmpeg", "ffprobe", "ffmpeg.exe", "ffprobe.exe"}
    extracted: dict[str, Path] = {}

    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                name = PurePosixPath(member.filename).name
                if name.endswith(".tar.xz") and not member.is_dir():
                    with package.open(member) as nested:
                        nested_data = nested.read()
                    with tarfile.open(
                        fileobj=io.BytesIO(nested_data), mode="r:xz"
                    ) as nested_package:
                        _extract_tar_programs(
                            nested_package, destination, expected_names, extracted
                        )
                    continue
                if name not in expected_names or member.is_dir():
                    continue
                path = destination / name
                with package.open(member) as source, path.open("wb") as output:
                    shutil.copyfileobj(source, output)
                extracted[name] = path
    else:
        with tarfile.open(archive, mode="r:gz") as package:
            _extract_tar_programs(package, destination, expected_names, extracted)

    unix_programs = {"ffmpeg", "ffprobe"}
    windows_programs = {"ffmpeg.exe", "ffprobe.exe"}
    required = (
        unix_programs if unix_programs.intersection(extracted) else windows_programs
    )
    missing = required.difference(extracted)
    if missing:
        raise RuntimeError(
            f"{archive.name} did not contain: {', '.join(sorted(missing))}"
        )
    return extracted


def _extract_tar_programs(
    package: tarfile.TarFile,
    destination: Path,
    expected_names: set[str],
    extracted: dict[str, Path],
) -> None:
    for member in package.getmembers():
        name = PurePosixPath(member.name).name
        if name not in expected_names or not member.isfile():
            continue
        source = package.extractfile(member)
        if source is None:
            continue
        path = destination / name
        with source, path.open("wb") as output:
            shutil.copyfileobj(source, output)
        extracted[name] = path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--platform",
        choices=("windows", "linux", "macos", "android", "all"),
        default="all",
    )
    parser.add_argument(
        "--architecture",
        choices=("x86_64", "arm64", "arm", "all"),
        default="all",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_BINARY_ROOT)
    arguments = parser.parse_args()

    platforms = (
        ("windows", "linux", "macos", "android")
        if arguments.platform == "all"
        else (arguments.platform,)
    )
    architectures = (
        ("x86_64", "arm64", "arm")
        if arguments.architecture == "all"
        else (arguments.architecture,)
    )
    for platform_name, architecture in ARCHIVES:
        if platform_name in platforms and architecture in architectures:
            fetch_bundle(platform_name, architecture, binary_root=arguments.output)


if __name__ == "__main__":
    main()
