from __future__ import annotations

import ast
import re
import unittest

from tools.common import APP, WORKER


def _worker_windows() -> dict[str, str]:
    """distribution → ``allowed`` specifier of every RuntimePackage the worker
    declares. Parsed, because the tools cannot import the worker's
    dependencies."""
    source = (WORKER / "src" / "melody_worker" / "updater" / "packages.py").read_text(
        "utf-8"
    )
    windows = {}
    for node in ast.walk(ast.parse(source)):
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "RuntimePackage"
        ):
            continue
        keywords = {k.arg: k.value for k in node.keywords if k.arg is not None}
        allowed = keywords["allowed"]
        assert isinstance(allowed, ast.Call) and allowed.args
        windows[ast.literal_eval(keywords["distribution"])] = ast.literal_eval(
            allowed.args[0]
        )
    return windows


def _app_windows() -> dict[str, str]:
    """label → ``allowed`` of every RuntimePackageInfo the app declares. Each
    label is the PyPI distribution name."""
    source = (APP / "lib" / "application" / "package_runtime.dart").read_text("utf-8")
    windows = {}
    for body in re.findall(r"RuntimePackageInfo\((.*?)\);", source, re.DOTALL):
        label = re.search(r'label: "([^"]+)"', body)
        allowed = re.search(r'allowed: "([^"]+)"', body)
        if label and allowed:
            windows[label.group(1)] = allowed.group(1)
    return windows


class RuntimePackageTests(unittest.TestCase):
    def test_settings_name_the_versions_the_worker_accepts(self) -> None:
        worker = _worker_windows()
        self.assertEqual(set(worker), {"yt-dlp", "ytmusicapi"})
        self.assertEqual(_app_windows(), worker)


if __name__ == "__main__":
    unittest.main()
