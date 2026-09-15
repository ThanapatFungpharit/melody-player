import os
import re
from pathlib import Path


def process_file(file_path):
    text = file_path.read_text("utf-8")

    # We replace AppProtocol with AppContext where necessary
    # Or actually, we leave AppProtocol around but change it to mean "the main app"

    # 1. In pages/components, change `class X(_Base):` to `class X:` and add `__init__(self, app: AppProtocol): self.app = app`
    if "class " in text and "_Base" in text:
        text = re.sub(
            r"class (\w+)\(_Base\):\n",
            r'class \1:\n    def __init__(self, app: "AppProtocol"):\n        self.app = app\n',
            text,
        )

    file_path.write_text(text, "utf-8")


def main():
    base = Path("src/musicplayer/ui")
    for root, _, files in os.walk(base):
        for f in files:
            if f.endswith(".py"):
                process_file(Path(root) / f)


if __name__ == "__main__":
    main()
