#!/usr/bin/env python3
"""Render the three example frames used in the README into docs/images/.

    python3 scripts/render_samples.py

Everything shown is made up (see sample_board in agent_board/render.py), so the
pictures never contain anything from the machine they were rendered on.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agent_board.render import build_view, render, sample_board  # noqa: E402
from agent_board.usage import FIVE_HOUR, SEVEN_DAY  # noqa: E402

SCALE = 3  # whole multiples only: the frame is 1-bit and must stay sharp
BEZEL = 18
BEZEL_COLOUR = (28, 28, 30)
NOW = time.mktime((2026, 10, 8, 10, 12, 0, 0, 0, -1))  # a Thursday morning


def usage() -> dict:
    hour, day = 3600, 86400
    return {
        "claude": {"windows": {FIVE_HOUR: {"left": 36, "resets_at": NOW + 4.3 * hour},
                               SEVEN_DAY: {"left": 73, "resets_at": NOW + 2 * day}}},
        "codex": {"windows": {SEVEN_DAY: {"left": 95, "resets_at": NOW + 5 * day}}},
    }


def framed(frame: Image.Image) -> Image.Image:
    big = frame.convert("RGB").resize((frame.width * SCALE, frame.height * SCALE), Image.NEAREST)
    canvas = Image.new("RGBA", (big.width + 2 * BEZEL, big.height + 2 * BEZEL), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).rounded_rectangle((0, 0, canvas.width - 1, canvas.height - 1), radius=BEZEL, fill=BEZEL_COLOUR)
    canvas.paste(big, (BEZEL, BEZEL))
    return canvas


def main() -> None:
    out = ROOT / "docs" / "images"
    out.mkdir(parents=True, exist_ok=True)
    for kind in ("list", "wait", "idle"):
        view = build_view(sample_board(kind, NOW), NOW, None, usage())
        path = out / f"{kind}.png"
        framed(render(view)).save(path, optimize=True)
        print(path.relative_to(ROOT))


if __name__ == "__main__":
    main()
