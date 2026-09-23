#!/usr/bin/env python3
"""Draws the background of the Murmur disk image window: a soft wash, the "murmur" wave faintly in
the middle, an arrow from where Finder shows the app to where it shows Applications, and a line of
instructions. Writes Resources/dmg-background.png (660x400) and @2x (1320x800).

The icon positions must match scripts/make-dmg.sh (app at x=170, Applications at x=490, y=190).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
WIDTH, HEIGHT = 660, 400
APP_X, DROP_X, ICON_Y = 170, 490, 190
# Same bars as the app icon: the envelope of the spoken word "murmur".
HEIGHTS = [0.19, 0.24, 0.80, 1.00, 0.80, 0.69, 0.56, 0.19, 0.16, 0.69, 0.67, 0.58, 0.42]
VIOLET = (108, 92, 231)

FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def font(size: int) -> ImageFont.ImageFont:
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw(scale: int) -> Image.Image:
    w, h = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (w, h))
    pixels = image.load()
    # A vertical wash from near-white to a pale lavender.
    top, bottom = (252, 251, 255), (238, 235, 252)
    for y in range(h):
        t = y / (h - 1)
        row = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(w):
            pixels[x, y] = row

    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)

    # The wave, faint, between the two icons, doubling as the arrow's shaft.
    bar_w, gap = 7 * scale, 5 * scale
    total = len(HEIGHTS) * bar_w + (len(HEIGHTS) - 1) * gap
    left = (APP_X + DROP_X) * scale / 2 - total / 2 - 14 * scale
    for i, v in enumerate(HEIGHTS):
        bh = max(bar_w, v * 64 * scale)
        x0 = left + i * (bar_w + gap)
        y0 = ICON_Y * scale - bh / 2
        d.rounded_rectangle([x0, y0, x0 + bar_w, y0 + bh], radius=bar_w / 2, fill=VIOLET + (70,))

    # Arrow head just past the wave, pointing at Applications.
    tip_x = left + total + 30 * scale
    cy = ICON_Y * scale
    size = 13 * scale
    d.polygon([(tip_x, cy), (tip_x - size, cy - size), (tip_x - size, cy + size)], fill=VIOLET + (150,))

    # Instructions under the icons (Finder draws the icon names at about y=260).
    title = "Drag Murmur into Applications"
    f = font(17 * scale)
    tw = d.textlength(title, font=f)
    d.text(((w - tw) / 2, 312 * scale), title, font=f, fill=(60, 56, 80, 255))
    note = "Then open it from Applications. It lives in the menu bar."
    f2 = font(12 * scale)
    nw = d.textlength(note, font=f2)
    d.text(((w - nw) / 2, 342 * scale), note, font=f2, fill=(110, 106, 130, 255))

    image = Image.alpha_composite(image.convert("RGBA"), overlay.filter(ImageFilter.GaussianBlur(0.3 * scale)))
    return image.convert("RGB")


def main() -> None:
    for scale, name in [(1, "dmg-background.png"), (2, "dmg-background@2x.png")]:
        out = ROOT / "Resources" / name
        draw(scale).save(out, dpi=(72 * scale, 72 * scale))
        print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
