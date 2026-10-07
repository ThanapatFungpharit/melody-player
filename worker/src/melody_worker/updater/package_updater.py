"""The on-disk transaction and activation policy for one package."""

from __future__ import annotations

import importlib.metadata
import json
import logging
import os
import sys
import threading
import uuid
import zipfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from packaging.version import InvalidVersion, Version

from ..file_lock import exclusive_file_lock
from .activation import activate, deactivate
from .cleanup import remove_obsolete, remove_temporary_files
from .constants import DEFAULT_TIMEOUT, MAX_WHEEL_BYTES, STATE_SCHEMA
from .errors import DamagedWheel, WheelRejected, is_transient
from .files import fsync_directory, sha256_file, unlink
from .packages import RuntimePackage
from .probing import probe, read_probed, write_probed
from .records import (
    DownloadFunction,
    RemoteFunction,
    RemoteRelease,
    UpdateResult,
    WheelRecord,
    coerce_version,
)
from .remote import download_file, fetch_remote_release
from .state import entry_shape, record_for_state, same_roles, state_records
from .wheels import parse_wheel_name, temporary_extraction, validate_archive

logger = logging.getLogger(__name__)

# Serializes selection in this process; reentrant for prepare_package.
PREPARE_LOCK = threading.RLock()


class PackageUpdater:
    """Own the on-disk transaction and activation policy for one package."""

    def __init__(
        self,
        package: RuntimePackage,
        *,
        storage_directory: str | Path | None = None,
        bundled_version: str | Version | None = None,
        metadata_url: str | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        download: DownloadFunction | None = None,
        fetch_remote: RemoteFunction | None = None,
        check_remote: bool = True,
    ) -> None:
        self._package = package
        self._name = package.distribution
        self._storage_directory = (
            Path(storage_directory) if storage_directory is not None else None
        )
        self._bundled_version_override = (
            coerce_version(bundled_version) if bundled_version is not None else None
        )
        self._metadata_url = metadata_url or package.metadata_url
        self._timeout = timeout
        self._download_function = download
        self._fetch_remote_function = fetch_remote
        self._check_remote = check_remote
        self._errors: list[str] = []
        self._recovered = False
        self._rolled_back = False
        self._updated = False
        self._pending: dict[str, Any] | None = None
        self._failed: dict[str, Any] | None = None
        self._install_retryable = False
        self._probed: set[str] = set()
        # The exact text of state.json as last read or written.
        self._state_on_disk: str | None = None

    @property
    def package(self) -> RuntimePackage:
        return self._package

    @property
    def storage_directory(self) -> Path | None:
        return self._storage_directory

    def prepare(self) -> UpdateResult:
        with PREPARE_LOCK:
            if self._package.module in sys.modules:
                raise RuntimeError(
                    f"{self._name} selection must finish before its first import; "
                    "restart to update"
                )
            return self._prepare()

    def _prepare(self) -> UpdateResult:
        """Recover, optionally update, and activate without raising failures.

        The outer exception boundary is deliberate: update failures are
        diagnostics, never a reason to stop the application from reaching its
        bundled fallback.
        """

        self._errors = []
        self._recovered = False
        self._rolled_back = False
        self._updated = False

        try:
            storage = self._storage()
        except Exception as error:  # noqa: BLE001 - updater failures are non-fatal
            storage = None
            self._record_error(f"Runtime storage unavailable: {error}")

        bundled = self._bundled_version(storage)
        if bundled is None:
            message = f"Could not determine the bundled {self._name} version"
            self._record_error(message)
            deactivate(storage, self._package)
            return self._result(
                active_version="unknown",
                bundled_version="unknown",
                current=None,
                previous=None,
                remote=None,
                source="bundled",
            )

        if storage is None:
            deactivate(None, self._package)
            return self._result(
                active_version=str(bundled),
                bundled_version=str(bundled),
                current=None,
                previous=None,
                remote=None,
                source="bundled",
            )

        try:
            with exclusive_file_lock(storage / "runtime.lock"):
                return self._prepare_locked(storage, bundled)
        except Exception as error:  # noqa: BLE001 - validation/update failures preserve the bundle
            self._record_error(f"{self._name} updater failure: {error}")
            deactivate(storage, self._package)
            return self._result(
                active_version=str(bundled),
                bundled_version=str(bundled),
                current=None,
                previous=None,
                remote=None,
                source="bundled",
            )

    def _prepare_locked(self, storage: Path, bundled: Version) -> UpdateResult:
        deactivate(storage, self._package)
        if remove_temporary_files(storage, self._package):
            self._recovered = True
        self._probed = read_probed(storage, self._package, bundled)
        state, valid = self._read_state(storage)
        self._pending = state.get("pending") if valid else None
        self._failed = state.get("failed") if valid else None
        records, current, previous = self._recover_records(
            storage, bundled, state, valid
        )
        pending = self._pending
        if pending:
            # Only an explicitly validated transaction may survive the rename /
            # state-commit crash window. A directory listing never grants trust.
            candidate = record_for_state(records, pending.get("wheel"))
            if pending.get("status") == "validated" and candidate is not None:
                previous = current
                current = candidate
            else:
                self._note_failure(
                    pending["wheel"], "Interrupted update", retryable=True
                )
            self._pending = None
            self._recovered = True
        if not valid or not same_roles(state, current, previous):
            self._recovered = True
        durable = self._write_state(storage, current, previous)
        remote = self._remote_release() if self._check_remote else None
        if remote and remote.version > (current.version if current else bundled):
            remote_record = WheelRecord(remote.version, remote.filename, remote.sha256)
            failed = self._failed or {}
            if failed.get("wheel") == remote_record.as_json() and not failed.get(
                "retryable", False
            ):
                self._record_error(
                    f"Skipping previously failed {self._name} {remote.version}"
                )
            elif durable:
                installed = self._update(storage, bundled, remote, current, previous)
                if installed is not None:
                    previous, current = current, installed
        # A wheel that cannot be activated now (a full disk while extracting,
        # say) keeps its role: the cause is environmental, so the next launch
        # tries it again. This launch uses the previous runtime release instead.
        active = self._activate_first(storage, current, previous)
        if active is not current:
            # "updated" means this launch switched to a newly installed release.
            self._updated = False
        if self._write_state(storage, current, previous):
            remove_obsolete(storage, self._package, bundled, current, previous)
        write_probed(storage, self._package, bundled, self._probed, current, previous)
        return self._result(
            active_version=str(active.version if active else bundled),
            bundled_version=str(bundled),
            current=current,
            previous=previous,
            remote=remote,
            source="runtime" if active else "bundled",
        )

    def _bundled_version(self, storage: Path | None) -> Version | None:
        if self._bundled_version_override is not None:
            return self._bundled_version_override
        # A caller may prepare twice in one process during recovery tests or a
        # host restart handoff.  Remove an earlier runtime wheel before asking
        # importlib.metadata, otherwise it could be mistaken for the bundle.
        deactivate(storage, self._package)
        try:
            return coerce_version(importlib.metadata.version(self._name))
        except (
            importlib.metadata.PackageNotFoundError,
            InvalidVersion,
            OSError,
            TypeError,
        ):
            return None

    def _storage(self) -> Path:
        if self._storage_directory is None:
            raise RuntimeError(
                f"No {self._name} runtime storage directory was configured"
            )
        self._storage_directory.mkdir(parents=True, exist_ok=True)
        return self._storage_directory

    def _read_state(self, storage: Path) -> tuple[dict[str, Any], bool]:
        path = storage / "state.json"
        self._state_on_disk = None
        try:
            text = path.read_text(encoding="utf-8")
            value = json.loads(text)
        except FileNotFoundError:
            logger.info("%s runtime state is missing; rebuilding it", self._name)
            self._recovered = True
            return {}, False
        except (OSError, json.JSONDecodeError) as error:
            logger.warning("%s runtime state is invalid: %s", self._name, error)
            self._recovered = True
            return {}, False

        if not isinstance(value, dict) or value.get("schema") not in {1, STATE_SCHEMA}:
            logger.warning("%s runtime state has an unsupported structure", self._name)
            self._recovered = True
            return {}, False
        if not entry_shape(value.get("current"), self._package) or not entry_shape(
            value.get("previous"), self._package
        ):
            logger.warning(
                "%s runtime state contains invalid package metadata", self._name
            )
            self._recovered = True
            return {}, False
        current = value.get("current")
        previous = value.get("previous")
        if (
            isinstance(current, dict)
            and isinstance(previous, dict)
            and current["filename"] == previous["filename"]
        ):
            logger.warning("%s runtime state refers to one wheel twice", self._name)
            self._recovered = True
            return {}, False
        for key in ("pending", "failed"):
            entry = value.get(key)
            if entry is not None and (
                not isinstance(entry, dict)
                or not isinstance(entry.get("wheel"), dict)
                or not entry_shape(entry["wheel"], self._package)
                or (
                    key == "pending"
                    and entry.get("status") not in {"downloading", "validated"}
                )
            ):
                # The installed roles are still trustworthy; drop only the
                # unreadable journal entry rather than every runtime wheel.
                logger.warning(
                    "%s runtime state has an invalid %s entry; discarding it",
                    self._name,
                    key,
                )
                self._recovered = True
                value[key] = None
        self._state_on_disk = text
        return value, True

    def _recover_records(
        self,
        storage: Path,
        bundled: Version,
        state: Mapping[str, Any],
        state_was_valid: bool,
    ) -> tuple[dict[str, WheelRecord], WheelRecord | None, WheelRecord | None]:
        trusted = state_records(state, self._package)
        records: dict[str, WheelRecord] = {}
        for filename, expected in trusted.items():
            try:
                records[filename] = self._validate_wheel(
                    storage / filename, bundled, expected=expected
                )
            except WheelRejected as rejection:
                self._recovered = True
                if rejection.superseded:
                    logger.info(
                        "%s %s is superseded by the bundled release",
                        self._name,
                        filename,
                    )
                else:
                    self._note_failure(
                        expected.as_json(),
                        f"Integrity or compatibility check failed: {rejection.reason}",
                        retryable=rejection.retryable,
                    )
        current = record_for_state(records, state.get("current"))
        previous = record_for_state(records, state.get("previous"))
        if state.get("current") and current is None and previous:
            current, previous = previous, None
            self._rolled_back = True
        if current is None:
            previous = None
        return records, current, previous

    def _validate_wheel(
        self,
        path: Path,
        bundled: Version,
        *,
        expected: WheelRecord | None,
        filename: str | None = None,
    ) -> WheelRecord:
        """Return the trusted record for ``path`` or raise :class:`WheelRejected`."""
        wheel_name = filename or path.name
        parsed = parse_wheel_name(wheel_name, self._package)
        if parsed is None:
            raise WheelRejected(f"{wheel_name} is not a {self._name} wheel")
        version, parsed_filename = parsed
        if version <= bundled:
            raise WheelRejected(
                f"{version} is not newer than the bundled {bundled}", superseded=True
            )
        if not self._package.permits(version):
            raise WheelRejected(f"{version} is outside Melody's compatibility policy")
        if expected is None:
            raise WheelRejected("Wheel has no trusted checksum record")
        if expected.filename != parsed_filename or expected.version != version:
            logger.warning(
                "%s state metadata does not match %s", self._name, wheel_name
            )
            raise WheelRejected("State metadata does not match the wheel")
        try:
            if path.is_symlink() or path.stat().st_size > MAX_WHEEL_BYTES:
                raise ValueError("Runtime wheel is a symlink or exceeds the size limit")
            digest = sha256_file(path)
            if digest != expected.sha256:
                raise DamagedWheel("SHA-256 does not match trusted runtime metadata")
            # The CRC check and the probe depend only on these bytes and on
            # the environment. Bytes with a digest that already passed both
            # here skip them: the probe imports the whole package, which
            # costs seconds of every launch on a phone.
            probed = digest in self._probed
            with zipfile.ZipFile(path) as archive:
                validate_archive(archive, version, self._package)
                if not probed and archive.testzip() is not None:
                    raise ValueError("ZIP CRC validation failed")
            if not probed:
                if self._package.zip_safe:
                    probe(path, version, self._package, timeout=self._timeout)
                else:
                    with temporary_extraction(path) as extracted:
                        probe(extracted, version, self._package, timeout=self._timeout)
                self._probed.add(digest)
        except Exception as error:  # re-raised as a classified WheelRejected
            logger.warning(
                "%s package failed integrity validation: %s (%s)",
                self._name,
                path,
                error,
            )
            # Bytes matching the trusted digest fail the same way every time;
            # only damage and environmental errors are worth another attempt.
            raise WheelRejected(
                str(error) or type(error).__name__, retryable=is_transient(error)
            ) from error
        return WheelRecord(version, parsed_filename, digest)

    def latest_release(self) -> RemoteRelease | None:
        """Return the newest release allowed by Melody's compatibility policy.

        This only reads release metadata; it never downloads or selects a
        package. Network and metadata failures are raised to the caller.
        """
        if self._fetch_remote_function is not None:
            remote = self._fetch_remote_function(self._metadata_url)
        else:
            remote = fetch_remote_release(
                self._metadata_url, self._timeout, self._package
            )
        if remote is not None:
            record = WheelRecord(remote.version, remote.filename, remote.sha256)
            if not entry_shape(
                record.as_json(), self._package
            ) or not self._package.permits(remote.version):
                raise ValueError(
                    "Remote release is outside Melody's runtime compatibility policy"
                )
        return remote

    def _remote_release(self) -> RemoteRelease | None:
        try:
            return self.latest_release()
        except Exception as error:  # noqa: BLE001 - install failures are non-fatal
            self._record_error(f"Could not check for {self._name} updates: {error}")
            logger.warning("Could not check for %s updates: %s", self._name, error)
            return None

    def _install_remote(
        self,
        storage: Path,
        bundled: Version,
        remote: RemoteRelease,
    ) -> WheelRecord | None:
        self._install_retryable = False
        if remote.version <= bundled:
            return None
        final = storage / remote.filename
        temporary = storage / f".{remote.filename}.{uuid.uuid4().hex}.tmp"
        logger.info("Downloading replacement %s %s", self._name, remote.version)
        try:
            if self._download_function is not None:
                self._download_function(remote.url, temporary)
            else:
                download_file(remote.url, temporary, self._timeout)
            # Checks the bytes against PyPI's digest, then imports them.
            installed = self._validate_wheel(
                temporary,
                bundled,
                expected=WheelRecord(remote.version, remote.filename, remote.sha256),
                filename=remote.filename,
            )
            with temporary.open("rb+") as stream:
                os.fsync(stream.fileno())
            os.replace(temporary, final)
            fsync_directory(storage)
            logger.info("Downloaded and verified %s %s", self._name, installed.version)
            return installed
        except Exception as error:  # noqa: BLE001 - install failures are non-fatal
            self._install_retryable = (
                error.retryable
                if isinstance(error, WheelRejected)
                else is_transient(error)
            )
            self._record_error(
                f"Could not install {self._name} {remote.version}: {error}"
            )
            logger.warning(
                "Could not install %s %s: %s", self._name, remote.version, error
            )
            return None
        finally:
            unlink(temporary)

    def _write_state(
        self,
        storage: Path,
        current: WheelRecord | None,
        previous: WheelRecord | None,
    ) -> bool:
        payload = {
            "schema": STATE_SCHEMA,
            "pending": self._pending,
            "failed": self._failed,
            "current": current.as_json() if current else None,
            "previous": previous.as_json() if previous else None,
        }
        encoded = (
            json.dumps(payload, ensure_ascii=True, sort_keys=True, indent=2) + "\n"
        )
        if encoded == self._state_on_disk:
            # Already durable; most launches change nothing, and each commit
            # costs two fsyncs.
            return True
        temporary = storage / "state.json.tmp"
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, storage / "state.json")
            fsync_directory(storage)
            self._state_on_disk = encoded
            return True
        except OSError as error:
            self._record_error(f"Could not persist {self._name} runtime state: {error}")
            logger.warning("Could not persist %s runtime state: %s", self._name, error)
            return False
        finally:
            unlink(temporary)

    def _activate(self, storage: Path, record: WheelRecord) -> None:
        activate(storage, record, self._package)

    def _record_error(self, message: str) -> None:
        self._errors.append(message)

    def _note_failure(
        self, wheel: Mapping[str, Any], reason: str, *, retryable: bool
    ) -> None:
        """Record why ``wheel`` failed, keeping the newest failure.

        Only one failure is stored. It exists to stop re-downloading a broken
        release, which is always the newest one, so an older wheel's failure
        must not replace it.
        """
        existing = (self._failed or {}).get("wheel")
        if isinstance(existing, Mapping):
            try:
                if Version(str(existing["version"])) > Version(str(wheel["version"])):
                    return
            except KeyError, InvalidVersion:
                pass
        self._failed = {"wheel": dict(wheel), "reason": reason, "retryable": retryable}

    def _update(
        self,
        storage: Path,
        bundled: Version,
        remote: RemoteRelease,
        current: WheelRecord | None,
        previous: WheelRecord | None,
    ) -> WheelRecord | None:
        """Download, verify, and commit ``remote`` as the current release.

        Each step is journaled in ``pending`` so that :meth:`_prepare_locked`
        recovers a crash at any point on the next launch.
        """
        wheel = WheelRecord(remote.version, remote.filename, remote.sha256)
        self._pending = {"status": "downloading", "wheel": wheel.as_json()}
        if not self._write_state(storage, current, previous):
            # Nothing was downloaded; a later state write must not persist the
            # intent as an interrupted update.
            self._pending = None
            return None
        installed = self._install_remote(storage, bundled, remote)
        if installed is not None:
            self._pending = {"status": "validated", "wheel": installed.as_json()}
            if self._write_state(storage, current, previous):
                self._pending = None
                failed = self._failed
                if failed and failed.get("wheel") == installed.as_json():
                    # A retried release succeeded; commit that with the roles.
                    self._failed = None
                if self._write_state(storage, installed, current):
                    self._updated = True
                    return installed
                self._failed = failed
        self._note_failure(
            wheel.as_json(),
            "Installation failed",
            retryable=installed is not None or self._install_retryable,
        )
        self._pending = None
        self._write_state(storage, current, previous)
        return None

    def _activate_first(
        self, storage: Path, *candidates: WheelRecord | None
    ) -> WheelRecord | None:
        """Activate the first candidate that can be; ``None`` means the bundle."""
        for record in candidates:
            if record is None:
                continue
            try:
                self._activate(storage, record)
            except Exception as error:  # noqa: BLE001 - fall back to the next release
                self._record_error(
                    f"Could not activate {self._name} {record.version}: {error}"
                )
                logger.warning(
                    "Could not activate %s %s: %s", self._name, record.version, error
                )
                deactivate(storage, self._package)
            else:
                return record
        return None

    def _result(
        self,
        *,
        active_version: str,
        bundled_version: str,
        current: WheelRecord | None,
        previous: WheelRecord | None,
        remote: RemoteRelease | None,
        source: str,
    ) -> UpdateResult:
        return UpdateResult(
            active_version=active_version,
            bundled_version=bundled_version,
            current_version=str(current.version) if current else None,
            previous_version=str(previous.version) if previous else None,
            remote_version=str(remote.version) if remote else None,
            updated=self._updated,
            recovered=self._recovered,
            rolled_back=self._rolled_back,
            active_source=source,
            errors=tuple(self._errors),
        )
