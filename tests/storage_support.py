"""Temporary data directories that release SQLite files before removal.

Stores keep one database connection for the process lifetime. Windows cannot
remove an open file, so a directory closes every database opened while it was
alive before deleting itself.
"""

from __future__ import annotations

import tempfile
from typing import Any

from musicplayer.core.storage import Database

_active: list[DataDirectory] = []
_original_init = Database.__init__


def _tracking_init(self: Database, *args: Any, **kwargs: Any) -> None:
    _original_init(self, *args, **kwargs)
    for directory in _active:
        directory.databases.append(self)


Database.__init__ = _tracking_init


class DataDirectory(tempfile.TemporaryDirectory):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.databases: list[Database] = []
        _active.append(self)

    def cleanup(self) -> None:
        if self in _active:
            _active.remove(self)
        for database in self.databases:
            database.close()
        self.databases.clear()
        super().cleanup()
