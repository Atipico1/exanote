#!/usr/bin/env python3
"""Draw Exanote's mark and write the app icon and brand files from one set of coordinates.

The mark is a page folded at its top-right corner. Two slits cut in from the right turn the page
into an E, and one narrow cut frees the fold. Coordinates are fractions of the square tile, so the
icon, the SVG and LogoMark in native/App/Brand.swift draw the same shape at any size.

    .venv/bin/python scripts/brand_assets.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "native/App/Assets.xcassets/AppIcon.appiconset"
BRAND = ROOT / "docs/brand"
SITE_ICON = ROOT / "site/icon.png"

LIME = (0xD1, 0xFE, 0x17)
DEEP_LIME = (0x4A, 0x6A, 0x00)
INK = (0x0F, 0x11, 0x13)
TILE = (0x16, 0x18, 0x1B)   # one flat color, no gradient
PAPER = (0xF6, 0xF6, 0xF4)

# --- Geometry, in fractions of the tile side (keep in sync with LogoMark in Brand.swift) ---
# The page outline, clockwise, taking in the two slits that open to the right. The cut at 0.56-0.59
# frees the fold, a separate triangle whose lower edge is the top of the first slit.
PAGE = [(0.26, 0.21), (0.56, 0.21), (0.56, 0.36), (0.435, 0.36), (0.435, 0.435), (0.74, 0.435),
        (0.74, 0.565), (0.435, 0.565), (0.435, 0.64), (0.74, 0.64), (0.74, 0.79), (0.26, 0.79)]
FOLD = [(0.59, 0.21), (0.74, 0.36), (0.59, 0.36)]
CORNER = 0.2237           # macOS icon corner radius / side


def draw_mark(size: int, color=LIME) -> Image.Image:
    """Transparent image of the mark alone, drawn at 4x and reduced for clean edges."""
    scale = size * 4
    mask = Image.new("L", (scale, scale), 0)
    draw = ImageDraw.Draw(mask)
    for shape in (PAGE, FOLD):
        draw.polygon([(x * scale, y * scale) for x, y in shape], fill=255)
    image = Image.new("RGBA", (scale, scale), (*color, 255))
    image.putalpha(mask)
    return image.resize((size, size), Image.LANCZOS)


def app_icon(size: int = 1024) -> Image.Image:
    """macOS icon: 824/1024 tile with the system corner radius and a soft drop shadow."""
    inset, side = round(size * 100 / 1024), round(size * 824 / 1024)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset * 4, inset * 4, (inset + side) * 4, (inset + side) * 4], radius=side * 4 * CORNER, fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda a: a * 0.32))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -round(size * 0.012))).filter(ImageFilter.GaussianBlur(size * 0.014))
    canvas.alpha_composite(shadow)
    tile = Image.new("RGBA", (size, size), (*TILE, 255))
    tile.putalpha(mask)
    canvas.alpha_composite(tile)
    mark = draw_mark(side)
    canvas.alpha_composite(mark, (inset, inset))
    return canvas


def mark_svg(color="#D1FE17", tile="#16181B", tile_corner=CORNER) -> str:
    n = lambda v: f"{v * 100:.2f}"
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="Exanote">']
    if tile:
        parts.append(f'<rect width="100" height="100" rx="{n(tile_corner)}" fill="{tile}"/>')
    d = " ".join("M " + " L ".join(f"{n(x)} {n(y)}" for x, y in shape) + " Z" for shape in (PAGE, FOLD))
    parts.append(f'<path fill="{color}" d="{d}"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


# --- Wordmark: capital E, SF Pro Display semibold, tight; only the x is lime ---
SF = "/System/Library/Fonts/SFNS.ttf"
WORDMARK_WEIGHT = 620
WORDMARK_TRACKING = -0.02  # of the font size, matching Text.tracking in Typography.swift


def wordmark(size: int, text_color, x_color) -> Image.Image:
    font = ImageFont.truetype(SF, size)
    font.set_variation_by_axes([100, 96, 400, WORDMARK_WEIGHT])  # width, optical size, grade, weight
    ascent, descent = font.getmetrics()
    advances = [font.getlength(ch) + size * WORDMARK_TRACKING for ch in "Exanote"]
    image = Image.new("RGBA", (int(sum(advances)) + size // 4, ascent + descent), (0, 0, 0, 0))
    draw, x = ImageDraw.Draw(image), 0.0
    for ch, advance in zip("Exanote", advances):
        draw.text((x, 0), ch, font=font, fill=(*(x_color if ch == "x" else text_color), 255))
        x += advance
    return image.crop(image.getbbox())


def lockup(text_color, x_color) -> Image.Image:
    """Icon tile + wordmark on a transparent background, for the README header."""
    height = 240
    icon = app_icon(1024).crop((100, 100, 924, 924)).resize((height, height), Image.LANCZOS)
    word = wordmark(190, text_color, x_color)
    gap = round(height * 0.26)
    image = Image.new("RGBA", (height + gap + word.width, height), (0, 0, 0, 0))
    image.alpha_composite(icon)
    # Sit the x-height on the tile's optical center.
    image.alpha_composite(word, (height + gap, (height - word.height) // 2 + round(height * 0.03)))
    return image


def main() -> None:
    icon = app_icon(1024)
    for path in sorted(ICONSET.glob("icon_*.png")):
        size = Image.open(path).size[0]
        (icon if size == 1024 else icon.resize((size, size), Image.LANCZOS)).save(path)
    icon.resize((256, 256), Image.LANCZOS).save(SITE_ICON)
    BRAND.mkdir(parents=True, exist_ok=True)
    (BRAND / "exanote-mark.svg").write_text(mark_svg())
    icon.save(BRAND / "exanote-icon-1024.png")
    lockup(INK, DEEP_LIME).save(BRAND / "exanote-lockup-light.png")   # for light backgrounds
    lockup((0xF2, 0xF3, 0xEF), LIME).save(BRAND / "exanote-lockup-dark.png")  # for dark backgrounds
    if "--preview" in sys.argv:
        light, dark = Image.open(BRAND / "exanote-lockup-light.png"), Image.open(BRAND / "exanote-lockup-dark.png")
        preview = Image.new("RGBA", (max(light.width, dark.width) + 120, light.height * 2 + 180), (*PAPER, 255))
        preview.alpha_composite(light, (60, 60))
        ImageDraw.Draw(preview).rectangle([0, light.height + 120, preview.width, preview.height], fill=(0x14, 0x14, 0x14, 255))
        preview.alpha_composite(dark, (60, light.height + 120 + 30))
        preview.save("/tmp/exanote-brand-preview.png")


if __name__ == "__main__":
    main()
