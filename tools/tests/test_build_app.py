from __future__ import annotations

import ast
import fnmatch
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.build.app import ANDROID_EXTRACT_PACKAGES, collect, python_environment
from tools.common import WORKER

EXTRACT_VARIABLE = "SERIOUS_PYTHON_ANDROID_EXTRACT_PACKAGES"


def _unzippable_packages() -> list[tuple[str, str]]:
    """(distribution, module) of every RuntimePackage the worker declares
    ``zip_safe=False``. Parsed, because the tools cannot import the worker's
    dependencies."""
    source = (WORKER / "src" / "melody_worker" / "updater" / "packages.py").read_text(
        "utf-8"
    )
    packages = []
    for node in ast.walk(ast.parse(source)):
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "RuntimePackage"
        ):
            continue
        keywords = {
            keyword.arg: keyword.value
            for keyword in node.keywords
            if keyword.arg is not None
        }
        zip_safe = keywords.get("zip_safe")
        if isinstance(zip_safe, ast.Constant) and zip_safe.value is False:
            packages.append(
                (
                    ast.literal_eval(keywords["distribution"]),
                    ast.literal_eval(keywords["module"]),
                )
            )
    return packages


class PythonEnvironmentTests(unittest.TestCase):
    def test_android_unpacks_packages_that_read_their_data_files(self) -> None:
        packages = _unzippable_packages()
        self.assertIn(("ytmusicapi", "ytmusicapi"), packages)
        for distribution, module in packages:
            dist_info = f"{distribution.replace('-', '_')}-1.0.dist-info"
            for entry in (module, dist_info):
                with self.subTest(entry=entry):
                    self.assertTrue(
                        any(
                            fnmatch.fnmatchcase(entry, pattern)
                            for pattern in ANDROID_EXTRACT_PACKAGES
                        ),
                        f"{entry} would stay in sitepackages.zip on Android",
                    )

    def test_only_android_builds_set_the_extract_list(self) -> None:
        staging = Path("staging")
        for target in ("apk", "aab"):
            with self.subTest(target=target):
                env = python_environment(target, staging)
                self.assertEqual(
                    env[EXTRACT_VARIABLE].split(","), list(ANDROID_EXTRACT_PACKAGES)
                )
                self.assertEqual(
                    env["SERIOUS_PYTHON_SITE_PACKAGES"],
                    str(staging / "site-packages"),
                )
        for target in ("windows", "linux", "macos"):
            with self.subTest(target=target):
                self.assertNotIn(EXTRACT_VARIABLE, python_environment(target, staging))


class CollectTests(unittest.TestCase):
    def test_desktop_output_follows_the_architecture(self) -> None:
        layouts = {
            "windows": ("runner", "Release"),
            "linux": ("release", "bundle"),
        }
        for target, tail in layouts.items():
            for architecture, folder in (("x86_64", "x64"), ("arm64", "arm64")):
                with (
                    self.subTest(target=target, architecture=architecture),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = Path(directory)
                    built = root / "app" / "build" / target / folder / Path(*tail)
                    built.mkdir(parents=True)
                    (built / "melody").write_text(architecture, encoding="utf-8")
                    with (
                        mock.patch("tools.build.app.ROOT", root),
                        mock.patch("tools.build.app.APP", root / "app"),
                    ):
                        output = collect(target, "1.0.0", architecture)
                    self.assertEqual(
                        (output / "melody").read_text(encoding="utf-8"), architecture
                    )


if __name__ == "__main__":
    unittest.main()
