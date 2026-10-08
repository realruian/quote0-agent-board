#!/usr/bin/env python3
"""Draw the app's icon into menubar/AppIcon.icns.

    python3 scripts/make_app_icon.py

The icon is the device's screen as one solid black shape on a light plate, with
the saw-edged disc of the Dot. app cut out of its middle: the board is something
that runs on a Dot. device. It is drawn large and scaled down, then packed with
iconutil, which ships with macOS.
"""

from __future__ import annotations

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
K = 4  # drawn at four times the size, so the scaled-down edges come out smooth
N = SIZE * K


def gradient(top: tuple, bottom: tuple) -> Image.Image:
    column = Image.new("RGB", (1, N))
    for y in range(N):
        t = y / (N - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((N, N))


def rounded(mask: Image.Image, box: tuple, radius: int, fill: int = 255) -> None:
    """A rounded box on a mask, in units of Apple's 1024-point icon grid."""
    ImageDraw.Draw(mask).rounded_rectangle([v * K for v in box], radius=radius * K, fill=fill)


def disc(mask: Image.Image, cx: int, cy: int, radius: int, fill: int, points: int = 12, depth: float = 0.9, turn: float = 7) -> None:
    corners = []
    for i in range(points * 2):
        r = radius if i % 2 == 0 else radius * depth
        angle = math.radians(turn + i * 180 / points)
        corners.append(((cx + r * math.cos(angle)) * K, (cy + r * math.sin(angle)) * K))
    ImageDraw.Draw(mask).polygon(corners, fill=fill)


def draw() -> Image.Image:
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # The light plate every macOS icon sits on, with a soft shadow under it.
    shadow = Image.new("L", (N, N), 0)
    rounded(shadow, (100, 112, 924, 936), 185, 70)
    img.paste((0, 0, 0, 255), (0, 0), shadow.filter(ImageFilter.GaussianBlur(14 * K)))
    plate = Image.new("L", (N, N), 0)
    rounded(plate, (100, 100, 924, 924), 185)
    img.paste(gradient((255, 255, 255), (238, 238, 240)), (0, 0), plate)

    # The screen, with the disc cut out. Black with a little depth: lighter at the top.
    shape = Image.new("L", (N, N), 0)
    rounded(shape, (232, 322, 792, 702), 84)
    disc(shape, 512, 512, 122, 0)
    img.paste(gradient((72, 72, 76), (8, 8, 10)), (0, 0), shape)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    icon = draw()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            icon.resize((points, points), Image.LANCZOS).save(iconset / f"icon_{points}x{points}.png")
            icon.resize((points * 2, points * 2), Image.LANCZOS).save(iconset / f"icon_{points}x{points}@2x.png")
        out = ROOT / "menubar" / "AppIcon.icns"
        subprocess.run(["iconutil", "--convert", "icns", "--output", str(out), str(iconset)], check=True)
    print(out)


if __name__ == "__main__":
    main()
