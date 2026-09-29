from __future__ import annotations

import hashlib
import io
import json
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import urllib.error
import zipfile
from pathlib import Path
from unittest import mock

from tools.fetch_media_binaries import (
    ARCHIVES,
    Archive,
    ResolvedArchive,
    _extract_programs,
    _resolve_archive,
    _validate_audio_encoders,
    fetch_bundle,
    main,
)


class MediaBinaryFetcherTests(unittest.TestCase):
    def test_unsupported_platform_architecture_pair_fails_before_download(
        self,
    ) -> None:
        with (
            tempfile.TemporaryDirectory() as directory,
            self.assertRaisesRegex(ValueError, "linux/arm"),
        ):
            fetch_bundle("linux", "arm", binary_root=Path(directory))

    def test_all_targets_iterates_only_available_platform_architectures(
        self,
    ) -> None:
        with (
            mock.patch("sys.argv", ["fetch_media_binaries.py"]),
            mock.patch("tools.fetch_media_binaries.fetch_bundle") as fetch,
        ):
            main()

        self.assertEqual(
            [(call.args[0], call.args[1]) for call in fetch.call_args_list],
            list(ARCHIVES),
        )

    def test_windows_archives_include_yt_dlp_audio_encoders(self) -> None:
        filenames = {
            "x86_64": "ffmpeg-n9.0-latest-win64-gpl-9.0.zip",
            "arm64": "ffmpeg-n9.0-latest-winarm64-gpl-9.0.zip",
        }
        for architecture, filename in filenames.items():
            archive = ARCHIVES[("windows", architecture)]

            self.assertIn("BtbN/FFmpeg-Builds", archive.release_root)
            self.assertEqual(archive.filename, filename)
            self.assertIsNone(archive.sha256)

    def test_windows_release_resolves_provider_digest(self) -> None:
        archive = ARCHIVES[("windows", "x86_64")]
        with mock.patch(
            "tools.fetch_media_binaries._latest_release",
            return_value=("latest", ((archive.filename, archive.url, "a" * 64),)),
        ):
            resolved = _resolve_archive(archive)
        self.assertEqual(resolved.url, archive.url)
        self.assertEqual(resolved.sha256, "a" * 64)
        self.assertEqual(resolved.version, "latest")

    def test_android_release_manifest_uses_pinned_assets(self) -> None:
        arm64 = ARCHIVES[("android", "arm64")]
        x86_64 = ARCHIVES[("android", "x86_64")]

        self.assertEqual(arm64.version, "build-264")
        self.assertEqual(x86_64.version, "build-264")
        self.assertTrue(arm64.filename.endswith("-Static-android-arm64-v8a.zip"))
        self.assertTrue(x86_64.filename.endswith("-Static-android-x86_64.zip"))

    def test_rejects_missing_audio_encoders(self) -> None:
        result = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=" A....D aac AAC encoder\n", stderr=""
        )
        with (
            mock.patch(
                "tools.fetch_media_binaries.subprocess.run", return_value=result
            ),
            self.assertRaisesRegex(RuntimeError, "libmp3lame, libopus"),
        ):
            _validate_audio_encoders(Path("ffmpeg.exe"))

    def test_cache_detects_damaged_binary_and_invalid_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_archive = root / "fixture.zip"
            with zipfile.ZipFile(source_archive, "w") as package:
                package.writestr("bin/ffmpeg.exe", b"good-ffmpeg")
                package.writestr("bin/ffprobe.exe", b"good-ffprobe")
            sha256 = hashlib.sha256(source_archive.read_bytes()).hexdigest()
            archive = Archive("fixture.zip", sha256, version="fixture-v1")
            output = root / "output"

            def download(_url: str, destination: Path) -> None:
                shutil.copy2(source_archive, destination)

            with (
                mock.patch.dict(ARCHIVES, {("windows", "x86_64"): archive}),
                mock.patch(
                    "tools.fetch_media_binaries._download", side_effect=download
                ) as fetch,
                mock.patch("tools.fetch_media_binaries._validate_audio_encoders"),
            ):
                target = fetch_bundle("windows", "x86_64", binary_root=output)
                metadata = json.loads((target / "bundle.json").read_text())
                self.assertEqual(
                    metadata["program_sha256"]["ffmpeg.exe"],
                    hashlib.sha256(b"good-ffmpeg").hexdigest(),
                )
                fetch_bundle("windows", "x86_64", binary_root=output)
                self.assertEqual(fetch.call_count, 1)

                (target / "ffmpeg.exe").write_bytes(b"damaged")
                fetch_bundle("windows", "x86_64", binary_root=output)
                self.assertEqual(fetch.call_count, 2)
                self.assertEqual((target / "ffmpeg.exe").read_bytes(), b"good-ffmpeg")

                (target / "bundle.json").write_text("{invalid", encoding="utf-8")
                fetch_bundle("windows", "x86_64", binary_root=output)
                self.assertEqual(fetch.call_count, 3)

    def test_new_release_digest_refreshes_cached_windows_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archives = []
            for version in (b"first", b"second"):
                source = root / f"{version.decode()}.zip"
                with zipfile.ZipFile(source, "w") as package:
                    package.writestr("ffmpeg.exe", version)
                    package.writestr("ffprobe.exe", version)
                archives.append(source)
            archive = Archive(
                "fixture.zip",
                None,
                release_root="https://example.test/releases/latest",
                version="latest",
                repository="example/test",
            )
            current = [0]

            def resolve(_archive: Archive) -> ResolvedArchive:
                digest = hashlib.sha256(archives[current[0]].read_bytes()).hexdigest()
                return ResolvedArchive(
                    archive.url, digest, "latest", "https://example.test"
                )

            def download(_url: str, destination: Path) -> None:
                shutil.copy2(archives[current[0]], destination)

            with (
                mock.patch.dict(ARCHIVES, {("windows", "x86_64"): archive}),
                mock.patch(
                    "tools.fetch_media_binaries._resolve_archive", side_effect=resolve
                ) as release,
                mock.patch(
                    "tools.fetch_media_binaries._download", side_effect=download
                ) as fetch,
                mock.patch("tools.fetch_media_binaries._validate_audio_encoders"),
            ):
                target = fetch_bundle("windows", "x86_64", binary_root=root / "output")
                current[0] = 1
                fetch_bundle("windows", "x86_64", binary_root=root / "output")
                self.assertEqual(fetch.call_count, 2)
                self.assertEqual((target / "ffmpeg.exe").read_bytes(), b"second")

                release.side_effect = urllib.error.URLError("offline")
                fetch_bundle("windows", "x86_64", binary_root=root / "output")
                self.assertEqual(fetch.call_count, 2)

    def test_unsupported_cli_target_fails(self) -> None:
        with (
            mock.patch(
                "sys.argv",
                [
                    "fetch_media_binaries.py",
                    "--platform",
                    "linux",
                    "--architecture",
                    "arm",
                ],
            ),
            mock.patch("tools.fetch_media_binaries.fetch_bundle") as fetch,
            self.assertRaises(SystemExit) as error,
        ):
            main()
        self.assertEqual(error.exception.code, 2)
        fetch.assert_not_called()

    def test_nested_android_archive_extracts_both_programs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested_archive = root / "ffmpeg.tar.xz"
            with tarfile.open(nested_archive, mode="w:xz") as package:
                for name, contents in (
                    ("bin/ffmpeg", b"android-ffmpeg"),
                    ("bin/ffprobe", b"android-ffprobe"),
                ):
                    member = tarfile.TarInfo(name)
                    member.size = len(contents)
                    package.addfile(member, io.BytesIO(contents))

            outer_archive = root / "android.zip"
            with zipfile.ZipFile(outer_archive, mode="w") as package:
                package.write(nested_archive, "ffmpeg.tar.xz")

            original_read = zipfile.ZipExtFile.read

            def bounded_read(stream, size=-1):
                if size < 0:
                    raise AssertionError("Nested archive was read without a size limit")
                return original_read(stream, size)

            with mock.patch.object(zipfile.ZipExtFile, "read", bounded_read):
                extracted = _extract_programs(outer_archive, root / "output")

            self.assertEqual(extracted["ffmpeg"].read_bytes(), b"android-ffmpeg")
            self.assertEqual(extracted["ffprobe"].read_bytes(), b"android-ffprobe")


if __name__ == "__main__":
    unittest.main()
