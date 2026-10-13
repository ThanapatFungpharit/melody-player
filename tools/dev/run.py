"""Run Melody from source on this desktop, isolated from your real library.

    uv run melody-run
    uv run melody-run --fresh
    uv run melody-run --layout mobile
    uv run melody-run --layout mobile --size small-phone
    uv run melody-run -- --release

The worker runs in its development interpreter (``worker/.venv``) over stdio,
FFmpeg comes from the verified bundle in ``app/media``, and all state and the
default music folder live in ``build/dev-data`` unless ``--data-dir`` says
otherwise. ``--layout mobile`` shows the phone UI in a phone-sized window and
``--size`` sets the window to another device (``tablet``, ``phone-landscape``,
...) or to WIDTHxHEIGHT, so every presentation can be tried on this desktop.
Arguments after ``--`` go to ``flutter run``.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from tools.common import (
    APP,
    DEV_DATA,
    child_environment,
    executable,
    host_platform,
    load_env_file,
    split_passthrough,
)
from tools.dev.env import add_display_arguments, dev_environment, display_environment


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-run",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--device",
        default=host_platform(),
        help="Flutter desktop device (default: this machine)",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=DEV_DATA,
        help=f"Application state and default music folder (default: {DEV_DATA})",
    )
    parser.add_argument(
        "--fresh",
        action="store_true",
        help="Delete the data folder first, as on a first launch",
    )
    parser.add_argument(
        "--no-media", action="store_true", help="Run without FFmpeg (no downloads)"
    )
    add_display_arguments(parser)
    own, flutter_arguments = split_passthrough(sys.argv[1:] if argv is None else argv)
    arguments = parser.parse_args(own)
    load_env_file()
    data = arguments.data_dir.resolve()
    if arguments.fresh:
        shutil.rmtree(data, ignore_errors=True)
    overrides = dev_environment(data, media=not arguments.no_media)
    overrides.update(display_environment(arguments.layout, arguments.size))
    for key, value in overrides.items():
        print(f"{key}={value}")
    command = [
        executable("flutter"),
        "run",
        "-d",
        arguments.device,
        *flutter_arguments,
    ]
    print("+", " ".join(command), flush=True)
    try:
        completed = subprocess.run(
            command, cwd=APP, env=child_environment(overrides), check=False
        )
        raise SystemExit(completed.returncode)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
