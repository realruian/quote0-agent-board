#!/usr/bin/env python3
"""Render the three example frames used in the README into docs/images/.

    python3 scripts/render_samples.py

The frames come from the app's own renderer (app/Sources/RenderSamples), so they
match the screen dot for dot; this script only enlarges them and puts them in a
bezel. Everything shown is made up (see sampleBoard in app/Sources/BoardCore/View.swift),
so the pictures never contain anything from the machine they were rendered on.
Needs the Swift toolchain and Pillow.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SCALE = 3  # whole multiples only: the frame is 1-bit and must stay sharp
BEZEL = 18
BEZEL_COLOUR = (28, 28, 30)
NOW = time.mktime((2026, 10, 8, 10, 12, 0, 0, 0, -1))  # a Thursday morning


def framed(frame: Image.Image) -> Image.Image:
    big = frame.convert("RGB").resize((frame.width * SCALE, frame.height * SCALE), Image.NEAREST)
    canvas = Image.new("RGBA", (big.width + 2 * BEZEL, big.height + 2 * BEZEL), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).rounded_rectangle((0, 0, canvas.width - 1, canvas.height - 1), radius=BEZEL, fill=BEZEL_COLOUR)
    canvas.paste(big, (BEZEL, BEZEL))
    return canvas


def main() -> None:
    out = ROOT / "docs" / "images"
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        # the fonts the app ships, from the repository
        environment = {**os.environ, "AGENT_BOARD_RESOURCES": str(ROOT / "agent_board")}
        result = subprocess.run(["swift", "run", "--package-path", str(ROOT / "app"), "RenderSamples", tmp, str(NOW)],
                                env=environment, capture_output=True, text=True)
        if result.returncode:
            sys.exit(result.stdout + result.stderr)
        for kind in ("list", "wait", "idle"):
            path = out / f"{kind}.png"
            framed(Image.open(Path(tmp) / f"{kind}.png")).save(path, optimize=True)
            print(path.relative_to(ROOT))


if __name__ == "__main__":
    main()
