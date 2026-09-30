from __future__ import annotations

import flet as ft

# ---------------------------------------------------------------------------
# Accent-color palettes
# ---------------------------------------------------------------------------

THEME_PALETTES: dict[str, str] = {
    "violet": "#8B5CF6",
    "ocean": "#0EA5E9",
    "rose": "#F43F5E",
    "emerald": "#10B981",
    "amber": "#F59E0B",
    "slate": "#64748B",
    "blue": "#2563EB",
    "teal": "#0D9488",
    "coral": "#F97316",
    "magenta": "#D946EF",
    "lime": "#84CC16",
}

DEFAULT_PALETTE = "violet"
TOUCH_TARGET = 48
CARD_RADIUS = 18
FONT_FAMILY = "Segoe UI"

DEFAULT_ACCENT = THEME_PALETTES[DEFAULT_PALETTE]


def accent_color(name: str) -> str:
    """Return the hex accent for *name*, falling back to the default palette."""
    return THEME_PALETTES.get(name, THEME_PALETTES[DEFAULT_PALETTE])


def palette_names() -> list[str]:
    """Ordered list of available palette keys."""
    return list(THEME_PALETTES.keys())


# ---------------------------------------------------------------------------
# Theme builder
# ---------------------------------------------------------------------------


def build_theme(seed: str = DEFAULT_ACCENT) -> ft.Theme:
    return ft.Theme(
        color_scheme_seed=seed,
        use_material3=True,
        visual_density=ft.VisualDensity.COMFORTABLE,
        font_family=FONT_FAMILY,
    )


# ---------------------------------------------------------------------------
# Shared card helper
# ---------------------------------------------------------------------------


def card(
    content: ft.Control,
    *,
    padding: int = 18,
    expand: bool | int | None = None,
    key: ft.KeyValue | None = None,
) -> ft.Container:
    return ft.Container(
        content=content,
        padding=padding,
        border_radius=CARD_RADIUS,
        bgcolor=ft.Colors.SURFACE_CONTAINER,
        border=ft.Border.all(1, ft.Colors.OUTLINE_VARIANT),
        expand=expand,
        key=key,
    )
