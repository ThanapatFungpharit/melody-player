"""Small filesystem primitives shared by durable state owners."""

from __future__ import annotations

import logging
import os
import shutil
import sqlite3
import tempfile
import threading
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Self


def _cleanup_temporary(path: Path) -> None:
    try:
        if path.exists():
            path.unlink()
    except OSError:
        logging.getLogger(__name__).warning(
            "Could not remove temporary file %s", path, exc_info=True
        )


def sync_directory(directory: Path) -> None:
    """Flush a committed rename without misreporting it as an aborted write.

    A directory barrier can be unsupported or fail after the file was replaced.
    Raising then would make callers roll back memory although disk has committed.
    Report the durability limitation while preserving the committed state.
    """
    if os.name == "nt":
        return
    try:
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        logging.getLogger(__name__).warning(
            "File replacement committed, but directory durability could not be confirmed: %s",
            directory,
            exc_info=True,
        )


def atomic_write(path: Path, contents: bytes) -> None:
    """Replace a file only after all bytes have reached durable storage."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        _cleanup_temporary(temporary)


class DatabaseError(OSError):
    """A durable commit failed; the transaction was rolled back."""


class Database:
    """One process-lifetime SQLite connection in write-ahead-log mode.

    WAL appends each commit instead of rewriting a whole state file, so a small
    change costs a small write. ``synchronous="FULL"`` makes every commit
    survive power loss; ``"NORMAL"`` survives application crashes and may lose
    only the latest commits on power loss, never consistency. Callers keep
    their own in-memory model and roll it back when ``transaction`` raises.

    The connection is shared across threads and serialized by an internal
    lock. It holds the file open until ``close``; process exit without closing
    is safe because SQLite recovers the log on the next open.
    """

    def __init__(self, path: Path, *, synchronous: str = "FULL") -> None:
        if synchronous not in {"FULL", "NORMAL"}:
            raise ValueError(f"Unsupported synchronous mode: {synchronous}")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        try:
            connection = sqlite3.connect(
                self.path, autocommit=True, check_same_thread=False
            )
        except sqlite3.Error as error:
            raise ValueError(f"Could not open {self.path}: {error}") from error
        try:
            # WAL is persistent in the file; a filesystem that cannot map the
            # shared-memory index keeps the rollback journal, which is still
            # atomic, only slower.
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute(f"PRAGMA synchronous={synchronous}")
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA busy_timeout=5000")
            (result,) = connection.execute("PRAGMA quick_check").fetchone()
            if result != "ok":
                raise sqlite3.DatabaseError(result)
        except sqlite3.Error as error:
            connection.close()
            raise ValueError(f"{self.path} is not a valid database: {error}") from error
        self._connection: sqlite3.Connection | None = connection

    def _require_open(self) -> sqlite3.Connection:
        if self._connection is None:
            raise DatabaseError(f"Database is closed: {self.path}")
        return self._connection

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        """Run writes atomically; any exception rolls every statement back."""
        with self._lock:
            connection = self._require_open()
            try:
                connection.execute("BEGIN IMMEDIATE")
            except sqlite3.Error as error:
                raise DatabaseError(f"Could not write {self.path}: {error}") from error
            try:
                yield connection
                connection.execute("COMMIT")
            except BaseException as error:
                try:
                    if connection.in_transaction:
                        connection.execute("ROLLBACK")
                except sqlite3.Error:
                    logging.getLogger(__name__).warning(
                        "Could not roll back %s", self.path, exc_info=True
                    )
                if isinstance(error, sqlite3.Error):
                    raise DatabaseError(
                        f"Could not write {self.path}: {error}"
                    ) from error
                raise

    def query(self, sql: str, parameters: Sequence[object] = ()) -> list[Any]:
        with self._lock:
            try:
                return self._require_open().execute(sql, parameters).fetchall()
            except sqlite3.Error as error:
                raise DatabaseError(f"Could not read {self.path}: {error}") from error

    def has_table(self, name: str) -> bool:
        return bool(
            self.query(
                "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?",
                (name,),
            )
        )

    def close(self) -> None:
        with self._lock:
            if self._connection is not None:
                self._connection.close()
                self._connection = None

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def retire_legacy_file(path: Path) -> None:
    """Keep an imported legacy file as a backup that is never imported again."""
    try:
        os.replace(path, path.with_name(f"{path.name}.migrated"))
    except FileNotFoundError:
        return
    except OSError:
        logging.getLogger(__name__).warning(
            "Imported legacy state, but could not rename %s", path, exc_info=True
        )


def atomic_copy(source: Path, destination: Path) -> None:
    """Copy across filesystems without exposing a partial destination file."""
    descriptor, name = tempfile.mkstemp(
        dir=destination.parent, prefix=".melody-import-", suffix=".tmp"
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output, 1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        sync_directory(destination.parent)
    finally:
        _cleanup_temporary(temporary)


@contextmanager
def exclusive_file_lock(path: Path) -> Iterator[None]:
    """Nonblocking OS lock; process termination releases it automatically.

    The lock file must remain in place: unlinking it can create two lock owners.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as stream:
        if os.name == "nt":
            import msvcrt

            if path.stat().st_size == 0:
                stream.write(b"\0")
                stream.flush()
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            try:
                yield
            finally:
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                yield
            finally:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
