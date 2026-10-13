"""Import probes, and the record that lets already-probed bytes skip them."""

from __future__ import annotations

import functools
import hashlib
import importlib
import importlib.metadata
import json
import logging
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

from packaging.version import Version

from .constants import EXTRACTED_MARKER, PROBED_FILE, SHA256_HEX
from .files import unlink
from .packages import PACKAGES, RuntimePackage
from .records import WheelRecord

logger = logging.getLogger(__name__)

# Shared start of every import probe. ``probe_path`` is the wheel or the
# extracted directory, placed first on ``sys.path``.
PROBE_PRELUDE = """
import os
import sys
from packaging.version import Version
probe_path, expected_version = globals().get('probe_arguments') or sys.argv[1:]
sys.path.insert(0, probe_path)
def require_location(module):
    root = os.path.normcase(os.path.abspath(probe_path))
    location = os.path.normcase(os.path.abspath(module.__file__))
    if os.path.commonpath([root, location]) != root:
        raise ValueError('Wrong package imported')
"""


def probe(
    path: Path, version: Version, package: RuntimePackage, *, timeout: float
) -> None:
    """Import ``package`` from ``path`` and check the API Melody calls."""
    script = PROBE_PRELUDE + package.probe
    # Embedded Python cannot necessarily spawn another interpreter. Startup is the
    # only time an import probe may temporarily select a package in this process.
    standalone = bool(
        re.fullmatch(
            r"(?:pythonw?|pypy)(?:\d+(?:\.\d+)*)?(?:\.exe)?",
            Path(sys.executable).name.casefold(),
        )
    )
    if (
        sys.platform in {"ios", "android"}
        or hasattr(sys, "getandroidapilevel")
        or getattr(sys, "frozen", False)
        or not standalone
    ):
        original_path = sys.path[:]
        try:
            exec(script, {"probe_arguments": [str(path), str(version)]})  # noqa: S102 - fixed, local API probe (never remote source text)
        except MemoryError:
            raise
        except (Exception, SystemExit) as error:
            # Whatever the package raised on import, this release is unusable
            # here; it must not end the calling thread either.
            raise ValueError(
                f"{package.distribution} import/API validation failed: {error}"
            ) from error
        finally:
            sys.path[:] = original_path
            for name in list(sys.modules):
                if name == package.module or name.startswith(f"{package.module}."):
                    sys.modules.pop(name, None)
            importlib.invalidate_caches()
    else:
        result = subprocess.run(
            [sys.executable, "-I", "-c", script, str(path), str(version)],
            capture_output=True,
            timeout=timeout,
            check=False,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        if result.returncode:
            lines = result.stderr.decode("utf-8", "replace").strip().splitlines()
            detail = lines[-1] if lines else f"exit status {result.returncode}"
            raise ValueError(
                f"{package.distribution} import/API validation failed: {detail}"
            )


@functools.cache
def bundle_fingerprint() -> str:
    """The interpreter and the distributions it bundles. Runtime wheels are
    left out, active or not, so the answer never depends on activation (and
    no wheel stays open in importlib's zip cache)."""
    try:
        bundle = [
            entry
            for entry in sys.path
            if isinstance(entry, str)
            and not entry.casefold().endswith(".whl")
            and not os.path.exists(os.path.join(entry or ".", EXTRACTED_MARKER))
        ]
        updatable = {name.replace("_", "-").lower() for name in PACKAGES}
        installed: set[str] = set()
        for distribution in importlib.metadata.distributions(path=bundle):
            try:
                metadata = distribution.metadata
                raw_name = metadata["Name"] if metadata is not None else None
                name = str(raw_name or "").replace("_", "-").lower()
                version = distribution.version
            except Exception as error:  # noqa: BLE001 - one broken record must not disable updates
                logger.debug("Skipping unreadable distribution metadata: %s", error)
                continue
            if name and name not in updatable:
                installed.add(f"{name}=={version}")
    except Exception as error:  # noqa: BLE001 - probe caching is an optimization
        logger.warning("Could not fingerprint the bundled packages: %s", error)
        # Never matches a stored record, so every wheel is probed again.
        return f"unavailable:{uuid.uuid4().hex}"
    return "\n".join([sys.version, sys.platform, *sorted(installed)])


def environment_fingerprint(package: RuntimePackage, bundled: Version) -> str:
    """What an import probe's outcome depends on besides the wheel itself:
    the bundle, the bundled release, and the probe."""
    return hashlib.sha256(
        "\n".join(
            [bundle_fingerprint(), str(bundled), PROBE_PRELUDE, package.probe]
        ).encode("utf-8")
    ).hexdigest()


def read_probed(storage: Path, package: RuntimePackage, bundled: Version) -> set[str]:
    """Digests whose CRC check and probe passed in this environment."""
    try:
        value = json.loads((storage / PROBED_FILE).read_text(encoding="utf-8"))
    except OSError, ValueError:
        return set()
    if (
        not isinstance(value, dict)
        or value.get("environment") != environment_fingerprint(package, bundled)
        or not isinstance(value.get("digests"), list)
    ):
        return set()
    return {
        item.lower()
        for item in value["digests"]
        if isinstance(item, str) and SHA256_HEX.fullmatch(item)
    }


def write_probed(
    storage: Path,
    package: RuntimePackage,
    bundled: Version,
    probed: set[str],
    current: WheelRecord | None,
    previous: WheelRecord | None,
) -> None:
    """Keeps the retained wheels' probe results; failures only cost the
    next launch a probe."""
    digests = sorted(
        record.sha256
        for record in (current, previous)
        if record and record.sha256 in probed
    )
    path = storage / PROBED_FILE
    if not digests:
        unlink(path)
        return
    payload = {
        "environment": environment_fingerprint(package, bundled),
        "digests": digests,
    }
    try:
        if json.loads(path.read_text(encoding="utf-8")) == payload:
            return
    except OSError, ValueError:
        pass
    temporary = storage / f"{PROBED_FILE}.tmp"
    try:
        temporary.write_text(json.dumps(payload), encoding="utf-8")
        os.replace(temporary, path)
    except OSError as error:
        logger.warning(
            "Could not record %s probe results: %s", package.distribution, error
        )
    finally:
        unlink(temporary)
