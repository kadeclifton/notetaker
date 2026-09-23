#!/usr/bin/env python3
"""Draws Murmur's app icon and writes Resources/AppIcon.icns (plus a PNG preview).

White waveform bars (the menu bar symbol) on a violet-to-blue gradient, in the macOS app-icon
shape: a 824 pt rounded square ("squircle") centered on a 1024 pt canvas with a soft shadow.

    pip install pillow numpy
    python3 scripts/make-icon.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SS = 4                      # supersampling for smooth edges
SIZE = 1024 * SS
BODY = 824 * SS
INSET = (SIZE - BODY) // 2

TOP_LEFT = np.array([124, 92, 255], dtype=float)      # violet
BOTTOM_RIGHT = np.array([45, 170, 255], dtype=float)  # sky blue


def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """Superellipse |x|^n + |y|^n <= 1, the shape of macOS app icons."""
    coords = np.linspace(-1, 1, size)
    x, y = np.meshgrid(coords, coords)
    inside = (np.abs(x) ** n + np.abs(y) ** n) <= 1
    return Image.fromarray((inside * 255).astype(np.uint8), "L")


def gradient(size: int) -> Image.Image:
    t = np.linspace(0, 1, size)
    x, y = np.meshgrid(t, t)
    mix = ((x + y) / 2)[..., None]
    rgb = TOP_LEFT * (1 - mix) + BOTTOM_RIGHT * mix
    # A soft light from the top so it doesn't look flat.
    rgb += (np.clip(0.5 - y, 0, 0.5) * 50)[..., None]
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")


def waveform(draw: ImageDraw.ImageDraw, center: int) -> None:
    heights = [0.26, 0.50, 0.80, 0.58, 1.00, 0.62, 0.34]
    bar = 60 * SS
    gap = 40 * SS
    tallest = 470 * SS
    total = len(heights) * bar + (len(heights) - 1) * gap
    left = center - total // 2
    for i, h in enumerate(heights):
        height = int(tallest * h)
        x0 = left + i * (bar + gap)
        y0 = center - height // 2
        draw.rounded_rectangle([x0, y0, x0 + bar, y0 + height], radius=bar // 2, fill=(255, 255, 255, 255))


def icon() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = squircle_mask(BODY)

    # Shadow: the body's shape, darkened, blurred and nudged down.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (INSET, INSET + 14 * SS), mask)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(18 * SS)))

    body = gradient(BODY).convert("RGBA")
    body.putalpha(mask)
    canvas.alpha_composite(body, (INSET, INSET))

    marks = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    waveform(ImageDraw.Draw(marks), SIZE // 2)
    # A faint shadow under the bars for depth.
    bars_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bars_shadow.paste((20, 20, 80, 70), (0, 6 * SS), marks.split()[3])
    canvas = Image.alpha_composite(canvas, bars_shadow.filter(ImageFilter.GaussianBlur(10 * SS)))
    canvas = Image.alpha_composite(canvas, marks)

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main() -> None:
    image = icon()
    resources = ROOT / "Resources"
    image.save(resources / "AppIcon.png")
    image.save(resources / "AppIcon.icns", format="ICNS",
               sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("Wrote", resources / "AppIcon.icns")


if __name__ == "__main__":
    main()
