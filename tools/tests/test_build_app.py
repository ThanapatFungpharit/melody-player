from __future__ import annotations

import ast
import fnmatch
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.build.app import (
    ANDROID_EXTRACT_PACKAGES,
    PACKAGE_RETRY_DELAYS,
    collect,
    discard_incomplete_macos_runtime,
    package_worker,
    python_environment,
    serious_python_darwin,
)
from tools.common import APP, WORKER

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


class SeriousPythonVersionTests(unittest.TestCase):
    def test_platform_packages_match_the_pinned_version(self) -> None:
        # serious_python only constrains its platform packages with ^, so a lock
        # refresh can move them past the packaging command they work with.
        pinned = re.search(
            r"^  serious_python: (\S+)$",
            (APP / "pubspec.yaml").read_text("utf-8"),
            re.MULTILINE,
        )
        assert pinned is not None
        locked = dict(
            re.findall(
                r'^  (serious_python\w*):\n(?:    .*\n)*?    version: "([^"]+)"$',
                (APP / "pubspec.lock").read_text("utf-8"),
                re.MULTILINE,
            )
        )
        self.assertIn("serious_python_darwin", locked)
        self.assertEqual(locked, dict.fromkeys(locked, pinned[1]))


class MacosRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.darwin = self.root / "darwin"
        self.cache = self.root / "cache"
        self.archives = [
            self.cache / "python-build" / "v1" / "python-macos-dart-1.tar.gz",
            self.cache / "dart-bridge" / "v1" / "dart_bridge-apple.xcframework.zip",
        ]
        for archive in self.archives:
            archive.parent.mkdir(parents=True)
            archive.touch()

    def make_runtime(self, *names: str) -> None:
        for name in names:
            (self.darwin / "dist_macos" / name).mkdir(parents=True)

    def test_a_complete_runtime_is_kept(self) -> None:
        self.make_runtime(
            "stdlib",
            "xcframeworks/Python.xcframework",
            "xcframeworks/dart_bridge.xcframework",
        )
        discard_incomplete_macos_runtime(self.darwin, self.cache)
        self.assertTrue((self.darwin / "dist_macos" / "stdlib").is_dir())
        self.assertTrue(all(archive.is_file() for archive in self.archives))

    def test_an_incomplete_runtime_is_discarded_with_its_downloads(self) -> None:
        # What a failed download leaves: a marker that says the runtime is ready.
        self.make_runtime("site-packages")
        (self.darwin / "dist_macos" / ".python_build_id").touch()
        discard_incomplete_macos_runtime(self.darwin, self.cache)
        self.assertFalse((self.darwin / "dist_macos").exists())
        self.assertFalse(any(archive.exists() for archive in self.archives))

    def test_plugin_directory_comes_from_the_package_config(self) -> None:
        app = self.root / "app"
        config = app / ".dart_tool" / "package_config.json"
        config.parent.mkdir(parents=True)
        self.assertIsNone(serious_python_darwin(app))
        plugin = self.root / "pub cache" / "serious_python_darwin-1"
        for root_uri in (plugin.as_uri(), "../../pub%20cache/serious_python_darwin-1"):
            with self.subTest(root_uri=root_uri):
                package = {"name": "serious_python_darwin", "rootUri": root_uri}
                config.write_text(json.dumps({"packages": [package]}), "utf-8")
                found = serious_python_darwin(app)
                assert found is not None
                self.assertEqual(found.resolve(), (plugin / "darwin").resolve())


class PackageWorkerTests(unittest.TestCase):
    def package(self, target: str, failures: int) -> tuple[int, int, list[float]]:
        """(packaging runs, macOS cleanups, pauses) when ``failures`` runs fail."""
        error = subprocess.CalledProcessError(1, ["dart"])
        with (
            mock.patch("tools.build.app.executable", side_effect=str),
            mock.patch("tools.build.app.worker_requirements", return_value=[]),
            mock.patch(
                "tools.build.app.run", side_effect=[error] * failures + [0]
            ) as run,
            mock.patch("tools.build.app.clean_macos_runtime") as clean,
            mock.patch("tools.build.app.time.sleep") as sleep,
        ):
            package_worker(target, [], {})
        pauses = [call.args[0] for call in sleep.call_args_list]
        return run.call_count, clean.call_count, pauses

    def test_a_passing_failure_is_retried_after_cleaning_up(self) -> None:
        self.assertEqual(self.package("macos", 1), (2, 2, [PACKAGE_RETRY_DELAYS[0]]))

    def test_other_targets_do_not_touch_the_macos_runtime(self) -> None:
        self.assertEqual(self.package("linux", 0), (1, 0, []))

    def test_a_lasting_failure_fails_the_build(self) -> None:
        with self.assertRaises(subprocess.CalledProcessError):
            self.package("linux", len(PACKAGE_RETRY_DELAYS) + 1)


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
