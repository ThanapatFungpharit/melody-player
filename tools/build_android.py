"""Build Android APK/AAB artifacts with executable FFmpeg native payloads."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

from tools.fetch_media_binaries import fetch_bundle
from tools.production_build import (
    ANDROID_SIGNING_ENVIRONMENT_VARIABLES,
    platform_flet_arguments,
    production_process_environment,
    validate_android_release_signing,
)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
ANDROID_BINARY_ROOT = PROJECT_ROOT / "build" / "android-native"
ANDROID_ABIS = {
    "arm64": "arm64-v8a",
    "arm": "armeabi-v7a",
    "x86_64": "x86_64",
}
ANDROID_XML_NAMESPACE = "http://schemas.android.com/apk/res/android"
ANDROID_KEY_SECRETS = (
    "ANDROID_KEY_STORE_BASE64",
    "ANDROID_KEY_STORE_PASSWORD",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEY_ALIAS",
)
REMOTE_DEBUG_GRADLE_HOOK = (
    PROJECT_ROOT / "tools" / "android_strip_remote_debug.gradle.kts"
)


def stage_android_native_libraries(
    flutter_dir: Path,
    architectures: list[str],
    *,
    binary_root: Path = ANDROID_BINARY_ROOT,
) -> None:
    """Place CLI executables where Android installs executable native files.

    Android 10 and newer cannot execute programs from writable application
    storage. Naming the position-independent executables as native libraries
    and enabling legacy JNI packaging makes the installer place them in the
    app's read-only ``nativeLibraryDir`` instead.
    """
    jni_root = flutter_dir / "android" / "app" / "src" / "main" / "jniLibs"
    for architecture in architectures:
        abi = ANDROID_ABIS[architecture]
        source = binary_root / "android" / architecture
        destination = jni_root / abi
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / "ffmpeg", destination / "libffmpeg.so")
        shutil.copy2(source / "ffprobe", destination / "libffprobe.so")


def configure_single_task_activity(flutter_dir: Path) -> None:
    """Make launcher and notification intents reuse Melody's one activity.

    Flet's standard Flutter template uses ``singleTop``. That permits another
    MainActivity whenever the existing activity is not currently at the top of
    its task, which can create a second Flet page, playback controller, and
    media-session bridge. ``singleTask`` routes those intents to the existing
    activity via ``onNewIntent``; disabling document launches closes the other
    Android route to parallel task instances.
    """
    manifest = flutter_dir / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    tree = ET.parse(manifest)
    root = tree.getroot()
    android_name = f"{{{ANDROID_XML_NAMESPACE}}}name"
    launcher = None
    for activity in root.findall("./application/activity"):
        for intent_filter in activity.findall("intent-filter"):
            actions = {
                item.get(android_name) for item in intent_filter.findall("action")
            }
            categories = {
                item.get(android_name) for item in intent_filter.findall("category")
            }
            if (
                "android.intent.action.MAIN" in actions
                and "android.intent.category.LAUNCHER" in categories
            ):
                launcher = activity
                break
        if launcher is not None:
            break
    if launcher is None:
        raise RuntimeError("Generated Android manifest has no launcher activity")
    launcher.set(f"{{{ANDROID_XML_NAMESPACE}}}launchMode", "singleTask")
    launcher.set(f"{{{ANDROID_XML_NAMESPACE}}}documentLaunchMode", "never")
    ET.register_namespace("android", ANDROID_XML_NAMESPACE)
    tree.write(manifest, encoding="utf-8", xml_declaration=True)


def configure_persistent_flutter_engine(flutter_dir: Path) -> None:
    """Keep the decoder's Dart engine alive after Android removes the task.

    The media-session foreground service survives a recents swipe, but Flet's
    default FlutterActivity destroys its engine. That leaves an orphaned live
    notification with no just_audio decoder. Cache the normal first-launch
    engine and attach the next activity to it when the notification is opened.
    """
    source_root = flutter_dir / "android" / "app" / "src" / "main" / "kotlin"
    activities = list(source_root.rglob("MainActivity.kt"))
    if len(activities) != 1:
        raise RuntimeError("Expected one generated Android MainActivity")
    activity = activities[0]
    source = activity.read_text(encoding="utf-8")
    if "FlutterEngineCache.getInstance().put(ENGINE_ID, engine)" in source:
        return
    package_line, _, body = source.partition("\n")
    if not package_line.startswith("package ") or body.strip() != (
        "import io.flutter.embedding.android.FlutterActivity\n\n"
        "class MainActivity : FlutterActivity()"
    ):
        raise RuntimeError("Generated Android MainActivity template has changed")
    activity.write_text(
        package_line
        + """

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    companion object {
        private const val ENGINE_ID = "melody-player"
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_ID)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        flutterEngine?.let { engine ->
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
""",
        encoding="utf-8",
    )


def configure_android_runtime(flutter_dir: Path) -> None:
    """Remove CPython's optional remote debugger from release packages."""
    gradle_file = flutter_dir / "android" / "build.gradle.kts"
    hook = REMOTE_DEBUG_GRADLE_HOOK.read_text(encoding="utf-8")
    contents = gradle_file.read_text(encoding="utf-8")
    if "// melody: strip Python remote debugger" not in contents:
        gradle_file.write_text(f"{contents.rstrip()}\n\n{hook}\n", encoding="utf-8")


@contextmanager
def close_finished_sdk_stdin() -> Iterator[None]:
    """Close installer pipes left open by the pinned Flet CLI SDK helper."""
    from flet_cli.utils.android_sdk import AndroidSDK

    # Flet 0.86.5's streamed process helper waits and closes stdout, but leaves
    # its stdin=PIPE handle open when SDK package installation returns.
    original_run = AndroidSDK.run

    def run(self: AndroidSDK, *args: Any, **kwargs: Any) -> Any:
        result = original_run(self, *args, **kwargs)
        if (
            isinstance(result, subprocess.Popen)
            and result.poll() is not None
            and result.stdin is not None
        ):
            result.stdin.close()
        return result

    AndroidSDK.run = run
    try:
        yield
    finally:
        AndroidSDK.run = original_run


def prepare_android_media_bundles(architectures: list[str]) -> None:
    """Prepare independent ABI bundles with at most two concurrent workers."""
    if len(architectures) == 1:
        fetch_bundle("android", architectures[0], binary_root=ANDROID_BINARY_ROOT)
        return
    with ThreadPoolExecutor(
        max_workers=2, thread_name_prefix="melody-android-media"
    ) as pool:
        pending = [
            pool.submit(fetch_bundle, "android", arch, binary_root=ANDROID_BINARY_ROOT)
            for arch in architectures
        ]
        for future in pending:
            future.result()


@contextmanager
def android_release_signing_environment() -> Iterator[None]:
    """Accept the generated .env signing secrets as well as Flet's variables."""
    if any(
        os.environ.get(name, "").strip()
        for name in ANDROID_SIGNING_ENVIRONMENT_VARIABLES
    ):
        yield
        return

    if not any(os.environ.get(name, "").strip() for name in ANDROID_KEY_SECRETS):
        yield
        return

    missing = [
        name for name in ANDROID_KEY_SECRETS if not os.environ.get(name, "").strip()
    ]
    if missing:
        raise RuntimeError(
            "Android release signing secrets are missing: " + ", ".join(missing)
        )
    try:
        key_store_bytes = base64.b64decode(
            os.environ["ANDROID_KEY_STORE_BASE64"], validate=True
        )
    except (binascii.Error, ValueError) as error:
        raise RuntimeError("ANDROID_KEY_STORE_BASE64 is not valid Base64") from error
    if not key_store_bytes:
        raise RuntimeError("ANDROID_KEY_STORE_BASE64 is empty")

    with tempfile.TemporaryDirectory(prefix="melody-signing-") as directory:
        key_store = Path(directory) / "release.jks"
        key_store.write_bytes(key_store_bytes)
        values = dict(
            zip(
                ANDROID_SIGNING_ENVIRONMENT_VARIABLES,
                (
                    str(key_store),
                    os.environ["ANDROID_KEY_STORE_PASSWORD"],
                    os.environ["ANDROID_KEY_PASSWORD"],
                    os.environ["ANDROID_KEY_ALIAS"],
                ),
                strict=True,
            )
        )
        previous = {name: os.environ.get(name) for name in values}
        os.environ.update(values)
        try:
            yield
        finally:
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value


def _run_flet_build(
    target: str, architectures: list[str], flet_arguments: list[str]
) -> None:
    # ``flet-cli`` is present in the isolated release/build environment. Keep
    # these imports local so the application runtime and UI smoke tests do not
    # need the packaging tool installed.
    from flet_cli import cli
    from flet_cli.commands.build import Command

    original_run_flutter = Command.run_flutter

    def run_flutter(self: Any) -> None:
        stage_android_native_libraries(self.flutter_dir, architectures)
        configure_single_task_activity(self.flutter_dir)
        configure_persistent_flutter_engine(self.flutter_dir)
        configure_android_runtime(self.flutter_dir)
        original_run_flutter(self)

    Command.run_flutter = run_flutter
    previous_argv = sys.argv
    try:
        sys.argv = [
            "flet",
            "build",
            target,
            str(PROJECT_ROOT),
            "--arch",
            *(ANDROID_ABIS[item] for item in architectures),
            "--android-legacy-packaging",
            *flet_arguments,
        ]
        with close_finished_sdk_stdin():
            cli.main()
    finally:
        Command.run_flutter = original_run_flutter
        sys.argv = previous_argv


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("apk", "aab"))
    parser.add_argument(
        "--architecture",
        choices=tuple(ANDROID_ABIS),
        action="append",
        dest="architectures",
    )
    arguments, flet_arguments = parser.parse_known_args()
    architectures = list(
        dict.fromkeys(arguments.architectures or ["arm64", "arm", "x86_64"])
    )
    if flet_arguments[:1] == ["--"]:
        flet_arguments = flet_arguments[1:]
    load_dotenv(PROJECT_ROOT / ".env", override=False)
    flet_arguments = platform_flet_arguments(
        flet_arguments,
        target=arguments.target,
        project_file=PROJECT_ROOT / "pyproject.toml",
    )
    with android_release_signing_environment():
        validate_android_release_signing(os.environ)
        with production_process_environment():
            prepare_android_media_bundles(architectures)
            _run_flet_build(arguments.target, architectures, flet_arguments)


if __name__ == "__main__":
    main()
