from pathlib import Path

import flet as ft


@ft.control("SharedAudioStorage")
class SharedAudioStorage(ft.Service):
    """Publish a staged track to Android's public MediaStore music folder."""

    async def publish(self, source: str | Path) -> Path:
        result = await self._invoke_method(
            "publish",
            {"source": str(Path(source)), "relative_path": "Melody"},
        )
        if not isinstance(result, dict) or not result.get("path"):
            raise RuntimeError("Android did not return the published music path")
        return Path(str(result["path"]))
