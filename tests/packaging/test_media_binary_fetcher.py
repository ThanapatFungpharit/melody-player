from __future__ import annotations

import io
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from tools.fetch_media_binaries import (
    ARCHIVES,
    Archive,
    ReleaseAsset,
    _extract_programs,
    _resolve_archive,
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
            "x86_64": "ffmpeg-windows-amd64.zip",
            "arm64": "ffmpeg-windows-arm64.zip",
        }
        for architecture, filename in filenames.items():
            archive = ARCHIVES[("windows", architecture)]

            self.assertEqual(archive.repository, "binmgr/ffmpeg")
            self.assertEqual(archive.filename, filename)

    def test_latest_release_resolution_uses_stable_asset_name_and_digest(self) -> None:
        archive = Archive("example/ffmpeg", "ffmpeg-windows-amd64.zip")
        release = (
            "v10.0.0",
            (
                ReleaseAsset(
                    "ffmpeg-windows-amd64.zip",
                    "https://downloads.example/ffmpeg-windows-amd64.zip",
                    "a" * 64,
                ),
            ),
        )

        with mock.patch(
            "tools.fetch_media_binaries._latest_release", return_value=release
        ):
            resolved = _resolve_archive(archive)

        self.assertEqual(resolved.version, "v10.0.0")
        self.assertEqual(resolved.sha256, "a" * 64)
        self.assertEqual(
            resolved.url, "https://downloads.example/ffmpeg-windows-amd64.zip"
        )

    def test_latest_release_resolution_accepts_android_versioned_asset(self) -> None:
        archive = Archive(
            "example/ffmpeg-android",
            filename_suffix="-Static-android-arm64-v8a.zip",
        )
        release = (
            "build-999",
            (
                ReleaseAsset(
                    "ffmpeg-10.0-abcdef-Static-android-arm64-v8a.zip",
                    "https://downloads.example/android-arm64.zip",
                    "b" * 64,
                ),
            ),
        )

        with mock.patch(
            "tools.fetch_media_binaries._latest_release", return_value=release
        ):
            resolved = _resolve_archive(archive)

        self.assertEqual(
            resolved.filename, "ffmpeg-10.0-abcdef-Static-android-arm64-v8a.zip"
        )
        self.assertEqual(resolved.version, "build-999")

    def test_android_release_manifest_uses_version_independent_selectors(self) -> None:
        arm64 = ARCHIVES[("android", "arm64")]
        x86_64 = ARCHIVES[("android", "x86_64")]

        self.assertEqual(arm64.repository, "rhythmcache/ffmpeg-android")
        self.assertEqual(x86_64.repository, "rhythmcache/ffmpeg-android")
        self.assertEqual(arm64.filename_suffix, "-Static-android-arm64-v8a.zip")
        self.assertEqual(x86_64.filename_suffix, "-Static-android-x86_64.zip")

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

            extracted = _extract_programs(outer_archive, root / "output")

            self.assertEqual(extracted["ffmpeg"].read_bytes(), b"android-ffmpeg")
            self.assertEqual(extracted["ffprobe"].read_bytes(), b"android-ffprobe")


if __name__ == "__main__":
    unittest.main()
