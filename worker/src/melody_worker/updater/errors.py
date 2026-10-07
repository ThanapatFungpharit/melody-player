"""How a rejected runtime wheel is classified."""

from __future__ import annotations

import http.client
import subprocess


class WheelRejected(Exception):
    """A runtime wheel failed validation.

    ``retryable`` failures may pass with a fresh copy of the same release
    (damaged bytes, I/O errors, timeouts); the others are properties of the
    release itself. ``superseded`` wheels are merely not newer than the bundle.
    """

    def __init__(
        self, reason: str, *, retryable: bool = False, superseded: bool = False
    ) -> None:
        super().__init__(reason)
        self.reason = reason
        self.retryable = retryable
        self.superseded = superseded


class DamagedWheel(ValueError):
    """The bytes differ from their trusted record; a new download repairs them."""


def is_transient(error: BaseException) -> bool:
    """Whether another attempt at the same release might succeed."""
    return isinstance(
        error,
        (
            OSError,
            MemoryError,
            subprocess.TimeoutExpired,
            http.client.HTTPException,
            DamagedWheel,
        ),
    )
