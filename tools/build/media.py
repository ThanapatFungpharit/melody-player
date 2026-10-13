"""Download and verify the FFmpeg/FFprobe bundles used by application builds."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from tools.common import MEDIA, host_architecture, host_platform

VERSION = "v9.0.1"
RELEASE_ROOT = f"https://github.com/binmgr/ffmpeg/releases/download/{VERSION}"
BTBN_RELEASE_ROOT = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"
ANDROID_VERSION = "build-264"
ANDROID_RELEASE_ROOT = (
    f"https://github.com/rhythmcache/ffmpeg-android/releases/download/{ANDROID_VERSION}"
)
DEFAULT_BINARY_ROOT = MEDIA
REQUIRED_AUDIO_ENCODERS = frozenset({"libmp3lame", "aac", "libopus"})


@dataclass(frozen=True)
class Archive:
    filename: str
    sha256: str | None
    release_root: str = RELEASE_ROOT
    version: str = VERSION
    license: str = "GPL-2.0-or-later"
    source_code: str = f"https://github.com/binmgr/ffmpeg/tree/{VERSION}"
    repository: str | None = None

    @property
    def url(self) -> str:
        return f"{self.release_root}/{self.filename}"


@dataclass(frozen=True)
class ResolvedArchive:
    url: str
    sha256: str
    version: str
    source_code: str


ARCHIVES: dict[tuple[str, str], Archive] = {
    ("windows", "x86_64"): Archive(
        "ffmpeg-n9.0-latest-win64-gpl-9.0.zip",
        None,
        release_root=BTBN_RELEASE_ROOT,
        version="latest",
        license="GPL-3.0-or-later",
        repository="BtbN/FFmpeg-Builds",
    ),
    ("windows", "arm64"): Archive(
        "ffmpeg-n9.0-latest-winarm64-gpl-9.0.zip",
        None,
        release_root=BTBN_RELEASE_ROOT,
        version="latest",
        license="GPL-3.0-or-later",
        repository="BtbN/FFmpeg-Builds",
    ),
    ("linux", "x86_64"): Archive(
        "ffmpeg-linux-amd64.tar.gz",
        "981493cde0bd9303129e6a7bef1a22bb65089bd8e04fd96622878a865761d706",
    ),
    ("linux", "arm64"): Archive(
        "ffmpeg-linux-arm64.tar.gz",
        "4fdc66bd708aef86f4e431f52f72bb26ce49eb9e12d34ff92c069e04dabc2df5",
    ),
    ("macos", "x86_64"): Archive(
        "ffmpeg-darwin-amd64.tar.gz",
        "a58d579615e8bfd54cb063e208d9c6c33b6ed81a8030885347167ff86ba43148",
    ),
    ("macos", "arm64"): Archive(
        "ffmpeg-darwin-arm64.tar.gz",
        "5e28fe92746c35be5a5c0c7bffe8397c36e9bf75867eb28992c69fcfb69be155",
    ),
    ("android", "arm64"): Archive(
        "ffmpeg-8.0-ee2eb6c-Static-android-arm64-v8a.zip",
        "a18551c916b3cb60c41930d0affdf44763497fe318ccec9555ab93097a9c28c8",
        release_root=ANDROID_RELEASE_ROOT,
        version=ANDROID_VERSION,
        license="GPL-3.0-or-later",
        source_code="https://github.com/rhythmcache/ffmpeg-android/tree/0f21485",
    ),
    ("android", "arm"): Archive(
        "ffmpeg-8.0-ee2eb6c-Static-android-armeabi-v7a.zip",
        "15fd326dd60cae3e444e33911663ba3bb37f2f9f1672581d09e1f4d4e4cf5b9f",
        release_root=ANDROID_RELEASE_ROOT,
        version=ANDROID_VERSION,
        license="GPL-3.0-or-later",
        source_code="https://github.com/rhythmcache/ffmpeg-android/tree/0f21485",
    ),
    ("android", "x86_64"): Archive(
        "ffmpeg-8.0-ee2eb6c-Static-android-x86_64.zip",
        "f41fb1339c4d609e376bc99ea0982a11db5cebeb2dce2e302c60cce9dd0ffe0e",
        release_root=ANDROID_RELEASE_ROOT,
        version=ANDROID_VERSION,
        license="GPL-3.0-or-later",
        source_code="https://github.com/rhythmcache/ffmpeg-android/tree/0f21485",
    ),
}


def _latest_release(repository: str) -> tuple[str, tuple[tuple[str, str, str], ...]]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Melody-build/1",
    }
    # CI runners share IPs, so anonymous requests soon hit GitHub's rate limit.
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/releases/latest",
        headers=headers,
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        payload: Any = json.load(response)
    if not isinstance(payload, dict):
        raise TypeError(f"GitHub returned an invalid release manifest for {repository}")
    tag = payload.get("tag_name")
    assets = payload.get("assets")
    if not isinstance(tag, str) or not isinstance(assets, list):
        raise TypeError(f"GitHub returned an invalid release manifest for {repository}")
    resolved_assets: list[tuple[str, str, str]] = []
    for asset in assets:
        if not isinstance(asset, dict):
            continue
        filename = asset.get("name")
        url = asset.get("browser_download_url")
        digest = asset.get("digest")
        if (
            isinstance(filename, str)
            and isinstance(url, str)
            and isinstance(digest, str)
            and digest.startswith("sha256:")
        ):
            sha256 = digest.removeprefix("sha256:")
            if len(sha256) == 64 and all(
                character in "0123456789abcdef" for character in sha256
            ):
                resolved_assets.append((filename, url, sha256))
    return tag, tuple(resolved_assets)


def _resolve_archive(archive: Archive) -> ResolvedArchive:
    if archive.sha256 is not None:
        return ResolvedArchive(
            archive.url, archive.sha256, archive.version, archive.source_code
        )
    if archive.repository is None:
        raise ValueError(f"No release repository for {archive.filename}")
    version, assets = _latest_release(archive.repository)
    matches = [asset for asset in assets if asset[0] == archive.filename]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one {archive.filename!r} asset in "
            f"{archive.repository}'s latest release, found {len(matches)}"
        )
    _, url, sha256 = matches[0]
    return ResolvedArchive(
        url, sha256, version, f"https://github.com/{archive.repository}/tree/{version}"
    )


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
    try:
        resolved = _resolve_archive(archive)
    except urllib.error.URLError, TimeoutError:
        if archive.repository is None or not _cache_valid(
            metadata_path, archive, expected, resolved=None
        ):
            raise
        print(f"Using cached media tools offline for {platform_name}/{architecture}")
        return target
    if _cache_valid(metadata_path, archive, expected, resolved=resolved):
        print(f"Using cached media tools for {platform_name}/{architecture}")
        return target

    with tempfile.TemporaryDirectory(prefix="melody-ffmpeg-") as temporary:
        download = Path(temporary) / archive.filename
        print(f"Downloading {resolved.url}")
        _download(resolved.url, download)
        actual_digest = _sha256(download)
        if actual_digest != resolved.sha256:
            raise RuntimeError(
                f"Checksum mismatch for {archive.filename}: expected "
                f"{resolved.sha256}, received {actual_digest}"
            )
        extracted = _extract_programs(download, Path(temporary) / "extracted")
        # The encoder check runs the downloaded program, so only on its host.
        host = (host_platform(), host_architecture())
        if platform_name == "windows" and (platform_name, architecture) == host:
            _validate_audio_encoders(extracted[f"ffmpeg{suffix}"])

        target.mkdir(parents=True, exist_ok=True)
        program_hashes: dict[str, str] = {}
        for program in (f"ffmpeg{suffix}", f"ffprobe{suffix}"):
            source = extracted[program]
            destination = target / program
            program_hashes[program] = _sha256(source)
            shutil.copy2(source, destination)
            if platform_name != "windows":
                destination.chmod(
                    destination.stat().st_mode
                    | stat.S_IXUSR
                    | stat.S_IXGRP
                    | stat.S_IXOTH
                )
            if _sha256(destination) != program_hashes[program]:
                raise RuntimeError(
                    f"Copied media program failed verification: {destination}"
                )

    metadata_text = (
        json.dumps(
            {
                "version": resolved.version,
                "source": resolved.url,
                "archive_sha256": resolved.sha256,
                "program_sha256": program_hashes,
                "license": archive.license,
                "source_code": resolved.source_code,
            },
            indent=2,
        )
        + os.linesep
    )
    pending_metadata = target / ".bundle.json.tmp"
    try:
        pending_metadata.write_text(metadata_text, encoding="utf-8")
        os.replace(pending_metadata, metadata_path)
    finally:
        pending_metadata.unlink(missing_ok=True)
    print(f"Prepared media tools in {target}")
    return target


def _cache_valid(
    metadata_path: Path,
    archive: Archive,
    expected: tuple[Path, Path],
    *,
    resolved: ResolvedArchive | None,
) -> bool:
    if not metadata_path.is_file() or not all(path.is_file() for path in expected):
        return False
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if not isinstance(metadata, dict):
            return False
        program_hashes = metadata.get("program_sha256")
        if not isinstance(program_hashes, dict):
            return False
        source = resolved.url if resolved is not None else archive.url
        if resolved is None:
            archive_sha256 = metadata.get("archive_sha256")
            valid_archive_sha256 = (
                isinstance(archive_sha256, str)
                and len(archive_sha256) == 64
                and all(character in "0123456789abcdef" for character in archive_sha256)
            )
        else:
            valid_archive_sha256 = (
                metadata.get("archive_sha256") == resolved.sha256
                and metadata.get("version") == resolved.version
            )
        return (
            metadata.get("source") == source
            and valid_archive_sha256
            and all(
                isinstance(program_hashes.get(path.name), str)
                and _sha256(path) == program_hashes[path.name]
                and (path.suffix == ".exe" or path.stat().st_mode & 0o111 != 0)
                for path in expected
            )
        )
    except OSError, UnicodeError, ValueError:
        return False


def _validate_audio_encoders(ffmpeg: Path) -> None:
    try:
        result = subprocess.run(
            [str(ffmpeg), "-hide_banner", "-encoders"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"Could not inspect {ffmpeg}: {error}") from error
    if result.returncode != 0:
        raise RuntimeError(f"Could not inspect {ffmpeg}: {result.stderr.strip()}")
    encoders = {
        fields[1]
        for line in result.stdout.splitlines()
        if len(fields := line.split()) >= 2 and fields[0].startswith("A")
    }
    missing = REQUIRED_AUDIO_ENCODERS - encoders
    if missing:
        raise RuntimeError(
            f"{ffmpeg} is missing required audio encoders: {', '.join(sorted(missing))}"
        )


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
                    # Large Android bundles contain a compressed tar inside the
                    # zip. Spool it in bounded chunks instead of holding the
                    # entire compressed archive in RAM during extraction.
                    with (
                        package.open(member) as nested,
                        tempfile.SpooledTemporaryFile(
                            max_size=8 * 1024 * 1024
                        ) as staged,
                    ):
                        shutil.copyfileobj(nested, staged, 1024 * 1024)
                        staged.seek(0)
                        with tarfile.open(
                            fileobj=staged, mode="r:xz"
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


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="melody-fetch-media", description=__doc__)
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
    arguments = parser.parse_args(argv)

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
    selected = [
        (platform_name, architecture)
        for platform_name, architecture in ARCHIVES
        if platform_name in platforms and architecture in architectures
    ]
    if not selected:
        parser.error(
            f"No supported media bundle for {arguments.platform}/{arguments.architecture}"
        )
    for platform_name, architecture in selected:
        fetch_bundle(platform_name, architecture, binary_root=arguments.output)


if __name__ == "__main__":
    main()
