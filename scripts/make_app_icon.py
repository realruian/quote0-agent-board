#!/usr/bin/env python3
"""Draw the menu bar app's icon into menubar/AppIcon.icns.

    python3 scripts/make_app_icon.py

The icon is the device itself: a dark bezel around a paper-white screen that
shows three conversations. It is drawn large and scaled down, then packed with
iconutil, which ships with macOS.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
DRAWN = 4 * SIZE  # drawn oversize, so the scaled-down edges come out smooth
PAPER = (244, 243, 238)
INK = (28, 28, 30)
BEZEL = (44, 44, 48)


def draw() -> Image.Image:
    u = DRAWN / 1024  # one unit of Apple's 1024-point icon grid
    img = Image.new("RGBA", (DRAWN, DRAWN), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def box(x0, y0, x1, y1, radius, fill):
        d.rounded_rectangle([x0 * u, y0 * u, x1 * u, y1 * u], radius=radius * u, fill=fill)

    box(100, 100, 924, 924, 185, (252, 252, 250))  # the tile every macOS icon sits on
    box(168, 300, 856, 724, 56, BEZEL)
    box(204, 336, 820, 688, 26, PAPER)
    for y, working, length in ((412, True, 300), (512, True, 380), (612, False, 240)):
        box(250, y - 30, 310, y + 30, 12, INK)  # the agent's tag: solid while working, outlined once finished
        if not working:
            box(260, y - 20, 300, y + 20, 5, PAPER)
        box(346, y - 14, 346 + length, y + 14, 14, INK)
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
