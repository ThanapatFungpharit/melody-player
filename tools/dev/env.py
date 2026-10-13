"""Print the environment that runs Melody from source, for your shell.

    uv run melody-env | Invoke-Expression                 # PowerShell
    eval "$(uv run melody-env --shell bash)"              # bash, zsh
    for /f "delims=" %i in ('uv run melody-env --shell cmd') do %i

Afterwards ``flutter run``, ``flutter test``, and IDE launches started from
that shell use the worker's development interpreter, a verified FFmpeg, and a
throwaway data folder instead of your real library. ``--layout mobile`` adds
the variables that show the phone UI in a phone-sized window; ``--size`` picks
another device or window size.
"""

from __future__ import annotations

import argparse
import contextlib
import sys
from pathlib import Path

from tools.build.media import fetch_bundle
from tools.common import (
    DEV_DATA,
    MEDIA,
    WORKER,
    host_architecture,
    host_platform,
    load_env_file,
    worker_python,
)

SHELLS = ("powershell", "bash", "cmd")
LAYOUTS = ("desktop", "mobile")
# Window sizes in logical pixels for previewing other devices on a desktop.
DEVICE_SIZES = {
    "phone": (390, 844),
    "small-phone": (320, 568),
    "phone-landscape": (844, 390),
    "tablet": (820, 1180),
    "narrow-desktop": (1040, 700),
}


def dev_environment(
    data_directory: Path | None, *, media: bool = True
) -> dict[str, str]:
    """MELODY_* variables for running the app or its tests from source.

    Syncs the worker's interpreter and, with ``media``, fetches FFmpeg for
    this machine. Progress goes to stderr so stdout stays machine-readable.
    """
    environment = {
        "MELODY_WORKER_PYTHON": str(worker_python()),
        "MELODY_WORKER_SOURCE": str(WORKER / "src"),
    }
    if media:
        with contextlib.redirect_stdout(sys.stderr):
            ffmpeg = fetch_bundle(
                host_platform(), host_architecture(), binary_root=MEDIA
            )
        environment["MELODY_FFMPEG_DIR"] = str(ffmpeg)
    if data_directory is not None:
        environment["MELODY_DATA_DIR"] = str(data_directory)
    return environment


def window_size(value: str) -> tuple[int, int]:
    """A device name from DEVICE_SIZES or WIDTHxHEIGHT, as (width, height)."""
    if value in DEVICE_SIZES:
        return DEVICE_SIZES[value]
    width, separator, height = value.casefold().partition("x")
    if separator and width.isdigit() and height.isdigit() and int(width) * int(height):
        return int(width), int(height)
    raise argparse.ArgumentTypeError(
        f"expected WIDTHxHEIGHT or one of {', '.join(DEVICE_SIZES)}, got {value!r}"
    )


def add_display_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--layout",
        choices=LAYOUTS,
        help="Show this UI regardless of platform; mobile previews the phone UI "
        "in a phone-sized desktop window",
    )
    parser.add_argument(
        "--size",
        type=window_size,
        metavar="DEVICE|WxH",
        help=f"Initial desktop window size: {', '.join(DEVICE_SIZES)}, or "
        "WIDTHxHEIGHT in logical pixels (default: phone with --layout mobile)",
    )


def display_environment(
    layout: str | None, size: tuple[int, int] | None
) -> dict[str, str]:
    """MELODY_LAYOUT and MELODY_WINDOW_SIZE for the chosen UI and window."""
    if size is None and layout == "mobile":
        size = DEVICE_SIZES["phone"]
    environment = {}
    if layout is not None:
        environment["MELODY_LAYOUT"] = layout
    if size is not None:
        environment["MELODY_WINDOW_SIZE"] = f"{size[0]}x{size[1]}"
    return environment


def render(environment: dict[str, str], shell: str) -> str:
    lines = []
    for key, value in environment.items():
        if shell == "powershell":
            lines.append(f"$env:{key} = '{value.replace("'", "''")}'")
        elif shell == "cmd":
            lines.append(f'set "{key}={value}"')
        else:
            lines.append(f"export {key}='{value.replace("'", "'\\''")}'")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-env",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--shell",
        choices=SHELLS,
        default="powershell" if sys.platform == "win32" else "bash",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=DEV_DATA,
        help=f"Application state and default music folder (default: {DEV_DATA})",
    )
    parser.add_argument(
        "--no-media", action="store_true", help="Do not fetch or point at FFmpeg"
    )
    add_display_arguments(parser)
    arguments = parser.parse_args(argv)
    load_env_file()
    environment = dev_environment(
        arguments.data_dir.resolve(), media=not arguments.no_media
    )
    environment.update(display_environment(arguments.layout, arguments.size))
    print(render(environment, arguments.shell))


if __name__ == "__main__":
    main()
