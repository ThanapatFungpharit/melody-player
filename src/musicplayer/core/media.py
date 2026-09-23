"""Provider identities independent of titles, paths, UI, and storage records."""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit

YOUTUBE_PROVIDER_ID = "youtube"
YOUTUBE_MUSIC_NAME = "YouTube Music"
YOUTUBE_MUSIC_HOST = "music.youtube.com"
YOUTUBE_HOSTS = frozenset(
    {
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        YOUTUBE_MUSIC_HOST,
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
        "youtu.be",
    }
)


def is_http_url(value: str) -> bool:
    return urlsplit(value.strip()).scheme.casefold() in {"http", "https"}


def is_youtube_url(value: str) -> bool:
    """Return whether *value* is an HTTP(S) URL hosted by YouTube."""
    parsed = urlsplit(value.strip())
    return (
        parsed.scheme.casefold() in {"http", "https"}
        and (parsed.hostname or "").casefold() in YOUTUBE_HOSTS
    )


def is_youtube_playlist_url(value: str) -> bool:
    """Return whether *value* identifies a specific YouTube playlist."""
    parsed = urlsplit(value.strip())
    return is_youtube_url(value) and bool(parse_qs(parsed.query).get("list"))


def youtube_music_search_url(term: str, *, section: str = "songs") -> str:
    """Build a YouTube Music search URL understood by yt-dlp."""
    fragment = f"#{section.strip()}" if section.strip() else ""
    return f"https://{YOUTUBE_MUSIC_HOST}/search?{urlencode({'q': term.strip()})}{fragment}"


def youtube_music_track_url(url: str, media_id: str = "") -> str:
    """Return a canonical YouTube Music watch URL for a YouTube video."""
    if not url or not is_http_url(url):
        video_id = media_id or url
        return (
            f"https://{YOUTUBE_MUSIC_HOST}/watch?{urlencode({'v': video_id})}"
            if video_id
            else url
        )

    parsed = urlsplit(url)
    host = (parsed.hostname or "").casefold()
    if host not in YOUTUBE_HOSTS:
        return url
    if host == "youtu.be":
        video_id = parsed.path.strip("/") or media_id
    elif parsed.path.rstrip("/") == "/watch":
        video_id = (parse_qs(parsed.query).get("v") or [media_id])[0]
    elif parsed.path.startswith(("/shorts/", "/live/", "/embed/")):
        video_id = parsed.path.rstrip("/").rsplit("/", 1)[-1] or media_id
    else:
        return url
    return (
        f"https://{YOUTUBE_MUSIC_HOST}/watch?{urlencode({'v': video_id})}"
        if video_id
        else url
    )


@dataclass(frozen=True)
class MediaIdentity:
    provider: str
    media_id: str

    @property
    def key(self) -> str:
        return f"{self.provider}:{self.media_id}"

    @classmethod
    def from_url(cls, source: str) -> MediaIdentity | None:
        parsed = urlsplit(source.strip())
        host = (parsed.hostname or "").casefold()
        parts = parsed.path.strip("/").split("/")
        media_id = ""
        if host == "youtu.be":
            media_id = parts[0]
        elif host in YOUTUBE_HOSTS:
            media_id = parse_qs(parsed.query).get("v", [""])[0]
            if (
                not media_id
                and len(parts) == 2
                and parts[0] in {"shorts", "embed", "live"}
            ):
                media_id = parts[1]
        if media_id and parsed.scheme.casefold() in {"http", "https"}:
            return cls(YOUTUBE_PROVIDER_ID, media_id)
        return None


def youtube_music_radio_url(source: str) -> str:
    """Build a YouTube Music radio URL seeded by a specific track."""
    identity = MediaIdentity.from_url(source)
    if identity is None or identity.provider != YOUTUBE_PROVIDER_ID:
        raise ValueError("A YouTube track URL is required to start a radio mix")
    query = urlencode(
        {
            "v": identity.media_id,
            "list": f"RDAMVM{identity.media_id}",
            "start_radio": "1",
        }
    )
    return f"https://{YOUTUBE_MUSIC_HOST}/watch?{query}"


def source_key(source: str) -> str:
    identity = MediaIdentity.from_url(source)
    if identity is not None:
        return identity.key
    parsed = urlsplit(source.strip())
    query = parse_qs(parsed.query)
    filtered = [
        (name, value)
        for name in sorted(query)
        if not name.casefold().startswith("utm_")
        for value in query[name]
    ]
    return urlunsplit(
        (
            parsed.scheme.casefold(),
            parsed.netloc.casefold().removeprefix("www."),
            parsed.path.rstrip("/"),
            urlencode(filtered),
            "",
        )
    )
