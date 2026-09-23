#!/usr/bin/env python3
"""Draws Murmur's app icon: Resources/AppIcon.icon for macOS 26 (light, dark, clear and tinted,
compiled by Xcode's actool in build-app.sh) and Resources/AppIcon.icns for older macOS and for
builds without Xcode 26 (plus a PNG preview).

The bars are the loudness of the word "murmur" spoken aloud, measured in 13 slices: a big swell
for the stressed MUR, a dip where the second "m" hums, then a smaller mur that trails off. White
bars on a violet-to-blue gradient, in the macOS app-icon shape: an 824 pt rounded square
("squircle") centered on a 1024 pt canvas with a soft shadow.

The menu bar icon draws the same heights (Sources/Murmur/MenuBarIcon.swift); keep them in sync.

    pip install pillow numpy
    python3 scripts/make-icon.py                    # the built-in "murmur" shape
    python3 scripts/make-icon.py --from murmur.wav  # measure a recording instead (16-bit PCM WAV)

To record one on a Mac:  say -o murmur.wav --data-format=LEI16@22050 "murmur"
"""
import argparse
import wave
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


# "murmur" as spoken by espeak-ng (en-us, 120 wpm), measured by word_heights() below.
HEIGHTS = [0.19, 0.24, 0.80, 1.00, 0.80, 0.69, 0.56, 0.19, 0.16, 0.69, 0.67, 0.58, 0.42]


def word_heights(path: str, bars: int = 13, gamma: float = 0.75, floor: float = 0.16) -> list:
    """Loudness of a spoken word in `bars` equal slices, scaled to floor...1."""
    with wave.open(path) as w:
        rate = w.getframerate()
        samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float) / 32768
        if w.getnchannels() > 1:
            samples = samples.reshape(-1, w.getnchannels()).mean(axis=1)
    window = int(rate * 0.01)
    rms = np.sqrt(np.convolve(samples ** 2, np.ones(window) / window, mode="same"))
    voiced = np.where(rms > rms.max() * 0.04)[0]          # trim the silence around the word
    rms = rms[voiced[0]:voiced[-1]]
    level = np.array([part.mean() for part in np.array_split(rms, bars)])
    level = (level / level.max()) ** gamma                  # a little compression, like hearing
    level = floor + (1 - floor) * (level - level.min()) / (level.max() - level.min())
    return [round(float(v), 2) for v in level]


def waveform(draw: ImageDraw.ImageDraw, center: int, heights: list) -> None:
    bar = 34 * SS
    gap = 16 * SS
    tallest = 500 * SS
    total = len(heights) * bar + (len(heights) - 1) * gap
    left = center - total // 2
    for i, h in enumerate(heights):
        height = int(tallest * h)
        x0 = left + i * (bar + gap)
        y0 = center - height // 2
        draw.rounded_rectangle([x0, y0, x0 + bar, y0 + height], radius=bar // 2, fill=(255, 255, 255, 255))


def icon(heights: list) -> Image.Image:
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
    waveform(ImageDraw.Draw(marks), SIZE // 2, heights)
    # A faint shadow under the bars for depth.
    bars_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bars_shadow.paste((20, 20, 80, 70), (0, 6 * SS), marks.split()[3])
    canvas = Image.alpha_composite(canvas, bars_shadow.filter(ImageFilter.GaussianBlur(10 * SS)))
    canvas = Image.alpha_composite(canvas, marks)

    return canvas.resize((1024, 1024), Image.LANCZOS)


# Icon Composer (macOS 26+): the system draws the tile, its light/dark gradient, glass, and the
# clear and tinted variants; we supply only the bars as a transparent layer and a seed color.
SEED = (86, 131, 255)   # between the gradient's violet and blue


def composer_icon(heights: list) -> None:
    folder = ROOT / "Resources" / "AppIcon.icon"
    (folder / "Assets").mkdir(parents=True, exist_ok=True)
    # Same proportions as the flat icon, on Icon Composer's full 1024 canvas (the flat icon's tile
    # is 824 wide; the system adds the margins itself).
    scale = 1024 / 824
    bar, gap, tallest = 34 * scale, 16 * scale, 500 * scale
    total = len(heights) * bar + (len(heights) - 1) * gap
    left = 512 - total / 2
    rects = []
    for i, h in enumerate(heights):
        height = tallest * h
        rects.append(f'  <rect x="{left + i * (bar + gap):.2f}" y="{512 - height / 2:.2f}" width="{bar:.2f}" '
                     f'height="{height:.2f}" rx="{bar / 2:.2f}" fill="#FFFFFF"/>')
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
           + "\n".join(rects) + "\n</svg>\n")
    (folder / "Assets" / "wave.svg").write_text(svg)
    r, g, b = (c / 255 for c in SEED)
    (folder / "icon.json").write_text(f"""{{
  "fill" : {{
    "automatic-gradient" : "extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"
  }},
  "groups" : [
    {{
      "layers" : [
        {{
          "image-name" : "wave.svg",
          "name" : "wave"
        }}
      ],
      "shadow" : {{
        "kind" : "neutral",
        "opacity" : 0.5
      }},
      "translucency" : {{
        "enabled" : true,
        "value" : 0.4
      }}
    }}
  ],
  "supported-platforms" : {{
    "squares" : "shared"
  }}
}}
""")
    print("Wrote", folder)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--from", dest="source", help="WAV recording of the word to measure")
    args = parser.parse_args()
    heights = HEIGHTS
    if args.source:
        heights = word_heights(args.source)
        print("Heights (copy into HEIGHTS here and in Sources/Murmur/MenuBarIcon.swift):", heights)
    image = icon(heights)
    resources = ROOT / "Resources"
    image.save(resources / "AppIcon.png")
    image.save(resources / "AppIcon.icns", format="ICNS",
               sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("Wrote", resources / "AppIcon.icns")
    composer_icon(heights)


if __name__ == "__main__":
    main()
