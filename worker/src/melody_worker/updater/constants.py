"""Limits, file names, and formats shared across the updater."""

from __future__ import annotations

import re

# Layout version of ``state.json`` written by this release. Readers also
# accept schema 1, which had no ``pending`` or ``failed`` journal entries.
STATE_SCHEMA = 2

MAX_WHEEL_BYTES = 32 * 1024 * 1024
MAX_EXPANDED_BYTES = 128 * 1024 * 1024
MAX_INDEX_BYTES = 8 * 1024 * 1024
# Bounds a whole wheel download; the socket timeout only bounds each read.
MAX_DOWNLOAD_SECONDS = 300.0
# Seconds allowed for one network read, and for a subprocess import probe.
DEFAULT_TIMEOUT = 12.0

# PEP 691 JSON form of PyPI's simple index; it lists every release.
SIMPLE_JSON = "application/vnd.pypi.simple.v1+json"
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)

# Written into an extracted wheel; names the wheel digest it was made from.
EXTRACTED_MARKER = ".melody-wheel-sha256"
# Wheel digests that passed the CRC check and import probe, and the
# environment they passed in. See PackageUpdater._validate_wheel.
PROBED_FILE = "probed.json"
