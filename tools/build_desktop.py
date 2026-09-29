"""Prepare native dependencies and build a Flet desktop application."""

from __future__ import annotations

import argparse
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from dotenv import load_dotenv

from musicplayer.platform_runtime import current_architecture

if __package__:
    from tools.fetch_media_binaries import fetch_bundle
    from tools.production_build import (
        platform_flet_arguments,
        production_build_environment,
    )
else:
    from fetch_media_binaries import fetch_bundle  # ty: ignore[unresolved-import]
    from production_build import (  # ty: ignore[unresolved-import]
        platform_flet_arguments,
        production_build_environment,
    )

PROJECT_ROOT = Path(__file__).resolve().parents[1]
_OPTIONAL_REMOTE_DEBUG_MODULES = {
    "_remote_debugging.pyd",
    "_remote_debugging.soref",
    "lib_remote_debugging.so",
}


def strip_optional_remote_debugger(output: Path) -> None:
    """Remove CPython's optional debugger from a generated release bundle."""
    for path in output.rglob("*"):
        if path.is_file() and path.name.casefold() in _OPTIONAL_REMOTE_DEBUG_MODULES:
            path.unlink()


def prepare_desktop_media_bundles(target: str, architectures: list[str]) -> None:
    """Prepare independent architecture bundles with bounded concurrency."""
    if len(architectures) == 1:
        fetch_bundle(target, architectures[0])
        return
    with ThreadPoolExecutor(
        max_workers=2, thread_name_prefix="melody-desktop-media"
    ) as pool:
        futures = [pool.submit(fetch_bundle, target, arch) for arch in architectures]
        for future in futures:
            future.result()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("windows", "linux", "macos"))
    parser.add_argument(
        "--architecture",
        choices=("x86_64", "arm64"),
        action="append",
        dest="architectures",
    )
    arguments, flet_arguments = parser.parse_known_args()
    architectures = list(
        dict.fromkeys(arguments.architectures or [current_architecture()])
    )

    extra = flet_arguments
    if extra[:1] == ["--"]:
        extra = extra[1:]
    load_dotenv(PROJECT_ROOT / ".env", override=False)
    extra = platform_flet_arguments(
        extra, target=arguments.target, project_file=PROJECT_ROOT / "pyproject.toml"
    )
    build_environment = production_build_environment()

    prepare_desktop_media_bundles(arguments.target, architectures)

    command = [
        sys.executable,
        "-m",
        "flet_cli.cli",
        "build",
        arguments.target,
        str(PROJECT_ROOT),
    ]
    if arguments.target == "macos":
        # Flet forwards these names to serious_python, whose Darwin package
        # targets are x86_64 and arm64 (not Flutter's x64 alias).
        command.extend(("--arch", *architectures))
        # Flutter defaults release builds to universal binaries. Match the
        # native app to the Python packages and FFmpeg resources prepared above.
        build_environment["FLUTTER_XCODE_ARCHS"] = " ".join(architectures)
    command.extend(extra)
    subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        check=True,
        env=build_environment,
    )
    strip_optional_remote_debugger(PROJECT_ROOT / "build" / arguments.target)


if __name__ == "__main__":
    main()
