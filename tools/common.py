"""Paths and process helpers shared by Melody's tools."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
WORKER = ROOT / "worker"
AUDIO_PLUGIN = ROOT / "packages" / "melody_audio"
MEDIA = APP / "media"
# Throwaway application state for running the app from source.
DEV_DATA = ROOT / "build" / "dev-data"
# Local settings every tool loads, such as FLUTTER_ROOT and JAVA_HOME.
ENV_FILE = ROOT / ".env"
# Android release signing secrets, read only by the steps that sign.
SIGNING_FILE = ROOT / ".signing"

# Tools that ship in the Flutter SDK, found through FLUTTER_ROOT when the SDK
# is not on PATH.
_FLUTTER_TOOLS = frozenset({"flutter", "dart"})


def find_executable(name: str) -> str | None:
    found = shutil.which(name) or shutil.which(f"{name}.bat")
    sdk = os.environ.get("FLUTTER_ROOT")
    if found is None and name in _FLUTTER_TOOLS and sdk:
        bin_directory = str(Path(sdk) / "bin")
        found = shutil.which(name, path=bin_directory) or shutil.which(
            f"{name}.bat", path=bin_directory
        )
    java = os.environ.get("JAVA_HOME")
    if found is None and name == "keytool" and java:
        found = shutil.which(name, path=str(Path(java) / "bin"))
    return found


def executable(name: str) -> str:
    found = find_executable(name)
    if found is None:
        hint = " (or set FLUTTER_ROOT)" if name in _FLUTTER_TOOLS else ""
        raise SystemExit(f"{name} was not found on PATH{hint}")
    return found


def child_environment(
    overrides: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """This process's environment for a child, plus ``overrides``.

    ``uv run`` exports the tools' VIRTUAL_ENV, which would make ``uv`` in the
    worker project warn and point Python tools at the wrong interpreter.
    """
    environment = {
        key: value for key, value in os.environ.items() if key != "VIRTUAL_ENV"
    }
    environment.update(overrides or {})
    return environment


def run(
    command: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str] | None = None,
    check: bool = True,
) -> int:
    print("+", " ".join(command), flush=True)
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        env=dict(env) if env is not None else None,
        check=False,
    )
    if check and completed.returncode:
        raise subprocess.CalledProcessError(completed.returncode, list(command))
    return completed.returncode


def split_passthrough(argv: Sequence[str]) -> tuple[list[str], list[str]]:
    """Split ``argv`` at ``--``: (this tool's arguments, the wrapped tool's)."""
    arguments = list(argv)
    if "--" not in arguments:
        return arguments, []
    split = arguments.index("--")
    return arguments[:split], arguments[split + 1 :]


def read_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE lines of a dotenv-style file; empty if it does not exist."""
    if not path.is_file():
        return {}
    values = {}
    for line in path.read_text("utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.removeprefix("export ").split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        values[key.strip()] = value
    return values


def load_env_file(path: Path = ENV_FILE) -> None:
    """Export ``path``'s variables; values already exported in the shell win."""
    for key, value in read_env_file(path).items():
        os.environ.setdefault(key, value)


def host_platform() -> str:
    """This machine's Flutter desktop device and media bundle name."""
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def host_architecture() -> str:
    machine = platform.machine().casefold()
    return "arm64" if machine in {"arm64", "aarch64"} else "x86_64"


def worker_python(*, sync: bool = True) -> Path:
    """The worker's development interpreter, synced to ``worker/uv.lock``."""
    if sync:
        subprocess.run(
            [executable("uv"), "sync", "--locked", "--quiet"],
            cwd=WORKER,
            env=child_environment(),
            stdout=subprocess.DEVNULL,
            check=True,
        )
    scripts = "Scripts/python.exe" if os.name == "nt" else "bin/python"
    python = WORKER / ".venv" / scripts
    if not python.is_file():
        raise SystemExit(f"The worker interpreter is missing: {python}")
    return python
