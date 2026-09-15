import hashlib
import logging
from pathlib import Path
from uuid import UUID

from musicplayer.core.media import source_key

__all__ = ["source_key"]

from .config import U32

logger = logging.getLogger(__name__)


def _as_uuid(value: UUID | str) -> UUID:
    return value if isinstance(value, UUID) else UUID(str(value))


def _read_utf8_string(data: bytes, offset: int) -> tuple[str, int]:
    if offset + U32.size > len(data):
        logger.error(
            "Metadata is truncated before UTF-8 field length: offset=%d", offset
        )
        raise ValueError("Truncated music metadata")
    (length,) = U32.unpack_from(data, offset)
    offset += U32.size
    end = offset + length
    if end > len(data):
        logger.error(
            "Metadata is truncated inside UTF-8 field: offset=%d length=%d data_length=%d",
            offset,
            length,
            len(data),
        )
        raise ValueError("Truncated music metadata")
    try:
        value = data[offset:end].decode("utf-8")
    except UnicodeDecodeError:
        logger.exception(
            "Invalid UTF-8 metadata field: offset=%d length=%d", offset, length
        )
        raise
    return value, end


def _pack_utf8_string(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return U32.pack(len(encoded)) + encoded


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    bytes_read = 0
    try:
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(1 << 20), b""):
                bytes_read += len(chunk)
                digest.update(chunk)
    except OSError:
        logger.exception("SHA-256 calculation failed while reading file: path=%s", path)
        raise
    result = digest.hexdigest()
    return result
