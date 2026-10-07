from __future__ import annotations

import unittest
from unittest import mock

from tools.checks.check import Step, execute, main, plan, summary
from tools.common import APP, ROOT, WORKER


class PlanTests(unittest.TestCase):
    def test_checks_match_ci(self) -> None:
        commands = {
            (step.component, step.name): step.command
            for step in plan(["app", "worker"], fix=False, tests=True)
        }

        self.assertEqual(
            commands["app", "format"],
            (
                "dart",
                "format",
                "--output=none",
                "--set-exit-if-changed",
                "lib",
                "test",
                "integration_test",
            ),
        )
        self.assertEqual(commands["app", "test"], ("flutter", "test"))
        self.assertEqual(
            commands["worker", "lint"],
            ("uv", "run", "--locked", "ruff", "check", "src", "tests"),
        )
        self.assertEqual(
            commands["worker", "format"],
            ("uv", "run", "--locked", "ruff", "format", "--check", "src", "tests"),
        )
        self.assertEqual(
            commands["worker", "types"],
            ("uv", "run", "--locked", "ty", "check", "src", "tests"),
        )

    def test_fix_applies_changes_and_no_tests_drops_test_steps(self) -> None:
        steps = plan(["app", "tools"], fix=True, tests=False)
        commands = {(step.component, step.name): step.command for step in steps}

        self.assertEqual(
            commands["app", "format"],
            ("dart", "format", "lib", "test", "integration_test"),
        )
        self.assertIn("--fix", commands["tools", "lint"])
        self.assertNotIn("--check", commands["tools", "format"])
        self.assertNotIn("test", {step.name for step in steps})

    def test_steps_run_in_their_project(self) -> None:
        cwd = {
            step.component: step.cwd
            for step in plan(["app", "worker", "tools"], fix=False, tests=False)
        }

        self.assertEqual(cwd, {"app": APP, "worker": WORKER, "tools": ROOT})


class ExecuteTests(unittest.TestCase):
    def steps(self) -> list[Step]:
        return [
            Step("app", "dependencies", ("flutter", "pub", "get"), APP),
            Step("app", "analyze", ("flutter", "analyze"), APP),
            Step("tools", "lint", ("uv", "run", "ruff"), ROOT),
            Step("tools", "test", ("uv", "run", "pytest"), ROOT),
        ]

    def test_missing_tool_fails_its_component_and_others_still_run(self) -> None:
        def find(name: str) -> str | None:
            return None if name == "flutter" else name

        with (
            mock.patch("tools.checks.check.find_executable", side_effect=find),
            mock.patch("tools.checks.check.subprocess.run") as run,
        ):
            run.return_value.returncode = 0
            outcomes = execute(self.steps(), fail_fast=False)

        self.assertEqual(
            [outcome.status for outcome in outcomes],
            ["failed", "skipped", "passed", "passed"],
        )
        self.assertIn("flutter not found", outcomes[0].detail)
        self.assertEqual(run.call_count, 2)

    def test_fail_fast_skips_everything_after_a_failure(self) -> None:
        with (
            mock.patch("tools.checks.check.find_executable", side_effect=str),
            mock.patch("tools.checks.check.subprocess.run") as run,
        ):
            run.return_value.returncode = 1
            outcomes = execute(self.steps(), fail_fast=True)

        self.assertEqual(
            [outcome.status for outcome in outcomes],
            ["failed", "skipped", "skipped", "skipped"],
        )
        self.assertIn("1 failed", summary(outcomes))

    def test_main_exits_nonzero_when_a_step_fails(self) -> None:
        with (
            mock.patch("tools.checks.check.find_executable", side_effect=str),
            mock.patch("tools.checks.check.subprocess.run") as run,
            mock.patch("builtins.print"),
        ):
            run.return_value.returncode = 1
            with self.assertRaises(SystemExit) as raised:
                main(["tools", "--no-tests"])

        self.assertEqual(raised.exception.code, 1)

    def test_unknown_component_is_rejected(self) -> None:
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit) as raised:
            main(["bogus"])

        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
