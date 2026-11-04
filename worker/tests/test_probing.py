"""An import probe inside the app's own process must leave no trace behind."""

from __future__ import annotations

import subprocess
import sys

import pytest

# In a process of its own, since yt-dlp's import changes urllib3 for the process.
_SCRIPT = """
import importlib.metadata
import importlib.util
import re
import sys
from pathlib import Path

from packaging.version import Version

from melody_worker.updater.packages import YT_DLP
from melody_worker.updater.probing import probe

# Embedded builds probe in this process, as frozen ones do.
sys.frozen = True
{before}
location = Path(importlib.util.find_spec("yt_dlp").origin).parent.parent
version = Version(importlib.metadata.version("yt-dlp"))
for _ in range(2):  # A wheel, then its extracted copy.
    probe(location, version, YT_DLP, timeout=120)
assert "yt_dlp" not in sys.modules

import yt_dlp  # noqa: E402
import urllib3.util.url as url  # noqa: E402

# The app's real import still gets to patch urllib3, once.
assert isinstance(url._PERCENT_RE.re, re.Pattern), type(url._PERCENT_RE.re)
assert url.parse_url("https://music.youtube.com/watch?v=x").host == "music.youtube.com"
assert url.parse_url("https://e.com/%aa%BB").path == "/%aa%BB"
"""


@pytest.mark.parametrize(
    "before",
    ["", "import urllib3.util.url"],
    ids=["urllib3 first imported by the probe", "urllib3 already imported"],
)
def test_a_probe_leaves_the_real_import_a_working_urllib3(before: str) -> None:
    result = subprocess.run(
        [sys.executable, "-c", _SCRIPT.format(before=before)],
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    assert result.returncode == 0, result.stderr[-1500:]
