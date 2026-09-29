from __future__ import annotations

import base64
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from threading import Barrier
from unittest import mock

from flet_cli.utils.android_sdk import AndroidSDK

from tools import build_android
from tools.build_android import (
    close_finished_sdk_stdin,
    configure_persistent_flutter_engine,
    configure_single_task_activity,
    prepare_android_media_bundles,
    stage_android_native_libraries,
)


class AndroidBuildTests(unittest.TestCase):
    def test_generated_dotenv_secrets_sign_local_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key_store_bytes = b"release keystore fixture"
            encoded = base64.b64encode(key_store_bytes).decode("ascii")
            (root / ".env").write_text(
                f"ANDROID_KEY_STORE_BASE64={encoded}\n"
                "ANDROID_KEY_STORE_PASSWORD=store-password\n"
                "ANDROID_KEY_PASSWORD=key-password\n"
                "ANDROID_KEY_ALIAS=release\n",
                encoding="utf-8",
            )
            signing_paths: list[Path] = []

            def build(
                _target: str, _architectures: list[str], _args: list[str]
            ) -> None:
                key_store = Path(os.environ["FLET_ANDROID_SIGNING_KEY_STORE"])
                signing_paths.append(key_store)
                self.assertEqual(key_store.read_bytes(), key_store_bytes)
                self.assertEqual(
                    os.environ["FLET_ANDROID_SIGNING_KEY_STORE_PASSWORD"],
                    "store-password",
                )

            with (
                mock.patch.dict(os.environ, {}, clear=True),
                mock.patch.object(build_android, "PROJECT_ROOT", root),
                mock.patch(
                    "sys.argv", ["build_android.py", "apk", "--architecture", "arm64"]
                ),
                mock.patch.object(
                    build_android, "platform_flet_arguments", return_value=[]
                ),
                mock.patch.object(build_android, "fetch_bundle"),
                mock.patch.object(build_android, "_run_flet_build", side_effect=build),
            ):
                build_android.main()
                self.assertNotIn("FLET_ANDROID_SIGNING_KEY_STORE", os.environ)

            self.assertEqual(len(signing_paths), 1)
            self.assertFalse(signing_paths[0].exists())

    def test_media_bundles_for_two_abis_are_prepared_concurrently(self) -> None:
        both_started = Barrier(2, timeout=5)

        def fetch(_platform: str, _architecture: str, *, binary_root: Path) -> None:
            self.assertEqual(binary_root, build_android.ANDROID_BINARY_ROOT)
            both_started.wait()

        with mock.patch.object(
            build_android, "fetch_bundle", side_effect=fetch
        ) as call:
            prepare_android_media_bundles(["arm64", "x86_64"])

        self.assertEqual(
            {args.args[1] for args in call.call_args_list}, {"arm64", "x86_64"}
        )

    def test_repeated_abi_is_fetched_and_built_once(self) -> None:
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch(
                "sys.argv",
                [
                    "build_android.py",
                    "apk",
                    "--architecture",
                    "arm64",
                    "--architecture",
                    "arm64",
                    "--",
                    "--yes",
                ],
            ),
            mock.patch.object(build_android, "validate_android_release_signing"),
            mock.patch.object(build_android, "fetch_bundle") as fetch,
            mock.patch.object(build_android, "_run_flet_build") as build,
        ):
            build_android.main()

        fetch.assert_called_once_with(
            "android", "arm64", binary_root=build_android.ANDROID_BINARY_ROOT
        )
        self.assertEqual(build.call_args.args[1], ["arm64"])

    def test_failed_media_preparation_stops_before_flet_build(self) -> None:
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch(
                "sys.argv",
                ["build_android.py", "apk", "--architecture", "arm64"],
            ),
            mock.patch.object(build_android, "validate_android_release_signing"),
            mock.patch.object(
                build_android, "fetch_bundle", side_effect=OSError("download failed")
            ),
            mock.patch.object(build_android, "_run_flet_build") as build,
            self.assertRaisesRegex(OSError, "download failed"),
        ):
            build_android.main()

        build.assert_not_called()

    def test_sdk_installer_stdin_is_closed_and_original_method_restored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen(
                [sys.executable, "-c", "pass"], stdin=subprocess.PIPE
            )
            assert process.stdin is not None
            self.addCleanup(process.wait)
            self.addCleanup(process.stdin.close)
            process.wait()
            sdk = AndroidSDK("", lambda _: None)

            with (
                mock.patch.object(AndroidSDK, "run", return_value=process) as original,
                mock.patch.object(
                    AndroidSDK,
                    "sdkmanager_exe",
                    return_value=Path(directory) / "sdkmanager",
                ),
            ):
                with close_finished_sdk_stdin():
                    sdk._install_package(Path(directory), "platform-tools")
                self.assertIs(AndroidSDK.run, original)

            self.assertTrue(process.stdin.closed)

    def test_sdk_method_is_restored_when_build_setup_fails(self) -> None:
        sdk = AndroidSDK("", lambda _: None)
        with mock.patch.object(
            AndroidSDK, "run", side_effect=RuntimeError("sdk failed")
        ) as original:
            with (
                self.assertRaisesRegex(RuntimeError, "sdk failed"),
                close_finished_sdk_stdin(),
            ):
                sdk.run(["unused"])
            self.assertIs(AndroidSDK.run, original)

    def test_launcher_activity_is_single_task(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            flutter = Path(directory)
            manifest = flutter / "android/app/src/main/AndroidManifest.xml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application>
    <activity android:name=".MainActivity" android:launchMode="singleTop">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
    </activity>
  </application>
</manifest>
""",
                encoding="utf-8",
            )

            configure_single_task_activity(flutter)

            configured = manifest.read_text(encoding="utf-8")
            self.assertIn('android:launchMode="singleTask"', configured)
            self.assertIn('android:documentLaunchMode="never"', configured)

    def test_launcher_reuses_engine_after_task_removal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            flutter = Path(directory)
            activity = (
                flutter
                / "android/app/src/main/kotlin/com/flet/musicplayer/MainActivity.kt"
            )
            activity.parent.mkdir(parents=True)
            activity.write_text(
                "package com.flet.musicplayer\n\n"
                "import io.flutter.embedding.android.FlutterActivity\n\n"
                "class MainActivity : FlutterActivity()\n",
                encoding="utf-8",
            )

            configure_persistent_flutter_engine(flutter)
            configured = activity.read_text(encoding="utf-8")
            self.assertIn("provideFlutterEngine(context: Context)", configured)
            self.assertIn("FlutterEngineCache.getInstance().put", configured)
            self.assertIn("shouldDestroyEngineWithHost(): Boolean = false", configured)
            configure_persistent_flutter_engine(flutter)
            self.assertEqual(activity.read_text(encoding="utf-8"), configured)

    def test_programs_are_staged_as_abi_native_libraries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "native"
            flutter = root / "flutter"
            for architecture in ("arm64", "x86_64"):
                source = binaries / "android" / architecture
                source.mkdir(parents=True)
                (source / "ffmpeg").write_bytes(f"{architecture}-ffmpeg".encode())
                (source / "ffprobe").write_bytes(f"{architecture}-ffprobe".encode())

            stage_android_native_libraries(
                flutter,
                ["arm64", "x86_64"],
                binary_root=binaries,
            )

            jni = flutter / "android/app/src/main/jniLibs"
            self.assertEqual(
                (jni / "arm64-v8a/libffmpeg.so").read_bytes(), b"arm64-ffmpeg"
            )
            self.assertEqual(
                (jni / "arm64-v8a/libffprobe.so").read_bytes(), b"arm64-ffprobe"
            )
            self.assertEqual(
                (jni / "x86_64/libffmpeg.so").read_bytes(), b"x86_64-ffmpeg"
            )
            self.assertEqual(
                (jni / "x86_64/libffprobe.so").read_bytes(), b"x86_64-ffprobe"
            )


if __name__ == "__main__":
    unittest.main()
