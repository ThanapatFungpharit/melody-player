"""Render Melody's bundled app icons from the in-app mark.

The icons reproduce ``BrandMark`` (app/lib/ui/shared/widgets.dart) in the light
theme: the ``graphic_eq_rounded`` glyph from Flutter's Material Icons font on a
primary-to-tertiary gradient tile, in the default violet accent. Pillow comes
with the tools' dev dependencies:

    uv run python -m tools.build.icons
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from functools import cache
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

from tools.common import APP, executable, load_env_file

# Drawn this many times larger than the output, then downsampled, for smooth edges.
SUPERSAMPLE = 4
MASTER = 1024

# BrandMark's gradient in the light theme: scheme.primary, then tertiary at 55%
# over primary. app/test/ui/app_icon_test.dart checks it.
COLORS: list[str] = json.loads(
    (Path(__file__).with_name("icon_colors.json")).read_text(encoding="utf-8")
)
# scheme.onPrimary is white for every accent.
GLYPH = (255, 255, 255)
# BrandMark's proportions: corner radius and glyph size as fractions of the tile.
RADIUS = 0.3
GLYPH_SCALE = 0.62
# Icons.graphic_eq_rounded.
CODEPOINT = ""

ANDROID_RES = APP / "android" / "app" / "src" / "main" / "res"
ANDROID_DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}
WINDOWS_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]

Rgb = tuple[int, int, int]


def _rgb(value: str) -> Rgb:
    return (int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16))


def _colors() -> tuple[Rgb, Rgb]:
    start, end = COLORS
    return _rgb(start), _rgb(end)


@cache
def _icon_font_path() -> Path:
    load_env_file()
    sdk = Path(executable("flutter")).resolve().parents[1]
    fonts = sdk / "bin" / "cache" / "artifacts" / "material_fonts"
    # Its name's case differs between Flutter releases.
    for path in fonts.glob("*"):
        if path.name.lower() == "materialicons-regular.otf":
            return path
    raise SystemExit(f"No Material Icons in {fonts}; run `flutter precache` first")


def _gradient(size: int, start: Rgb, end: Rgb) -> Image.Image:
    """BrandMark's top-left to bottom-right gradient filling a square."""
    down = Image.linear_gradient("L").resize((size, size))
    ramp = ImageChops.add(down, down.rotate(90), scale=2)
    first = Image.new("RGB", (size, size), start)
    last = Image.new("RGB", (size, size), end)
    return Image.composite(last, first, ramp).convert("RGBA")


def _glyph_mask(size: int, scale: float) -> Image.Image:
    """The glyph laid out as Flutter's Icon does, in a centred box ``scale`` wide.

    Material Icons glyphs fill a square em box whose ascent is the full em, so
    the box's top-left corner is the text origin.
    """
    box = size * scale
    font = ImageFont.truetype(str(_icon_font_path()), round(box))
    mask = Image.new("L", (size, size), 0)
    origin = (size - box) / 2
    ImageDraw.Draw(mask).text(
        (origin, origin), CODEPOINT, fill=255, font=font, anchor="la"
    )
    return mask


def _rounded_mask(size: int, inset: float, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - inset - 1, size - inset - 1), radius=radius, fill=255
    )
    return mask


def _tile(px: int, *, inset: float, radius: float, shadow: bool = False) -> Image.Image:
    """The default mark at ``px`` pixels; inset and radius are fractions of it."""
    size = px * SUPERSAMPLE
    body_size = size - 2 * inset * size
    shape = _rounded_mask(size, inset * size, radius * body_size)
    art = _gradient(size, *_colors())
    note = _glyph_mask(size, GLYPH_SCALE * body_size / size)
    art = Image.composite(Image.new("RGBA", (size, size), (*GLYPH, 255)), art, note)
    art.putalpha(shape)
    if shadow:
        drop = shape.filter(ImageFilter.GaussianBlur(size * 0.012)).point(
            lambda v: v * 0.45
        )
        drop = ImageChops.offset(drop, 0, round(size * 0.01))
        base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        base.putalpha(drop)
        art = Image.alpha_composite(base, art)
    return art.resize((px, px), Image.Resampling.LANCZOS)


def _save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)
    print(f"wrote {path.relative_to(APP.parent)}")


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {path.relative_to(APP.parent)}")


def _macos() -> None:
    directory = APP / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents = json.loads((directory / "Contents.json").read_text(encoding="utf-8"))
    for entry in contents["images"]:
        points = float(entry["size"].split("x")[0])
        px = round(points * int(entry["scale"].rstrip("x")))
        # macOS icons carry their own rounded body inside Apple's 824/1024 grid.
        image = _tile(px, inset=100 / MASTER, radius=RADIUS, shadow=True)
        _save(image, directory / entry["filename"])


def _hex(color: Iterable[float]) -> str:
    return "#" + "".join(f"{min(255, max(0, round(c))):02X}" for c in color)


def _android_background() -> str:
    """A gradient drawable for the 108dp adaptive background.

    Launchers show only the centre 72dp, so the gradient is extended a quarter
    of its length past each end to show BrandMark's colors at the visible corners.
    """
    start, end = _colors()

    def at(t: float) -> str:
        return _hex(tuple(a + (b - a) * t for a, b in zip(start, end, strict=True)))

    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated by tools/build/icons.py: the BrandMark gradient. -->\n"
        '<shape xmlns:android="http://schemas.android.com/apk/res/android">\n'
        "    <gradient\n"
        '        android:angle="315"\n'
        f'        android:startColor="{at(-0.25)}"\n'
        f'        android:endColor="{at(1.25)}" />\n'
        "</shape>\n"
    )


def _android() -> None:
    # minSdk is 29, so adaptive icons are all Android ever loads; the bitmap
    # launcher icons and backgrounds of older versions of this script go.
    for density in ANDROID_DENSITIES:
        for name in ("ic_launcher.png", "ic_launcher_background.png"):
            (ANDROID_RES / f"mipmap-{density}" / name).unlink(missing_ok=True)
    for density, factor in ANDROID_DENSITIES.items():
        # Adaptive layers are 108dp; launchers mask them to the centre 72dp and
        # only promise the centre 66dp; the glyph keeps its BrandMark size
        # relative to the visible 72dp.
        layer = round(108 * factor)
        size = layer * SUPERSAMPLE
        note = _glyph_mask(size, GLYPH_SCALE * 72 / 108)
        foreground = Image.new("RGBA", (size, size), (*GLYPH, 0))
        foreground.putalpha(note)
        foreground = foreground.resize((layer, layer), Image.Resampling.LANCZOS)
        directory = ANDROID_RES / f"mipmap-{density}"
        _save(foreground, directory / "ic_launcher_foreground.png")
        _save(foreground, directory / "ic_launcher_monochrome.png")
    _write(
        ANDROID_RES / "drawable" / "ic_launcher_background.xml",
        _android_background(),
    )
    _write(
        ANDROID_RES / "mipmap-anydpi-v26" / "ic_launcher.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated by tools/build/icons.py. -->\n"
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
        "</adaptive-icon>\n",
    )


def _windows() -> None:
    master = _tile(256, inset=0.03, radius=RADIUS)
    path = APP / "windows" / "runner" / "resources" / "app_icon.ico"
    master.save(path, sizes=[(s, s) for s in WINDOWS_SIZES])
    print(f"wrote {path.relative_to(APP.parent)}")


def _linux() -> None:
    path = APP / "linux" / "runner" / "resources" / "app_icon.png"
    _save(_tile(256, inset=0.03, radius=RADIUS), path)


def main() -> None:
    _android()
    _macos()
    _windows()
    _linux()


if __name__ == "__main__":
    main()
