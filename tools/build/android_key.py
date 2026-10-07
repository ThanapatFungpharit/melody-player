"""Create an Android release keystore and append its ANDROID_KEY_* to .signing.

    uv run melody-android-key
    uv run melody-android-key --key-store signing/release.jks --alias melody

``melody-build`` reads ANDROID_KEY_* from ``.signing`` in the repository root.
Relative paths are resolved against the current directory. Existing keystores
and existing ANDROID_KEY_* entries are never overwritten. Back up the keystore
and its credentials securely, and never commit either.
"""

from __future__ import annotations

import argparse
import base64
import re
import secrets
import subprocess
from pathlib import Path

from tools.common import SIGNING_FILE, child_environment, executable, load_env_file

SECRET_NAMES = (
    "ANDROID_KEY_STORE_BASE64",
    "ANDROID_KEY_STORE_PASSWORD",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEY_ALIAS",
)
DEFAULT_NAME = "CN=Android Release, OU=Development, O=Personal, C=US"
# keytool reads the passwords from these variables, never from its arguments.
_PASSWORD_VARIABLE = "MELODY_KEYTOOL_PASSWORD"


def check_targets(signing_file: Path, key_store: Path) -> None:
    """Refuse to replace an existing signing key or its credentials."""
    if key_store.exists():
        raise SystemExit(
            f"Keystore already exists: {key_store}. "
            "Refusing to overwrite an existing signing key."
        )
    if signing_file.is_file():
        existing = signing_file.read_text("utf-8")
        for name in SECRET_NAMES:
            if re.search(rf"^\s*{name}\s*=", existing, re.MULTILINE):
                raise SystemExit(
                    f"{name} already exists in {signing_file}. "
                    "Refusing to replace existing credentials."
                )


def append_credentials(
    signing_file: Path, key_store: Path, password: str, alias: str
) -> None:
    encoded = base64.b64encode(key_store.read_bytes()).decode("ascii")
    block = "\n".join(
        [
            "# Android release signing",
            f"ANDROID_KEY_STORE_BASE64={encoded}",
            f"ANDROID_KEY_STORE_PASSWORD={password}",
            f"ANDROID_KEY_PASSWORD={password}",
            f"ANDROID_KEY_ALIAS={alias}",
        ]
    )
    existing = signing_file.read_text("utf-8") if signing_file.is_file() else ""
    if existing:
        separator = "\n" if existing.endswith("\n") else "\n\n"
        block = separator + block
    with signing_file.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(block + "\n")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="melody-android-key",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--signing-file", type=Path, default=SIGNING_FILE)
    parser.add_argument("--key-store", type=Path, default=Path("android-release.jks"))
    parser.add_argument("--alias", default="release")
    parser.add_argument("--distinguished-name", default=DEFAULT_NAME)
    parser.add_argument("--validity-days", type=int, default=10000)
    arguments = parser.parse_args(argv)
    signing_file = arguments.signing_file.resolve()
    key_store = arguments.key_store.resolve()

    load_env_file()  # JAVA_HOME, for keytool
    keytool = executable("keytool")
    check_targets(signing_file, key_store)
    # Hexadecimal avoids shell and dotenv escaping issues. PKCS12 uses the same
    # password for the keystore and the private key.
    password = secrets.token_hex(32).upper()
    print("Generating Android release signing key...")
    key_store.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            keytool,
            "-genkeypair",
            "-v",
            "-keystore",
            str(key_store),
            "-storetype",
            "PKCS12",
            "-alias",
            arguments.alias,
            "-keyalg",
            "RSA",
            "-keysize",
            "4096",
            "-sigalg",
            "SHA256withRSA",
            "-validity",
            str(arguments.validity_days),
            "-dname",
            arguments.distinguished_name,
            "-storepass:env",
            _PASSWORD_VARIABLE,
            "-keypass:env",
            _PASSWORD_VARIABLE,
        ],
        env=child_environment({_PASSWORD_VARIABLE: password}),
        check=True,
    )
    if not key_store.is_file():
        raise SystemExit("Failed to generate the Android signing keystore.")
    append_credentials(signing_file, key_store, password, arguments.alias)
    print(
        "\nAndroid signing key generated."
        f"\nKeystore: {key_store}\nSigning file: {signing_file}"
        f"\nKey alias: {arguments.alias}"
        "\n\nBack up the keystore and credentials securely. Do not commit either."
    )


if __name__ == "__main__":
    main()
