"""Run the format, lint, type, and test checks CI runs, for any components.

    uv run melody-check                 # everything
    uv run melody-check worker tools    # only the Python projects
    uv run melody-check app --no-tests  # format and analyze the app
    uv run melody-check --fix           # apply formatting and safe lint fixes
    uv run melody-check --list          # print the commands without running

Components: ``audio`` (packages/melody_audio), ``app``, ``worker``, and
``tools``. Every component runs even when an earlier one fails, unless
``--fail-fast`` is given; a summary lists each step's result at the end.
Flutter is found on PATH or in ``FLUTTER_ROOT/bin``.
"""

from __future__ import annotations

import argparse
import subprocess
import time
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

from tools.common import (
    APP,
    AUDIO_PLUGIN,
    ROOT,
    WORKER,
    child_environment,
    find_executable,
    load_env_file,
)

COMPONENTS = ("audio", "app", "worker", "tools")
_DART_SOURCES = {
    "audio": ("lib", "test"),
    "app": ("lib", "test", "integration_test"),
}
_PYTHON_SOURCES = {"worker": ("src", "tests"), "tools": ("tools",)}


@dataclass(frozen=True)
class Step:
    component: str
    name: str
    command: tuple[str, ...]
    cwd: Path

    def __str__(self) -> str:
        return f"({self.cwd.relative_to(ROOT).as_posix() or '.'}) " + " ".join(
            self.command
        )


@dataclass(frozen=True)
class Outcome:
    step: Step
    status: str  # "passed", "failed", or "skipped"
    seconds: float = 0.0
    detail: str = ""


def plan(components: Iterable[str], *, fix: bool, tests: bool) -> list[Step]:
    steps: list[Step] = []
    for component in components:
        if component in {"audio", "app"}:
            cwd = AUDIO_PLUGIN if component == "audio" else APP
            check = () if fix else ("--output=none", "--set-exit-if-changed")
            steps += [
                Step(component, "dependencies", ("flutter", "pub", "get"), cwd),
                Step(
                    component,
                    "format",
                    ("dart", "format", *check, *_DART_SOURCES[component]),
                    cwd,
                ),
                Step(component, "analyze", ("flutter", "analyze"), cwd),
            ]
            if tests:
                steps.append(Step(component, "test", ("flutter", "test"), cwd))
            continue
        cwd = WORKER if component == "worker" else ROOT
        sources = _PYTHON_SOURCES[component]
        uv_run = ("uv", "run", "--locked")
        steps += [
            Step(component, "dependencies", ("uv", "sync", "--locked"), cwd),
            Step(
                component,
                "format",
                (*uv_run, "ruff", "format", *(() if fix else ("--check",)), *sources),
                cwd,
            ),
            Step(
                component,
                "lint",
                (*uv_run, "ruff", "check", *(("--fix",) if fix else ()), *sources),
                cwd,
            ),
            Step(component, "types", (*uv_run, "ty", "check", *sources), cwd),
        ]
        if tests:
            steps.append(Step(component, "test", (*uv_run, "pytest", "-q"), cwd))
        if component == "tools":
            steps.append(Step(component, "version", (*uv_run, "melody-version"), cwd))
    return steps


def execute(steps: Sequence[Step], *, fail_fast: bool) -> list[Outcome]:
    outcomes: list[Outcome] = []
    broken: set[str] = set()  # components whose dependencies failed
    stop = False
    for step in steps:
        if stop or step.component in broken:
            reason = "earlier failure" if stop else "dependencies failed"
            outcomes.append(Outcome(step, "skipped", detail=reason))
            continue
        program = find_executable(step.command[0])
        if program is None:
            hint = (
                " (or set FLUTTER_ROOT)"
                if step.command[0] in {"flutter", "dart"}
                else ""
            )
            outcomes.append(
                Outcome(step, "failed", detail=f"{step.command[0]} not found{hint}")
            )
        else:
            print(f"\n== {step.component}: {step.name}\n+ {step}", flush=True)
            started = time.monotonic()
            code = subprocess.run(
                [program, *step.command[1:]],
                cwd=step.cwd,
                env=child_environment(),
                check=False,
            ).returncode
            outcomes.append(
                Outcome(
                    step,
                    "passed" if code == 0 else "failed",
                    time.monotonic() - started,
                    "" if code == 0 else f"exit code {code}",
                )
            )
        if outcomes[-1].status == "failed":
            if step.name == "dependencies" or program is None:
                broken.add(step.component)
            stop = fail_fast
    return outcomes


def summary(outcomes: Sequence[Outcome]) -> str:
    marks = {"passed": "ok", "failed": "FAIL", "skipped": "skip"}
    lines = ["", "Summary"]
    for outcome in outcomes:
        timing = f"{outcome.seconds:6.1f}s" if outcome.status != "skipped" else " " * 7
        detail = f"  {outcome.detail}" if outcome.detail else ""
        lines.append(
            f"  {marks[outcome.status]:<5}{outcome.step.component:<8}"
            f"{outcome.step.name:<14}{timing}{detail}"
        )
    failed = sum(outcome.status == "failed" for outcome in outcomes)
    lines.append(f"\n{failed} failed" if failed else "\nAll checks passed")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-check",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "components",
        nargs="*",
        metavar="COMPONENT",
        help=f"Any of {', '.join(COMPONENTS)} (default: all)",
    )
    parser.add_argument(
        "--fix", action="store_true", help="Apply formatting and safe lint fixes"
    )
    parser.add_argument(
        "--no-tests", action="store_true", help="Only format, lint, and analyze"
    )
    parser.add_argument(
        "--fail-fast", action="store_true", help="Stop at the first failure"
    )
    parser.add_argument(
        "--list", action="store_true", help="Print the commands without running"
    )
    arguments = parser.parse_args(argv)
    if unknown := sorted(set(arguments.components) - set(COMPONENTS)):
        parser.error(f"unknown component {', '.join(unknown)}")
    load_env_file()
    selected = [c for c in COMPONENTS if c in arguments.components] or COMPONENTS
    steps = plan(selected, fix=arguments.fix, tests=not arguments.no_tests)
    if arguments.list:
        for step in steps:
            print(f"{step.component:<8}{step.name:<14}{step}")
        return
    outcomes = execute(steps, fail_fast=arguments.fail_fast)
    print(summary(outcomes))
    if any(outcome.status == "failed" for outcome in outcomes):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
