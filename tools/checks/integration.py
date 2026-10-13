"""Run the network integration tests with the environment they need.

    uv run melody-integration                 # both suites
    uv run melody-integration worker          # app/test/integration
    uv run melody-integration app --screenshots build/screens

``worker`` drives the real Python worker against YouTube Music (search and a
full download). ``app`` launches the real desktop app from
``app/integration_test`` against a new, empty data folder that is deleted
afterwards unless ``--keep-data`` is given. Both need network access; they use
the worker's development interpreter and the verified FFmpeg bundle.
Arguments after ``--`` go to ``flutter test``.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from tools.common import (
    APP,
    child_environment,
    executable,
    host_platform,
    load_env_file,
    split_passthrough,
)
from tools.dev.env import dev_environment

SUITES = ("worker", "app")


def command(suite: str, device: str, extra: list[str]) -> list[str]:
    if suite == "worker":
        return ["flutter", "test", "test/integration", "--tags", "network", *extra]
    return ["flutter", "test", "integration_test", "-d", device, *extra]


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-integration",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "suites",
        nargs="*",
        metavar="SUITE",
        help=f"Any of {', '.join(SUITES)} (default: all)",
    )
    parser.add_argument(
        "--device",
        default=host_platform(),
        help="Desktop device for the app suite (default: this machine)",
    )
    parser.add_argument(
        "--screenshots", type=Path, help="Write the app suite's PNGs here"
    )
    parser.add_argument(
        "--keep-data",
        action="store_true",
        help="Keep the app suite's data folder for inspection",
    )
    own, extra = split_passthrough(sys.argv[1:] if argv is None else argv)
    arguments = parser.parse_args(own)
    if unknown := sorted(set(arguments.suites) - set(SUITES)):
        parser.error(f"unknown suite {', '.join(unknown)}")
    load_env_file()
    suites = [s for s in SUITES if s in arguments.suites] or list(SUITES)

    flutter = executable("flutter")
    base = dev_environment(None)
    failed: list[str] = []
    for suite in suites:
        overrides = dict(base)
        data: Path | None = None
        if suite == "app":
            data = Path(tempfile.mkdtemp(prefix="melody-integration-"))
            overrides["MELODY_DATA_DIR"] = str(data)
            if arguments.screenshots:
                overrides["MELODY_SCREENSHOT_DIR"] = str(
                    arguments.screenshots.resolve()
                )
        line = command(suite, arguments.device, extra)
        print(f"\n== {suite}\n+ {' '.join(line)}", flush=True)
        try:
            code = subprocess.run(
                [flutter, *line[1:]],
                cwd=APP,
                env=child_environment(overrides),
                check=False,
            ).returncode
        finally:
            if data is not None:
                if arguments.keep_data:
                    print(f"Kept the app suite's data in {data}")
                else:
                    shutil.rmtree(data, ignore_errors=True)
        if code:
            failed.append(suite)
    if failed:
        raise SystemExit(f"Failed: {', '.join(failed)}")
    print("\nIntegration tests passed")


if __name__ == "__main__":
    main()
