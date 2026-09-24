#!/usr/bin/env python3
"""Draws the image GitHub shows when the repository is shared (Settings → General → Social preview):
the app icon, the name, one line on what it does, on the same soft wash as the disk image.
Writes Resources/social-preview.png (1280x640, GitHub's recommended size).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
WIDTH, HEIGHT = 1280, 640
HEIGHTS = [0.19, 0.24, 0.80, 1.00, 0.80, 0.69, 0.56, 0.19, 0.16, 0.69, 0.67, 0.58, 0.42]
VIOLET = (108, 92, 231)
FONTS = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]


def font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    for path in FONTS if bold else [f for f in FONTS if "Bold" not in f]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def main() -> None:
    image = Image.new("RGB", (WIDTH, HEIGHT))
    top, bottom = (252, 251, 255), (232, 228, 252)
    draw = ImageDraw.Draw(image)
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        draw.line([(0, y), (WIDTH, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    icon = Image.open(ROOT / "Resources" / "AppIcon.png").convert("RGBA").resize((300, 300), Image.LANCZOS)
    image.paste(icon, (110, (HEIGHT - 300) // 2), icon)

    x = 470
    draw.text((x, 170), "Murmur", font=font(112, bold=True), fill=(40, 36, 60))
    draw.text((x, 310), "Hold a key, talk, let go.", font=font(46), fill=(60, 56, 80))
    draw.text((x, 370), "Private dictation for the Mac, on your Mac.", font=font(34), fill=(95, 90, 120))

    # The wave, small, under the words.
    bar, gap = 12, 9
    for i, v in enumerate(HEIGHTS):
        h = max(bar, v * 70)
        x0 = x + i * (bar + gap)
        draw.rounded_rectangle([x0, 480 - h / 2, x0 + bar, 480 + h / 2], radius=bar / 2, fill=VIOLET)

    out = ROOT / "Resources" / "social-preview.png"
    image.save(out, optimize=True)
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
