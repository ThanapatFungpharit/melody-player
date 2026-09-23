from __future__ import annotations

import asyncio
import unittest

from musicplayer.core.concurrency import LazyBoundedExecutor
from musicplayer.ui.tasks import PageTasks


class _Page:
    pass


class PageTasksTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.errors: list[str] = []
        self.workers = LazyBoundedExecutor(max_workers=1, max_pending=1)
        self.tasks = PageTasks(_Page(), self.workers, self.errors.append)

    async def asyncTearDown(self) -> None:
        self.tasks.close()
        self.workers.shutdown(wait=True, cancel_pending=True)

    async def _wait_for_jobs(self) -> None:
        jobs = tuple(self.tasks._jobs.values())
        if jobs:
            await asyncio.gather(*jobs)

    async def test_distinct_arguments_run_as_independent_actions(self) -> None:
        release = asyncio.Event()
        started: list[str] = []

        async def action(item_id: str) -> None:
            started.append(item_id)
            await release.wait()

        self.tasks.start(action, "first")
        self.tasks.start(action, "second")
        await asyncio.sleep(0)

        self.assertCountEqual(started, ["first", "second"])
        release.set()
        await self._wait_for_jobs()

    async def test_duplicate_action_is_still_suppressed(self) -> None:
        release = asyncio.Event()
        started: list[str] = []

        async def action(item_id: str) -> None:
            started.append(item_id)
            await release.wait()

        self.tasks.start(action, "same")
        self.tasks.start(action, "same")
        await asyncio.sleep(0)

        self.assertEqual(started, ["same"])
        release.set()
        await self._wait_for_jobs()

    async def test_completion_callback_errors_reach_failure_handler(self) -> None:
        def fail_completion(_: object) -> None:
            raise ValueError("completion failed")

        with self.assertLogs("musicplayer.ui.tasks", level="ERROR"):
            self.assertTrue(
                self.tasks.submit(
                    lambda: 42,
                    fail_completion,
                    failed=self.errors.append,
                )
            )
            await self._wait_for_jobs()

        self.assertEqual(self.errors, ["completion failed"])


if __name__ == "__main__":
    unittest.main()
