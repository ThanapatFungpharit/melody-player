from __future__ import annotations

import base64
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.build.android_key import append_credentials, check_targets
from tools.build.app import android_signing
from tools.common import read_env_file


class AndroidKeyTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.signing_file = self.root / ".signing"
        self.key_store = self.root / "release.jks"

    def test_refuses_to_overwrite_a_keystore(self) -> None:
        self.key_store.write_bytes(b"key")

        with self.assertRaisesRegex(SystemExit, "already exists"):
            check_targets(self.signing_file, self.key_store)

    def test_refuses_to_replace_existing_credentials(self) -> None:
        self.signing_file.write_text("OTHER=1\n  ANDROID_KEY_ALIAS = old\n")

        with self.assertRaisesRegex(SystemExit, "ANDROID_KEY_ALIAS"):
            check_targets(self.signing_file, self.key_store)

    def test_allows_unrelated_settings(self) -> None:
        self.signing_file.write_text("MY_ANDROID_KEY_ALIAS=1\n")

        check_targets(self.signing_file, self.key_store)

    def test_appends_a_separated_block_to_an_existing_file(self) -> None:
        self.signing_file.write_text("OTHER=1")  # no trailing newline
        self.key_store.write_bytes(b"\x00key")

        append_credentials(self.signing_file, self.key_store, "ABC", "release")

        lines = self.signing_file.read_text("utf-8").split("\n")
        self.assertEqual(lines[:3], ["OTHER=1", "", "# Android release signing"])
        self.assertIn(
            f"ANDROID_KEY_STORE_BASE64={base64.b64encode(b'\x00key').decode()}", lines
        )
        self.assertIn("ANDROID_KEY_STORE_PASSWORD=ABC", lines)
        self.assertIn("ANDROID_KEY_PASSWORD=ABC", lines)
        self.assertEqual(lines[-2:], ["ANDROID_KEY_ALIAS=release", ""])

    def test_creates_a_new_file_without_a_leading_blank_line(self) -> None:
        self.key_store.write_bytes(b"key")

        append_credentials(self.signing_file, self.key_store, "ABC", "release")

        self.assertTrue(
            self.signing_file.read_text("utf-8").startswith(
                "# Android release signing\n"
            )
        )


class SigningFileTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.signing_file = Path(directory.name) / ".signing"
        self.key_store = Path(directory.name) / "release.jks"
        self.key_store.write_bytes(b"\x00key")
        environment = mock.patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def write_credentials(self) -> None:
        append_credentials(self.signing_file, self.key_store, "ABC", "release")

    def test_signs_with_the_secrets_in_the_signing_file(self) -> None:
        self.write_credentials()

        with android_signing(False, self.signing_file) as signing:
            self.assertEqual(
                Path(signing["MELODY_ANDROID_KEY_STORE"]).read_bytes(), b"\x00key"
            )
            self.assertEqual(signing["MELODY_ANDROID_KEY_STORE_PASSWORD"], "ABC")
            self.assertEqual(signing["MELODY_ANDROID_KEY_ALIAS"], "release")
        # The secrets are handed to the signing build only.
        self.assertNotIn("ANDROID_KEY_STORE_PASSWORD", os.environ)

    def test_exported_secrets_take_precedence(self) -> None:
        self.write_credentials()
        os.environ["ANDROID_KEY_ALIAS"] = "exported"

        with android_signing(False, self.signing_file) as signing:
            self.assertEqual(signing["MELODY_ANDROID_KEY_ALIAS"], "exported")

    def test_requires_release_signing_without_secrets(self) -> None:
        with (
            self.assertRaisesRegex(SystemExit, r"\.signing"),
            android_signing(False, self.signing_file),
        ):
            pass

    def test_read_env_file_parses_quotes_comments_and_export(self) -> None:
        self.signing_file.write_text(
            "# comment\n\nexport A='one'\nB = \"two=2\"\nnot a variable\n"
        )

        self.assertEqual(read_env_file(self.signing_file), {"A": "one", "B": "two=2"})


if __name__ == "__main__":
    unittest.main()
