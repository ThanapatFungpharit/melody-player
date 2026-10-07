"""Crash-safe, dependency-free-at-runtime updates for bundled Python packages.

Melody updates two pure Python distributions this way: yt-dlp (downloads and
stream URLs) and ytmusicapi (YouTube Music search, radio, and lyrics).

The application package is intentionally never modified.  A verified pure
Python wheel is placed on ``sys.path`` ahead of the packaged distribution, so
the packaged release remains an immutable last-resort fallback on every
platform Melody's embedded interpreter supports.  Packages that read data
files from disk (ytmusicapi's gettext catalogs) cannot be imported from a
zip, so their verified wheel is extracted and the directory is activated.

Modules:

- :mod:`.packages`: the updatable distributions and their trust checks.
- :mod:`.records`: value types shared by every module.
- :mod:`.selection`: :func:`prepare_package`, once per process at startup.
- :mod:`.package_updater`: :class:`PackageUpdater`, the crash-safe install
  transaction and recovery for one package.
- :mod:`.state`: the shape of ``state.json``.
- :mod:`.wheels`: wheel filenames, archive validation, and extraction.
- :mod:`.probing`: import probes and the record of probes already passed.
- :mod:`.remote`: PyPI release lookup and downloads over verified HTTPS.
- :mod:`.activation`: placing a release on ``sys.path``.
- :mod:`.cleanup`: removing temporary and obsolete runtime files.
- :mod:`.constants`: limits, timeouts, file names, and formats.
- :mod:`.errors` and :mod:`.files`: shared failure and filesystem helpers.
"""

from .package_updater import PackageUpdater
from .packages import PACKAGES, YT_DLP, YTMUSICAPI, RuntimePackage
from .records import RemoteRelease, UpdateResult, WheelRecord
from .selection import prepare_package

__all__ = [
    "PACKAGES",
    "YTMUSICAPI",
    "YT_DLP",
    "PackageUpdater",
    "RemoteRelease",
    "RuntimePackage",
    "UpdateResult",
    "WheelRecord",
    "prepare_package",
]
