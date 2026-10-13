"""The distributions Melody updates at runtime, and what makes each trusted.

``tools/tests/test_build_app.py`` parses this file for ``RuntimePackage(...)``
calls, so keep every package declared here with literal keyword arguments.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from packaging.specifiers import SpecifierSet
from packaging.version import Version


@dataclass(frozen=True)
class RuntimePackage:
    """One updatable distribution and the checks that make a wheel trusted."""

    distribution: str
    """The PyPI project name, such as ``yt-dlp``."""
    module: str
    """The top-level import name, such as ``yt_dlp``."""
    allowed: SpecifierSet
    """Releases Melody has been tested against."""
    required_members: frozenset[str]
    """Archive members a genuine wheel must contain."""
    probe: str
    """Import and API check run after :data:`~.probing.PROBE_PRELUDE`."""
    zip_safe: bool = True
    """Whether the package can be imported straight from its wheel."""
    wheel_name: re.Pattern[str] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        # Wheel filenames normalize "-" in project names to "_".
        project = re.escape(self.distribution).replace(r"\-", "[_-]")
        object.__setattr__(
            self,
            "wheel_name",
            re.compile(
                rf"^{project}-(?P<version>[^-]+)-py3-none-any\.whl$", re.IGNORECASE
            ),
        )

    def permits(self, version: Version) -> bool:
        """Whether ``version`` is a final release inside :attr:`allowed`.

        Only plain releases qualify: no pre (``a``/``b``/``rc``), dev, post,
        or local segments. packaging 26 lets pre-releases satisfy a specifier
        set without pre-release bounds, which would select yt-dlp's nightly
        uploads: they report a different ``__version__`` and always fail the
        import probe.
        """
        if (
            version.is_prerelease
            or version.is_devrelease
            or version.is_postrelease
            or version.local is not None
        ):
            return False
        return self.allowed.contains(version, prereleases=False)

    @property
    def metadata_url(self) -> str:
        """PyPI's JSON simple index (PEP 691), which lists every release."""
        return f"https://pypi.org/simple/{self.distribution}/"

    @property
    def wheel_prefix(self) -> str:
        return f"{self.distribution.replace('-', '_')}-"


YT_DLP = RuntimePackage(
    distribution="yt-dlp",
    module="yt_dlp",
    allowed=SpecifierSet(">=2026.8.19,<2027"),
    required_members=frozenset({"yt_dlp/__init__.py", "yt_dlp/version.py"}),
    probe="""
import yt_dlp
from yt_dlp.version import __version__
require_location(yt_dlp)
if Version(__version__) != Version(expected_version):
    raise ValueError('Runtime version mismatch')
if not callable(yt_dlp.YoutubeDL):
    raise ValueError('Missing YoutubeDL API')
if not issubclass(yt_dlp.CookieLoadError, Exception):
    raise ValueError('Missing cookie error API')
with yt_dlp.YoutubeDL({'quiet': True, 'no_warnings': True, 'skip_download': True}) as client:
    if not callable(client.extract_info) or not callable(client.download):
        raise ValueError('Incompatible API')
""",
)

YTMUSICAPI = RuntimePackage(
    distribution="ytmusicapi",
    module="ytmusicapi",
    allowed=SpecifierSet(">=1.12.3,<2"),
    required_members=frozenset(
        {
            "ytmusicapi/__init__.py",
            "ytmusicapi/ytmusic.py",
            "ytmusicapi/locales/en/LC_MESSAGES/base.mo",
        }
    ),
    probe="""
import importlib.metadata
import locale
import ytmusicapi
require_location(ytmusicapi)
installed = next(
    iter(importlib.metadata.distributions(name='ytmusicapi', path=[probe_path])),
    None,
)
if installed is None or Version(installed.version) != Version(expected_version):
    raise ValueError('Runtime version mismatch')
from ytmusicapi import YTMusic
for name in ('search', 'get_watch_playlist', 'get_lyrics', 'get_playlist'):
    if not callable(getattr(YTMusic, name, None)):
        raise ValueError('Missing YTMusic API')
saved_locale = locale.setlocale(locale.LC_ALL)
try:
    YTMusic()  # loads the gettext catalogs; makes no requests
finally:
    locale.setlocale(locale.LC_ALL, saved_locale)
""",
    zip_safe=False,
)

PACKAGES: dict[str, RuntimePackage] = {
    package.distribution: package for package in (YT_DLP, YTMUSICAPI)
}
