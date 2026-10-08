"""Small helpers for looking at the board from a terminal.

    python3 -m agent_board.cli status          what the board currently holds
    python3 -m agent_board.cli preview OUT.png render the current frame to a file
    python3 -m agent_board.cli open            open the settings page in the browser
"""

from __future__ import annotations

import json
import socket
import sys
import time

from . import config
from .render import build_view, render, to_png
from .state import Board


def _state() -> dict:
    try:
        return json.loads((config.home() / "state.json").read_text())
    except (FileNotFoundError, ValueError):
        return {}


def _board() -> Board:
    cfg = config.load()
    board = Board(done_ttl=cfg["done_ttl_minutes"] * 60, stale_running=cfg["stale_running_minutes"] * 60)
    board.load_dict(_state().get("board", {}))
    return board


def _daemon_alive() -> bool:
    with socket.socket(socket.AF_UNIX) as s:
        try:
            s.connect(str(config.socket_path()))
            return True
        except OSError:
            return False


def main(argv: list[str]) -> int:
    command = argv[0] if argv else "status"
    board = _board()
    if command == "status":
        print("daemon:", "running" if _daemon_alive() else "not running")
        if _state().get("last_push", {}).get("delivered") is False:
            print("device: asleep or offline, the screen is not showing the latest frame")
        shown = board.visible()
        if not shown:
            print("no active sessions")
        for s in shown:
            since = time.strftime("%H:%M", time.localtime(s.updated_at))
            print(f"  {s.state:8} {s.source:7} {s.project}  (last event {since})")
        return 0
    if command == "preview" and len(argv) == 2:
        with open(argv[1], "wb") as f:
            f.write(to_png(render(build_view(board, None, config.load()))))
        return 0
    if command == "open":
        import subprocess
        return subprocess.call(["open", f"http://127.0.0.1:{config.load()['web_port']}"])
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
