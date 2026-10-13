from __future__ import annotations

import gzip
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import Mock, patch

from packaging.version import Version

from melody_worker.updater import (
    YT_DLP,
    YTMUSICAPI,
    PackageUpdater,
    RemoteRelease,
    UpdateResult,
    WheelRecord,
    package_updater,
    probing,
)
from melody_worker.updater import remote as pypi


class YtDlpUpdaterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.imported_modules = {
            name: module
            for name, module in sys.modules.items()
            if name == "yt_dlp" or name.startswith("yt_dlp.")
        }
        for name in self.imported_modules:
            sys.modules.pop(name)
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.storage = root / "runtime"
        self.sources = root / "sources"
        self.sources.mkdir()

    def tearDown(self) -> None:
        storage_prefix = str(self.storage.resolve())
        sys.path[:] = [
            entry
            for entry in sys.path
            if not str(entry).casefold().startswith(storage_prefix.casefold())
        ]
        self.temporary_directory.cleanup()
        sys.modules.update(self.imported_modules)

    def test_downloads_only_newer_release_and_activates_verified_wheel(self) -> None:
        source = _make_wheel(self.sources, "2026.9.12")
        remote = _remote(source, "2026.9.12")
        downloads: list[str] = []

        def download(_url: str, destination: Path) -> None:
            downloads.append(destination.name)
            shutil.copyfile(source, destination)

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: remote,
            download=download,
        ).prepare()

        self.assertTrue(result.updated)
        self.assertEqual(result.active_source, "runtime")
        self.assertEqual(result.active_version, "2026.9.12")
        self.assertEqual(result.current_version, "2026.9.12")
        self.assertIsNone(result.previous_version)
        self.assertEqual(len(downloads), 1)
        self.assertEqual(Path(sys.path[0]), self.storage / source.name)
        self.assertEqual(
            json.loads((self.storage / "state.json").read_text()),
            {
                "schema": 2,
                "pending": None,
                "failed": None,
                "current": {
                    "filename": source.name,
                    "sha256": _sha256(source),
                    "version": "2026.9.12",
                },
                "previous": None,
            },
        )

    def test_does_not_download_when_remote_is_not_newer(self) -> None:
        current = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.12"), None)
        download = Mock()

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: _remote(
                _make_wheel(self.sources, "2026.9.11"), "2026.9.11"
            ),
            download=download,
        ).prepare()

        self.assertFalse(result.updated)
        self.assertEqual(result.active_version, "2026.9.12")
        download.assert_not_called()

    def test_unchanged_state_is_not_rewritten(self) -> None:
        current = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.12"), None)
        updater = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            check_remote=False,
        )
        updater.prepare()  # migrates the schema 1 state
        replace = Mock(wraps=os.replace)

        with patch.object(package_updater.os, "replace", replace):
            result = updater.prepare()

        self.assertEqual(result.active_version, "2026.9.12")
        self.assertFalse(result.recovered)
        replace.assert_not_called()

    def test_current_corruption_rolls_back_to_previous(self) -> None:
        current = self.storage / "yt_dlp-2026.9.12-py3-none-any.whl"
        self.storage.mkdir(parents=True)
        current.write_bytes(b"not a wheel")
        trusted_hash = _sha256(current)
        previous = _make_wheel(self.storage, "2026.9.08")
        _write_state(
            self.storage,
            WheelRecord(Version("2026.9.12"), current.name, trusted_hash),
            _record(previous, "2026.9.08"),
        )
        # The current hash in state is intentionally wrong for the bytes in the
        # package after the state transaction.
        current.write_bytes(b"corrupted after state commit")

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertTrue(result.rolled_back)
        self.assertEqual(result.active_version, "2026.9.8")
        self.assertEqual(result.current_version, "2026.9.8")
        self.assertIsNone(result.previous_version)
        self.assertFalse(current.exists())
        self.assertEqual(Path(sys.path[0]), previous)

    def test_both_corrupt_runtime_packages_fall_back_and_reset_state(self) -> None:
        current = self.storage / "yt_dlp-2026.9.12-py3-none-any.whl"
        previous = self.storage / "yt_dlp-2026.9.08-py3-none-any.whl"
        self.storage.mkdir(parents=True)
        current.write_bytes(b"bad current")
        previous.write_bytes(b"bad previous")
        _write_state(
            self.storage,
            WheelRecord(Version("2026.9.12"), current.name, "0" * 64),
            WheelRecord(Version("2026.9.08"), previous.name, "1" * 64),
        )

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertEqual(result.active_source, "bundled")
        self.assertEqual(result.active_version, "2026.8.19")
        self.assertTrue(result.recovered)
        self.assertFalse(current.exists())
        self.assertFalse(previous.exists())
        state = json.loads((self.storage / "state.json").read_text())
        self.assertIsNone(state["current"])
        self.assertIsNone(state["previous"])
        self.assertIsNotNone(state["failed"])

    def test_corrupt_state_does_not_trust_unreferenced_wheels(self) -> None:
        _make_wheel(self.storage, "2026.9.12")
        (self.storage / "state.json").write_text('{"schema": 1,', encoding="utf-8")
        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: None,
        ).prepare()
        self.assertTrue(result.recovered)
        self.assertEqual(result.active_source, "bundled")
        self.assertEqual(list(self.storage.glob("*.whl")), [])

    def test_missing_current_uses_previous_and_repairs_state(self) -> None:
        previous = _make_wheel(self.storage, "2026.9.08")
        missing = WheelRecord(
            Version("2026.9.12"),
            "yt_dlp-2026.9.12-py3-none-any.whl",
            "a" * 64,
        )
        _write_state(self.storage, missing, _record(previous, "2026.9.08"))

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertTrue(result.rolled_back)
        self.assertEqual(result.current_version, "2026.9.8")
        self.assertIsNone(result.previous_version)
        self.assertEqual(
            json.loads((self.storage / "state.json").read_text())["previous"], None
        )

    def test_hash_mismatch_and_zip_corruption_are_removed(self) -> None:
        hash_mismatch = self.storage / "yt_dlp-2026.9.12-py3-none-any.whl"
        zip_corruption = self.storage / "yt_dlp-2026.9.11-py3-none-any.whl"
        self.storage.mkdir(parents=True)
        hash_mismatch.write_bytes(b"not trusted")
        zip_corruption.write_bytes(b"not a zip")
        _write_state(
            self.storage,
            WheelRecord(Version("2026.9.12"), hash_mismatch.name, "f" * 64),
            WheelRecord(
                Version("2026.9.11"), zip_corruption.name, _sha256(zip_corruption)
            ),
        )

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertEqual(result.active_source, "bundled")
        self.assertFalse(hash_mismatch.exists())
        self.assertFalse(zip_corruption.exists())

    def test_stale_temporary_files_are_removed_on_every_launch(self) -> None:
        current = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.12"), None)
        stale_tmp = self.storage / ".yt_dlp-2026.9.13.whl.download.tmp"
        stale_part = self.storage / "state.json.part"
        stale_tmp.write_bytes(b"partial")
        stale_part.write_bytes(b"partial")

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertTrue(result.recovered)
        self.assertFalse(stale_tmp.exists())
        self.assertFalse(stale_part.exists())
        self.assertTrue(current.exists())

    def test_offline_recovery_keeps_valid_current_runtime(self) -> None:
        current = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.12"), None)

        def offline(_url: str) -> None:
            raise OSError("offline")

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=offline,
        ).prepare()

        self.assertEqual(result.active_source, "runtime")
        self.assertEqual(result.active_version, "2026.9.12")
        self.assertTrue(any("offline" in error for error in result.errors))

    def test_bundled_upgrade_removes_runtime_versions_at_or_below_bundle(self) -> None:
        old = _make_wheel(self.storage, "2026.9.08")
        _write_state(self.storage, _record(old, "2026.9.08"), None)

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.9.08",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertEqual(result.active_source, "bundled")
        self.assertFalse(old.exists())
        self.assertEqual(result.current_version, None)

    def test_failed_download_keeps_old_current_and_removes_temp(self) -> None:
        current = _make_wheel(self.storage, "2026.9.08")
        _write_state(self.storage, _record(current, "2026.9.08"), None)
        remote_source = _make_wheel(self.sources, "2026.9.12")
        remote = _remote(remote_source, "2026.9.12")

        def interrupted(_url: str, destination: Path) -> None:
            destination.write_bytes(b"partial")
            raise OSError("battery loss")

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: remote,
            download=interrupted,
        ).prepare()

        self.assertFalse(result.updated)
        self.assertEqual(result.active_version, "2026.9.8")
        self.assertTrue(current.exists())
        self.assertEqual(list(self.storage.glob("*.tmp")), [])
        self.assertTrue(any("battery loss" in error for error in result.errors))

    def test_hash_mismatched_download_is_not_activated(self) -> None:
        current = _make_wheel(self.storage, "2026.9.08")
        _write_state(self.storage, _record(current, "2026.9.08"), None)
        expected = _make_wheel(self.sources, "2026.9.12")
        wrong = _make_wheel(self.sources, "2026.9.13")
        remote = _remote(expected, "2026.9.12")

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: remote,
            download=lambda _url, destination: shutil.copyfile(wrong, destination),
        ).prepare()

        self.assertEqual(result.active_version, "2026.9.8")
        self.assertFalse(result.updated)
        self.assertTrue(current.exists())
        self.assertFalse((self.storage / expected.name).exists())

    def test_repeated_recovery_runs_converge_to_two_valid_runtime_versions(
        self,
    ) -> None:
        current = self.storage / "yt_dlp-2026.9.12-py3-none-any.whl"
        previous = self.storage / "yt_dlp-2026.9.08-py3-none-any.whl"
        self.storage.mkdir(parents=True)
        current.write_bytes(b"corrupt")
        previous.write_bytes(b"corrupt")
        _write_state(
            self.storage,
            WheelRecord(Version("2026.9.12"), current.name, "0" * 64),
            WheelRecord(Version("2026.9.08"), previous.name, "1" * 64),
        )

        first = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()
        second = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        self.assertTrue(first.recovered)
        self.assertFalse(second.recovered)
        self.assertEqual(second.active_source, "bundled")
        self.assertEqual(list(self.storage.glob("*.whl")), [])

    def test_only_current_and_previous_runtime_wheels_are_retained(self) -> None:
        wheels = [
            _make_wheel(self.storage, version)
            for version in ("2026.9.08", "2026.9.10", "2026.9.12")
        ]

        _write_state(
            self.storage,
            _record(wheels[2], "2026.9.12"),
            _record(wheels[1], "2026.9.10"),
        )
        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _url: None,
        ).prepare()

        retained = sorted(path.name for path in self.storage.glob("*.whl"))
        self.assertEqual(retained, [wheels[1].name, wheels[2].name])
        self.assertEqual(result.current_version, "2026.9.12")
        self.assertEqual(result.previous_version, "2026.9.10")

    def test_validated_transaction_is_completed_after_restart(self):
        current = _make_wheel(self.storage, "2026.9.8")
        pending = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.8"), None)
        state_path = self.storage / "state.json"
        state = json.loads(state_path.read_text())
        state.update(
            schema=2,
            pending={
                "status": "validated",
                "wheel": _record(pending, "2026.9.12").as_json(),
            },
        )
        state_path.write_text(json.dumps(state))
        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: None,
        ).prepare()
        self.assertEqual(
            (result.current_version, result.previous_version), ("2026.9.12", "2026.9.8")
        )
        self.assertIsNone(json.loads(state_path.read_text())["pending"])

    def test_downloading_transaction_never_promotes_existing_candidate(self):
        current = _make_wheel(self.storage, "2026.9.8")
        pending = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.8"), None)
        state_path = self.storage / "state.json"
        state = json.loads(state_path.read_text())
        state.update(
            schema=2,
            pending={
                "status": "downloading",
                "wheel": _record(pending, "2026.9.12").as_json(),
            },
        )
        state_path.write_text(json.dumps(state))
        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: None,
        ).prepare()
        self.assertEqual(result.current_version, "2026.9.8")
        self.assertFalse(pending.exists())
        self.assertIsNotNone(json.loads(state_path.read_text())["failed"])

    def test_healthy_zip_with_broken_import_rolls_back(self):
        old = _make_wheel(self.storage, "2026.9.8")
        broken = _make_wheel(self.storage, "2026.9.12")
        with zipfile.ZipFile(broken) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files["yt_dlp/__init__.py"] = b"raise RuntimeError('incompatible runtime')"
        with zipfile.ZipFile(broken, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        _write_state(
            self.storage, _record(broken, "2026.9.12"), _record(old, "2026.9.8")
        )
        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: None,
        ).prepare()
        self.assertTrue(result.rolled_back)
        self.assertEqual(result.current_version, "2026.9.8")
        self.assertNotIn("yt_dlp", sys.modules)

    def _prepare_counting_probes(self) -> int:
        with patch.object(
            package_updater, "probe", wraps=package_updater.probe
        ) as probe:
            PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _: None,
            ).prepare()
        for name in [name for name in sys.modules if name.startswith("yt_dlp")]:
            sys.modules.pop(name)
        return probe.call_count

    def test_probed_wheels_are_not_probed_again(self):
        current = _make_wheel(self.storage, "2026.9.12")
        previous = _make_wheel(self.storage, "2026.9.8")
        _write_state(
            self.storage, _record(current, "2026.9.12"), _record(previous, "2026.9.8")
        )
        self.assertEqual(self._prepare_counting_probes(), 2)
        self.assertEqual(self._prepare_counting_probes(), 0)

    def test_changed_bytes_or_environment_are_probed_again(self):
        current = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(current, "2026.9.12"), None)
        self.assertEqual(self._prepare_counting_probes(), 1)
        with patch.object(probing, "bundle_fingerprint", return_value="other"):
            self.assertEqual(self._prepare_counting_probes(), 1)
        # Back in the first environment, whose record was replaced.
        self.assertEqual(self._prepare_counting_probes(), 1)
        # A wheel rebuilt with other bytes under a re-trusted record.
        with zipfile.ZipFile(current, "a") as archive:
            archive.writestr("yt_dlp/extra.py", "")
        _write_state(self.storage, _record(current, "2026.9.12"), None)
        self.assertEqual(self._prepare_counting_probes(), 1)

    def test_release_outside_compatibility_window_is_not_downloaded(self):
        future = _make_wheel(self.sources, "2027.1.1")
        download = Mock()
        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: _remote(future, "2027.1.1"),
            download=download,
        ).prepare()
        self.assertEqual(result.active_source, "bundled")
        download.assert_not_called()

    def test_failed_state_commit_never_switches_the_running_package(self):
        old = _make_wheel(self.storage, "2026.9.8")
        source = _make_wheel(self.sources, "2026.9.12")
        _write_state(self.storage, _record(old, "2026.9.8"), None)
        replace = os.replace

        def fail_new_state(source_path, destination):
            if Path(destination).name == "state.json":
                state = json.loads(Path(source_path).read_text())
                if state.get("current", {}).get("version") == "2026.9.12":
                    raise OSError("disk full")
            replace(source_path, destination)

        with patch.object(package_updater.os, "replace", side_effect=fail_new_state):
            result = PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _: _remote(source, "2026.9.12"),
                download=lambda _, destination: shutil.copyfile(source, destination),
            ).prepare()
        self.assertFalse(result.updated)
        self.assertEqual(result.active_version, "2026.9.8")
        self.assertEqual(Path(sys.path[0]), old)
        self.assertTrue(old.is_file())

    def test_selection_cannot_change_after_first_import(self):
        from types import ModuleType

        with (
            patch.dict(sys.modules, {"yt_dlp": ModuleType("yt_dlp")}),
            self.assertRaisesRegex(RuntimeError, "first import"),
        ):
            PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _: None,
            ).prepare()

    def test_embedded_desktop_probes_without_relaunching_the_app(self):
        source = _make_wheel(self.storage, "2026.9.12")
        _write_state(self.storage, _record(source, "2026.9.12"), None)
        original_argv = sys.argv[:]
        with (
            patch.object(sys, "executable", "C:/Program Files/Melody/melody.exe"),
            patch.object(probing.subprocess, "run") as run,
        ):
            result = PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _: None,
            ).prepare()
        self.assertEqual(result.current_version, "2026.9.12")
        self.assertNotIn("yt_dlp", sys.modules)
        self.assertEqual(sys.argv, original_argv)
        run.assert_not_called()

    def _forget_imports(self) -> None:
        for name in [
            n for n in sys.modules if n == "yt_dlp" or n.startswith("yt_dlp.")
        ]:
            sys.modules.pop(name)

    def test_probe_timeout_during_install_is_retried_next_launch(self) -> None:
        source = _make_wheel(self.sources, "2026.9.12")
        remote = _remote(source, "2026.9.12")
        downloads: list[str] = []

        def download(_url: str, destination: Path) -> None:
            downloads.append(destination.name)
            shutil.copyfile(source, destination)

        def prepare() -> UpdateResult:
            result = PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _url: remote,
                download=download,
            ).prepare()
            self._forget_imports()
            return result

        timeout = subprocess.TimeoutExpired("python", 12)
        with patch.object(package_updater, "probe", side_effect=timeout):
            first = prepare()
        state_path = self.storage / "state.json"
        self.assertFalse(first.updated)
        self.assertTrue(json.loads(state_path.read_text())["failed"]["retryable"])

        second = prepare()
        self.assertTrue(second.updated)
        self.assertEqual(len(downloads), 2)
        self.assertIsNone(json.loads(state_path.read_text())["failed"])

    def test_broken_release_is_not_downloaded_again(self) -> None:
        source = _make_wheel(self.sources, "2026.9.12")
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files["yt_dlp/__init__.py"] = b"raise RuntimeError('incompatible runtime')"
        with zipfile.ZipFile(source, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        remote = _remote(source, "2026.9.12")
        download = Mock(side_effect=lambda _url, path: shutil.copyfile(source, path))

        for _ in range(2):
            PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _url: remote,
                download=download,
            ).prepare()
            self._forget_imports()

        self.assertEqual(download.call_count, 1)

    def test_activation_failure_uses_previous_runtime_release(self) -> None:
        current = _make_wheel(self.storage, "2026.9.12")
        previous = _make_wheel(self.storage, "2026.9.8")
        _write_state(
            self.storage, _record(current, "2026.9.12"), _record(previous, "2026.9.8")
        )
        activate = PackageUpdater._activate

        def flaky(self_: PackageUpdater, storage: Path, record: WheelRecord) -> None:
            if record.filename == current.name:
                raise OSError("disk full")
            activate(self_, storage, record)

        with patch.object(PackageUpdater, "_activate", flaky):
            result = PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _: None,
            ).prepare()

        self.assertEqual(result.active_source, "runtime")
        self.assertEqual(result.active_version, "2026.9.8")
        # The environmental failure does not demote or delete the release.
        self.assertEqual(result.current_version, "2026.9.12")
        self.assertTrue(current.exists())
        self.assertEqual(Path(sys.path[0]), previous)

    def test_unwritable_download_journal_is_not_persisted_later(self) -> None:
        current = _make_wheel(self.storage, "2026.9.8")
        _write_state(self.storage, _record(current, "2026.9.8"), None)
        source = _make_wheel(self.sources, "2026.9.12")
        download = Mock()
        replace = os.replace

        def fail_journal(source_path, destination):
            if Path(destination).name == "state.json":
                state = json.loads(Path(source_path).read_text())
                if (state.get("pending") or {}).get("status") == "downloading":
                    raise OSError("disk full")
            replace(source_path, destination)

        with patch.object(package_updater.os, "replace", side_effect=fail_journal):
            result = PackageUpdater(
                YT_DLP,
                storage_directory=self.storage,
                bundled_version="2026.8.19",
                fetch_remote=lambda _: _remote(source, "2026.9.12"),
                download=download,
            ).prepare()

        download.assert_not_called()
        self.assertEqual(result.active_version, "2026.9.8")
        self.assertIsNone(
            json.loads((self.storage / "state.json").read_text())["pending"]
        )

    def test_uppercase_remote_digest_installs(self) -> None:
        source = _make_wheel(self.sources, "2026.9.12")
        remote = RemoteRelease(
            Version("2026.9.12"),
            source.name,
            "https://example.test/yt-dlp.whl",
            _sha256(source).upper(),
        )

        result = PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: remote,
            download=lambda _, destination: shutil.copyfile(source, destination),
        ).prepare()

        self.assertTrue(result.updated)
        self.assertEqual(result.active_version, "2026.9.12")

    def test_foreign_storage_entries_are_left_alone(self) -> None:
        self.storage.mkdir(parents=True)
        foreign = self.storage / "site-packages"
        foreign.mkdir()
        other_package = self.storage / "yt_dlp_ejs-0.1.0-py3-none-any.whl"
        other_package.write_bytes(b"not ours")
        sys.path.insert(0, str(foreign))

        PackageUpdater(
            YT_DLP,
            storage_directory=self.storage,
            bundled_version="2026.8.19",
            fetch_remote=lambda _: None,
        ).prepare()

        self.assertIn(str(foreign), sys.path)
        self.assertTrue(other_package.exists())


class YtMusicApiUpdaterTests(unittest.TestCase):
    """ytmusicapi reads gettext catalogs from disk, so it runs extracted."""

    def setUp(self) -> None:
        self.imported_modules = {
            name: module
            for name, module in sys.modules.items()
            if name == "ytmusicapi" or name.startswith("ytmusicapi.")
        }
        for name in self.imported_modules:
            sys.modules.pop(name)
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.storage = root / "runtime"
        self.sources = root / "sources"

    def tearDown(self) -> None:
        storage_prefix = str(self.storage.resolve())
        sys.path[:] = [
            entry
            for entry in sys.path
            if not str(entry).casefold().startswith(storage_prefix.casefold())
        ]
        for name in list(sys.modules):
            if name == "ytmusicapi" or name.startswith("ytmusicapi."):
                sys.modules.pop(name)
        self.temporary_directory.cleanup()
        sys.modules.update(self.imported_modules)

    def _prepare(self, **options) -> UpdateResult:
        return PackageUpdater(
            YTMUSICAPI,
            storage_directory=self.storage,
            bundled_version="1.12.3",
            **options,
        ).prepare()

    def test_installs_and_activates_an_extracted_wheel(self) -> None:
        source = _make_ytmusicapi_wheel(self.sources, "1.13.0")
        remote = RemoteRelease(
            Version("1.13.0"),
            source.name,
            "https://example.test/y.whl",
            _sha256(source),
        )

        result = self._prepare(
            fetch_remote=lambda _url: remote,
            download=lambda _url, destination: shutil.copyfile(source, destination),
        )

        extracted = self.storage / source.name.removesuffix(".whl")
        self.assertTrue(result.updated)
        self.assertEqual(result.active_version, "1.13.0")
        self.assertEqual(Path(sys.path[0]), extracted)
        self.assertTrue((extracted / "ytmusicapi" / "ytmusic.py").is_file())
        self.assertNotIn("ytmusicapi", sys.modules)

    def test_a_modified_extraction_is_replaced(self) -> None:
        wheel = _make_ytmusicapi_wheel(self.storage, "1.13.0")
        _write_state(self.storage, _record(wheel, "1.13.0"), None)
        self._prepare(fetch_remote=lambda _url: None)
        module = (
            self.storage / wheel.name.removesuffix(".whl") / "ytmusicapi" / "ytmusic.py"
        )
        original = module.read_bytes()
        module.write_bytes(b"raise SystemExit('tampered')")

        result = self._prepare(fetch_remote=lambda _url: None)

        self.assertEqual(result.active_source, "runtime")
        self.assertEqual(module.read_bytes(), original)

    def test_obsolete_extractions_are_removed(self) -> None:
        stale = self.storage / "ytmusicapi-1.12.9-py3-none-any"
        stale.mkdir(parents=True)
        (stale / "leftover.py").write_text("")

        result = self._prepare(fetch_remote=lambda _url: None)

        self.assertEqual(result.active_source, "bundled")
        self.assertFalse(stale.exists())

    def test_an_extraction_with_added_modules_is_replaced(self) -> None:
        wheel = _make_ytmusicapi_wheel(self.storage, "1.13.0")
        _write_state(self.storage, _record(wheel, "1.13.0"), None)
        self._prepare(fetch_remote=lambda _url: None)
        extracted = self.storage / wheel.name.removesuffix(".whl")
        added = extracted / "ytmusicapi" / "injected.py"
        added.write_text("raise SystemExit('injected')")
        cache = extracted / "ytmusicapi" / "__pycache__" / "ytmusic.cpython-314.pyc"
        cache.parent.mkdir()
        cache.write_bytes(b"")

        result = self._prepare(fetch_remote=lambda _url: None)

        self.assertEqual(result.active_source, "runtime")
        self.assertFalse(added.exists())


class RemoteIndexTests(unittest.TestCase):
    def _fetch(
        self,
        files: list[dict[str, object]],
        *,
        body: bytes | None = None,
        **headers: str,
    ) -> RemoteRelease | None:
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.geturl.return_value = "https://pypi.org/simple/yt-dlp/"
        response.headers = headers
        response.read.return_value = (
            body if body is not None else json.dumps({"files": files}).encode()
        )
        with patch.object(pypi.urllib.request, "urlopen", return_value=response):
            return pypi.fetch_remote_release(YT_DLP.metadata_url, 1.0, YT_DLP)

    def test_gzip_index_is_requested_and_decoded(self) -> None:
        filename = "yt_dlp-2026.9.12-py3-none-any.whl"
        index = {
            "files": [
                {
                    "filename": filename,
                    "url": f"https://files.pythonhosted.org/packages/{filename}",
                    "hashes": {"sha256": "a" * 64},
                }
            ]
        }
        body = gzip.compress(json.dumps(index).encode())

        release = self._fetch([], body=body, **{"Content-Encoding": "gzip"})

        assert release is not None
        self.assertEqual(release.version, Version("2026.9.12"))

    def test_gzip_index_cannot_expand_past_the_size_limit(self) -> None:
        body = gzip.compress(b" " * (pypi.MAX_INDEX_BYTES + 1))

        with self.assertRaisesRegex(ValueError, "size limit"):
            self._fetch([], body=body, **{"Content-Encoding": "gzip"})

    def test_newest_allowed_release_wins_over_newer_incompatible_ones(self) -> None:
        def wheel(version: str, **extra: object) -> dict[str, object]:
            filename = f"yt_dlp-{version}-py3-none-any.whl"
            return {
                "filename": filename,
                "url": f"https://files.pythonhosted.org/packages/{filename}",
                "hashes": {"sha256": "A" * 64},
                "requires-python": ">=3.10",
                **extra,
            }

        release = self._fetch(
            [
                wheel("2026.9.1"),
                wheel("2026.9.12"),
                wheel("2026.9.20", yanked="broken"),
                wheel("2026.9.25", **{"requires-python": ">=4"}),
                # Nightly uploads report another version and fail the probe.
                wheel("2026.9.27.232945.dev0"),
                wheel("2026.9.28rc1"),
                wheel("2026.9.29a1"),
                wheel("2026.9.29b2"),
                wheel("2026.9.29.post1"),
                wheel("2026.9.12.post1"),
                wheel("2027.1.1"),
                {"filename": "yt_dlp-2026.9.30.tar.gz", "hashes": {}},
            ]
        )

        assert release is not None
        self.assertEqual(release.version, Version("2026.9.12"))
        self.assertEqual(release.sha256, "a" * 64)

    def test_no_qualifying_release_means_no_update(self) -> None:
        self.assertIsNone(self._fetch([]))

    def test_wheels_hosted_elsewhere_are_ignored(self) -> None:
        filename = "yt_dlp-2026.9.12-py3-none-any.whl"
        release = self._fetch(
            [
                {
                    "filename": filename,
                    "url": f"https://mirror.test/{filename}",
                    "hashes": {"sha256": "a" * 64},
                }
            ]
        )
        self.assertIsNone(release)


class TlsTests(unittest.TestCase):
    def test_context_verifies_with_bundled_ca_certificates(self) -> None:
        context = pypi.ssl_context()

        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        self.assertGreater(context.cert_store_stats()["x509_ca"], 0)

    def test_network_requests_use_the_verifying_context(self) -> None:
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.geturl.return_value = "http://insecure.test/"
        with (
            patch.object(
                pypi.urllib.request, "urlopen", return_value=response
            ) as urlopen,
            tempfile.TemporaryDirectory() as directory,
        ):
            with self.assertRaises(ValueError):
                pypi.fetch_remote_release("https://pypi.test/", 1.0, YT_DLP)
            with self.assertRaises(ValueError):
                pypi.download_file(
                    "https://files.test/x.whl", Path(directory) / "x.whl", 1.0
                )

        self.assertEqual(urlopen.call_count, 2)
        for call in urlopen.call_args_list:
            self.assertIs(call.kwargs["context"], pypi.ssl_context())


def _make_ytmusicapi_wheel(directory: Path, version: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"ytmusicapi-{version}-py3-none-any.whl"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("ytmusicapi/__init__.py", "from .ytmusic import YTMusic\n")
        archive.writestr(
            "ytmusicapi/ytmusic.py",
            """
import gettext
from pathlib import Path
class YTMusic:
    def __init__(self):
        gettext.translation(
            'base', localedir=Path(__file__).parent / 'locales', languages=['en']
        )
    def search(self): pass
    def get_watch_playlist(self): pass
    def get_lyrics(self): pass
    def get_playlist(self): pass
""",
        )
        archive.writestr("ytmusicapi/locales/en/LC_MESSAGES/base.mo", _EMPTY_MO)
        archive.writestr(
            f"ytmusicapi-{version}.dist-info/METADATA",
            f"Metadata-Version: 2.1\nName: ytmusicapi\nVersion: {version}\n",
        )
        archive.writestr(
            f"ytmusicapi-{version}.dist-info/WHEEL",
            "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        )
    return path


# A valid GNU message catalog with no messages.
_EMPTY_MO = (
    (0x950412DE).to_bytes(4, "little")
    + (0).to_bytes(4, "little") * 2
    + (28).to_bytes(4, "little") * 2
    + (0).to_bytes(4, "little") * 2
)


def _make_wheel(directory: Path, version: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"yt_dlp-{version}-py3-none-any.whl"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(
            "yt_dlp/__init__.py",
            """
class CookieLoadError(Exception): pass
class YoutubeDL:
    def __init__(self, options): pass
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def extract_info(self): pass
    def download(self): pass
""",
        )
        archive.writestr("yt_dlp/version.py", f"__version__ = {version!r}\n")
        archive.writestr(
            f"yt_dlp-{version}.dist-info/METADATA",
            f"Metadata-Version: 2.1\nName: yt-dlp\nVersion: {version}\nRequires-Python: >=3.12\n",
        )
        archive.writestr(
            f"yt_dlp-{version}.dist-info/WHEEL",
            "Wheel-Version: 1.0\nGenerator: tests\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        )
    return path


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _record(path: Path, version: str) -> WheelRecord:
    return WheelRecord(Version(version), path.name, _sha256(path))


def _remote(path: Path, version: str) -> RemoteRelease:
    return RemoteRelease(
        Version(version), path.name, "https://example.test/yt-dlp.whl", _sha256(path)
    )


def _write_state(
    storage: Path,
    current: WheelRecord | None,
    previous: WheelRecord | None,
) -> None:
    storage.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": 1,
        "current": current.as_json() if current else None,
        "previous": previous.as_json() if previous else None,
    }
    (storage / "state.json").write_text(json.dumps(payload), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
