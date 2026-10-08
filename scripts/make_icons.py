#!/usr/bin/env python3
"""Write the window's icons into the Swift source.

    npm pack @hugeicons/core-free-icons && tar -xzf hugeicons-core-free-icons-*.tgz
    python3 scripts/make_icons.py package

The icons are Hugeicons' free set (stroke, rounded; MIT, see app/Hugeicons-LICENSE.md).
The package holds each one as a list of SVG elements in a JavaScript file; this reads
the ones named below as text and leaves `app/Sources/AgentBoard/UI/Icons.swift`. To use
another icon, add its name here, run this again, and it is there as a case of `Icon`.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "app" / "Sources" / "AgentBoard" / "UI" / "Icons.swift"
NAMES = [
    "DashboardSquare01", "ListView", "Refresh", "Notification01", "CommandLine", "TabletConnectedWifi", "Pulse01", "InformationCircle",
    "Alert02", "CheckmarkCircle02", "CancelCircle", "ArrowUpRight01", "Folder01", "Tick02",
]
ATTRIBUTES = {"strokeLinecap": "stroke-linecap", "strokeLinejoin": "stroke-linejoin", "strokeWidth": "stroke-width",
              "fillRule": "fill-rule", "clipRule": "clip-rule"}


def svg(package: Path, name: str) -> str:
    source = (package / "dist" / "esm" / f"{name}Icon.js").read_text()
    elements = []
    for tag, body in re.findall(r'\["(\w+)", \{(.*?)\}\]', source, re.S):
        pairs = [(key, value) for key, value in re.findall(r'(\w+): "([^"]*)"', body) if key != "key"]
        # Drawn in black and used as a template: the view that shows it gives it its colour.
        elements.append("<%s %s/>" % (tag, " ".join(f"{ATTRIBUTES.get(k, k)}='{v.replace('currentColor', 'black')}'" for k, v in pairs)))
    if not elements:
        sys.exit(f"no drawing found for {name}")
    return "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' width='24' height='24' fill='none'>" + "".join(elements) + "</svg>"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    package = Path(sys.argv[1])
    version = json.loads((package / "package.json").read_text())["version"]
    case = lambda name: name[0].lower() + name[1:]
    lines = [
        f"// The window's icons: Hugeicons' free set, stroke rounded (https://hugeicons.com, MIT, see app/Hugeicons-LICENSE.md).",
        f"// Written by scripts/make_icons.py from @hugeicons/core-free-icons {version}. Change the list there, not this file.",
        "",
        "import AppKit",
        "import SwiftUI",
        "",
        "enum Icon: String {",
        "    case " + ", ".join(case(name) for name in NAMES),
        "",
        "    /// The drawing, as SVG on a 24-point grid.",
        "    var svg: String {",
        "        switch self {",
    ]
    lines += [f'        case .{case(name)}: return "{svg(package, name)}"' for name in NAMES]
    lines += ["        }", "    }", "}", ""]
    OUT.write_text("\n".join(lines))
    print(OUT)


if __name__ == "__main__":
    main()
