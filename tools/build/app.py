"""Build Melody's Flutter app with its embedded Python worker and FFmpeg.

    uv run melody-build windows
    uv run melody-build apk --abi arm64-v8a --abi x86_64
    uv run melody-build macos -- --verbose

Each build stages FFmpeg for the target, packages ``worker/`` and its pinned
requirements with serious_python, then runs ``flutter build`` with the release
version from ``app/pubspec.yaml``. Outputs are collected under ``build/<target>``.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

from tools.build.media import fetch_bundle
from tools.build.version import build_number, release_version
from tools.common import (
    APP,
    MEDIA,
    ROOT,
    SIGNING_FILE,
    WORKER,
    executable,
    host_architecture,
    load_env_file,
    read_env_file,
    run,
    split_passthrough,
)

PYTHON_VERSION = "3.14"

DESKTOP = {"windows": "Windows", "linux": "Linux", "macos": "Darwin"}
SERIOUS_PLATFORMS = {**DESKTOP, "apk": "Android", "aab": "Android"}
ANDROID_ABIS = {"arm64-v8a": "arm64", "armeabi-v7a": "arm", "x86_64": "x86_64"}
ANDROID_TARGET_PLATFORMS = {
    "arm64-v8a": "android-arm64",
    "armeabi-v7a": "android-arm",
    "x86_64": "android-x64",
}
# Android zip-imports site-packages from sitepackages.zip. Packages that read
# their own data files from disk (ytmusicapi's gettext catalogs) must be
# unpacked instead; each glob matches top-level entries, so it also takes the
# package's .dist-info. Keep in step with the worker's non-zip-safe
# RuntimePackage entries (worker/src/melody_worker/updater/packages.py).
ANDROID_EXTRACT_PACKAGES = ("ytmusicapi*",)
SIGNING_VARIABLES = (
    "MELODY_ANDROID_KEY_STORE",
    "MELODY_ANDROID_KEY_STORE_PASSWORD",
    "MELODY_ANDROID_KEY_PASSWORD",
    "MELODY_ANDROID_KEY_ALIAS",
)
SIGNING_SECRETS = (
    "ANDROID_KEY_STORE_BASE64",
    "ANDROID_KEY_STORE_PASSWORD",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEY_ALIAS",
)


def worker_requirements() -> list[str]:
    """The worker's pinned runtime requirements from its uv lock."""
    exported = subprocess.run(
        [
            executable("uv"),
            "export",
            "--project",
            str(WORKER),
            "--frozen",
            "--no-dev",
            "--no-hashes",
            "--no-emit-project",
            "--format",
            "requirements-txt",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [
        line.strip()
        for line in exported.splitlines()
        if line.strip() and not line.lstrip().startswith(("#", "-"))
    ]


def stage_media(target: str, architecture: str, abis: list[str]) -> None:
    """Place FFmpeg/FFprobe where the native build bundles them."""
    if target in DESKTOP:
        fetch_bundle(target, architecture, binary_root=MEDIA)
        return
    if target in {"apk", "aab"}:
        jni = APP / "android" / "app" / "src" / "main" / "jniLibs"
        shutil.rmtree(jni, ignore_errors=True)
        for abi in abis:
            fetch_bundle("android", ANDROID_ABIS[abi], binary_root=MEDIA)
            source = MEDIA / "android" / ANDROID_ABIS[abi]
            destination = jni / abi
            destination.mkdir(parents=True, exist_ok=True)
            # Android 10+ executes programs only from the read-only native
            # library directory, so the executables ship as native libraries.
            shutil.copy2(source / "ffmpeg", destination / "libffmpeg.so")
            shutil.copy2(source / "ffprobe", destination / "libffprobe.so")


def python_environment(target: str, staging: Path) -> dict[str, str]:
    """What serious_python's packaging and the native build read."""
    env = {
        "SERIOUS_PYTHON_VERSION": PYTHON_VERSION,
        "SERIOUS_PYTHON_APP": str(staging / "app"),
        "SERIOUS_PYTHON_SITE_PACKAGES": str(staging / "site-packages"),
    }
    if target in {"apk", "aab"}:
        # Read by serious_python_android's Gradle build.
        env["SERIOUS_PYTHON_ANDROID_EXTRACT_PACKAGES"] = ",".join(
            ANDROID_EXTRACT_PACKAGES
        )
    return env


def package_worker(target: str, abis: list[str], env: dict[str, str]) -> None:
    command = [
        executable("dart"),
        "run",
        "serious_python:main",
        "package",
        str(WORKER / "src"),
        "-p",
        SERIOUS_PLATFORMS[target],
        "--python-version",
        PYTHON_VERSION,
        "--compile-packages",
        "--cleanup",
        "--exclude",
        "**/__pycache__",
        "--exclude",
        "*.egg-info",
    ]
    for requirement in worker_requirements():
        command += ["--requirements", requirement]
    for abi in abis:
        command += ["--arch", abi]
    run(command, cwd=APP, env=env)


@contextmanager
def android_signing(
    allow_debug: bool, signing_file: Path = SIGNING_FILE
) -> Generator[dict[str, str]]:
    """Release signing from MELODY_ANDROID_* or the base64 ANDROID_KEY_* secrets.

    The secrets come from the environment (as in CI) or from ``signing_file``;
    they reach only the ``flutter build`` that signs, never other steps.
    """
    if all(os.environ.get(name, "").strip() for name in SIGNING_VARIABLES):
        yield {}
        return
    secrets = {**read_env_file(signing_file), **os.environ}
    if all(secrets.get(name, "").strip() for name in SIGNING_SECRETS):
        try:
            key_store = base64.b64decode(
                secrets["ANDROID_KEY_STORE_BASE64"], validate=True
            )
        except (binascii.Error, ValueError) as error:
            raise SystemExit("ANDROID_KEY_STORE_BASE64 is not valid Base64") from error
        with tempfile.TemporaryDirectory(prefix="melody-signing-") as directory:
            path = Path(directory) / "release.jks"
            path.write_bytes(key_store)
            yield {
                "MELODY_ANDROID_KEY_STORE": str(path),
                "MELODY_ANDROID_KEY_STORE_PASSWORD": secrets[
                    "ANDROID_KEY_STORE_PASSWORD"
                ],
                "MELODY_ANDROID_KEY_PASSWORD": secrets["ANDROID_KEY_PASSWORD"],
                "MELODY_ANDROID_KEY_ALIAS": secrets["ANDROID_KEY_ALIAS"],
            }
        return
    if not allow_debug:
        raise SystemExit(
            "Android release signing is required: run `uv run melody-android-key`"
            f" to create {signing_file.name}, or set "
            + ", ".join(SIGNING_VARIABLES)
            + " (or pass --allow-debug-signing for a local test build)"
        )
    yield {}


def collect(target: str, version: str, architecture: str) -> Path:
    """Copy the build output to build/<target> with a predictable layout."""
    output = ROOT / "build" / target
    shutil.rmtree(output, ignore_errors=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    build = APP / "build"
    # Flutter's name for the desktop architecture it built for.
    arch = "arm64" if architecture == "arm64" else "x64"
    if target == "windows":
        shutil.copytree(build / "windows" / arch / "runner" / "Release", output)
    elif target == "linux":
        shutil.copytree(build / "linux" / arch / "release" / "bundle", output)
    elif target == "macos":
        bundle = build / "macos" / "Build" / "Products" / "Release" / "melody.app"
        resources = bundle / "Contents" / "Resources" / "ffmpeg"
        resources.mkdir(parents=True, exist_ok=True)
        for program in ("ffmpeg", "ffprobe"):
            shutil.copy2(MEDIA / "macos" / architecture / program, resources / program)
        output.mkdir(parents=True)
        shutil.copytree(bundle, output / "melody.app", symlinks=True)
    elif target == "apk":
        output.mkdir(parents=True)
        for apk in (build / "app" / "outputs" / "flutter-apk").glob(
            "app-*-release.apk"
        ):
            abi = apk.name.removeprefix("app-").removesuffix("-release.apk")
            shutil.copy2(apk, output / f"melody-{abi}.apk")
    elif target == "aab":
        output.mkdir(parents=True)
        shutil.copy2(
            build / "app" / "outputs" / "bundle" / "release" / "app-release.aab",
            output / f"melody-{version}.aab",
        )
    return output


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-build",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("target", choices=sorted(SERIOUS_PLATFORMS))
    parser.add_argument(
        "--architecture", default=host_architecture(), choices=["x86_64", "arm64"]
    )
    parser.add_argument(
        "--abi", action="append", choices=sorted(ANDROID_ABIS), dest="abis"
    )
    parser.add_argument("--skip-media", action="store_true", help="Reuse staged FFmpeg")
    parser.add_argument("--allow-debug-signing", action="store_true")
    # Anything after "--" is passed to `flutter build` unchanged.
    own, extra = split_passthrough(sys.argv[1:] if argv is None else argv)
    arguments = parser.parse_args(own)
    target = arguments.target
    load_env_file()
    version = release_version()
    abis = (arguments.abis or list(ANDROID_ABIS)) if target in {"apk", "aab"} else []
    staging = APP / "build" / "python" / target
    shutil.rmtree(staging, ignore_errors=True)
    env = {**os.environ, **python_environment(target, staging)}
    if not arguments.skip_media:
        stage_media(target, arguments.architecture, abis)
    package_worker(target, abis, env)
    command = [
        executable("flutter"),
        "build",
        {"apk": "apk", "aab": "appbundle"}.get(target, target),
        "--release",
        f"--build-name={version}",
        f"--build-number={build_number(version)}",
    ]
    if target == "apk":
        command.append("--split-per-abi")
    if abis:
        command.append(
            "--target-platform="
            + ",".join(ANDROID_TARGET_PLATFORMS[abi] for abi in abis)
        )
    if target in {"apk", "aab"}:
        with android_signing(arguments.allow_debug_signing) as signing:
            run([*command, *extra], cwd=APP, env={**env, **signing})
    else:
        run([*command, *extra], cwd=APP, env=env)
    print(f"Built {collect(target, version, arguments.architecture)}")


if __name__ == "__main__":
    main()
