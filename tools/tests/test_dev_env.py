from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from argparse import ArgumentTypeError
from pathlib import Path
from unittest import mock

from tools.common import child_environment, find_executable, split_passthrough
from tools.dev.env import dev_environment, display_environment, render, window_size

_which = shutil.which  # the real one, before tests patch it


class RenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = {"MELODY_DATA_DIR": "C:\\it's here"}

    def test_powershell_doubles_single_quotes(self) -> None:
        self.assertEqual(
            render(self.environment, "powershell"),
            "$env:MELODY_DATA_DIR = 'C:\\it''s here'",
        )

    def test_bash_closes_and_escapes_single_quotes(self) -> None:
        self.assertEqual(
            render(self.environment, "bash"),
            "export MELODY_DATA_DIR='C:\\it'\\''s here'",
        )

    def test_cmd_quotes_the_assignment(self) -> None:
        self.assertEqual(
            render(self.environment, "cmd"), 'set "MELODY_DATA_DIR=C:\\it\'s here"'
        )


class DevEnvironmentTests(unittest.TestCase):
    def test_points_the_app_at_the_worker_media_and_data(self) -> None:
        with (
            mock.patch("tools.dev.env.worker_python", return_value=Path("py")),
            mock.patch(
                "tools.dev.env.fetch_bundle", return_value=Path("media")
            ) as fetch,
        ):
            environment = dev_environment(Path("data"))

        fetch.assert_called_once()
        self.assertEqual(environment["MELODY_WORKER_PYTHON"], "py")
        self.assertEqual(environment["MELODY_FFMPEG_DIR"], "media")
        self.assertEqual(environment["MELODY_DATA_DIR"], "data")
        self.assertTrue(environment["MELODY_WORKER_SOURCE"].endswith("src"))

    def test_without_media_or_data_neither_is_set(self) -> None:
        with (
            mock.patch("tools.dev.env.worker_python", return_value=Path("py")),
            mock.patch("tools.dev.env.fetch_bundle") as fetch,
        ):
            environment = dev_environment(None, media=False)

        fetch.assert_not_called()
        self.assertEqual(
            set(environment), {"MELODY_WORKER_PYTHON", "MELODY_WORKER_SOURCE"}
        )


class DisplayTests(unittest.TestCase):
    def test_mobile_layout_defaults_to_a_phone_window(self) -> None:
        self.assertEqual(
            display_environment("mobile", None),
            {"MELODY_LAYOUT": "mobile", "MELODY_WINDOW_SIZE": "390x844"},
        )

    def test_size_alone_keeps_the_platform_layout(self) -> None:
        self.assertEqual(
            display_environment(None, window_size("1040x700")),
            {"MELODY_WINDOW_SIZE": "1040x700"},
        )
        self.assertEqual(display_environment(None, None), {})

    def test_window_size_accepts_devices_and_dimensions(self) -> None:
        self.assertEqual(window_size("tablet"), (820, 1180))
        self.assertEqual(window_size("844X390"), (844, 390))
        for invalid in ("watch", "390", "0x844", "-1x5", "axb"):
            with self.subTest(invalid), self.assertRaises(ArgumentTypeError):
                window_size(invalid)


class CommonTests(unittest.TestCase):
    def test_split_passthrough(self) -> None:
        self.assertEqual(
            split_passthrough(["apk", "--", "--verbose", "--"]),
            (["apk"], ["--verbose", "--"]),
        )
        self.assertEqual(split_passthrough(["apk"]), (["apk"], []))

    def test_child_environment_drops_the_tools_virtual_env(self) -> None:
        with mock.patch.dict(os.environ, {"VIRTUAL_ENV": "x", "KEEP": "1"}):
            environment = child_environment({"ADDED": "2"})

        self.assertNotIn("VIRTUAL_ENV", environment)
        self.assertEqual((environment["KEEP"], environment["ADDED"]), ("1", "2"))

    def test_flutter_is_found_through_flutter_root(self) -> None:
        with tempfile.TemporaryDirectory() as sdk:
            name = "flutter.bat" if os.name == "nt" else "flutter"
            program = Path(sdk, "bin", name)
            program.parent.mkdir()
            program.write_text("")
            program.chmod(0o755)
            with (
                mock.patch.dict(os.environ, {"FLUTTER_ROOT": sdk}),
                mock.patch("tools.common.shutil.which", wraps=_which_only_in_sdk),
            ):
                found = find_executable("flutter")

        self.assertEqual(Path(found or "").resolve(), program.resolve())

    @unittest.skipUnless(os.name == "nt", "PATHEXT spelling is Windows-only")
    def test_windows_extension_is_lowercased_for_dart_hooks(self) -> None:
        with mock.patch(
            "tools.common.shutil.which", return_value=r"C:\sdk\bin\dart.EXE"
        ):
            found = find_executable("dart")

        self.assertEqual(found, r"C:\sdk\bin\dart.exe")


def _which_only_in_sdk(name: str, path: str | None = None) -> str | None:
    """shutil.which, but nothing on PATH (the SDK is passed as ``path``)."""
    return _which(name, path=path) if path else None


if __name__ == "__main__":
    unittest.main()
