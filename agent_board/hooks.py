"""Add and remove this project's hook entries in the agents' own config files.

Entries are always appended after whatever is already there and are recognised
again by a marker, so other tools' hooks keep their content and position.
"""

from __future__ import annotations

import json
import os
import shutil
import time
from pathlib import Path

from . import config

MARKER = ".quote0-agent-board/bin/agent-board-hook"

# event -> matcher (None = no matcher). Only events both agents already use here.
CLAUDE_EVENTS = {
    "SessionStart": None, "UserPromptSubmit": None, "PreToolUse": "*", "PostToolUse": "*",
    "PermissionRequest": "*", "Notification": "*", "Stop": None, "StopFailure": None, "SessionEnd": None,
}
CODEX_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop",
                "SessionEnd"]

FILES = {
    "claude": Path.home() / ".claude" / "settings.json",
    "codex": Path.home() / ".codex" / "hooks.json",
}


def hook_path() -> Path:
    return config.home() / "bin" / "agent-board-hook"


def _backup(path: Path) -> None:
    dest = config.home() / "backups"
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest / f"{path.parent.name.lstrip('.')}-{path.name}.{time.strftime('%Y%m%d-%H%M%S')}")


def _write_json(path: Path, data: dict) -> None:
    """Rewrite a JSON file in the style it already uses, to keep the change small."""
    old = path.read_text()
    spaced_colons = '" : ' in old  # the style Swift tools write
    text = json.dumps(data, indent=2, ensure_ascii=False, separators=(",", " : " if spaced_colons else ": "))
    if spaced_colons:
        text = text.replace("/", "\\/")
    tmp = path.with_name(path.name + ".agent-board.tmp")
    tmp.write_text(text + ("\n" if old.endswith("\n") else ""))
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def is_ours(group: dict) -> bool:
    return bool(group.get("_agent_board")) or any(MARKER in (h.get("command") or "") for h in group.get("hooks", []))


def groups_for(agent: str) -> dict[str, dict]:
    if agent == "claude":
        groups = {}
        for event, matcher in CLAUDE_EVENTS.items():
            command = (f"/bin/sh -c '[ -x \"$HOME/{MARKER}\" ] && "
                       f"\"$HOME/{MARKER}\" claude {event}; exit 0'")
            group: dict = {"hooks": [{"type": "command", "command": command, "timeout": 5}]}
            groups[event] = {"matcher": matcher, **group} if matcher else group
        return groups
    return {
        event: {"_agent_board": True,
                "hooks": [{"type": "command", "command": f"'{hook_path()}' codex {event}", "timeout": 5}]}
        for event in CODEX_EVENTS
    }


def edit(path: Path, add: dict[str, dict] | None) -> str:
    """Drop our hook groups from `path`, then append `add` (event -> group) if given."""
    if not path.exists():
        return "not found, skipped"
    data = json.loads(path.read_text())
    hooks = data.setdefault("hooks", {})
    before = json.dumps(hooks, sort_keys=True)
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if not is_ours(g)]
        if not hooks[event]:
            del hooks[event]
    for event, group in (add or {}).items():
        hooks.setdefault(event, []).append(group)  # appended last: existing positions stay put
    if json.dumps(hooks, sort_keys=True) == before:
        return "already up to date"
    _backup(path)
    _write_json(path, data)
    return "updated"


def set_enabled(agent: str, enabled: bool) -> str:
    return edit(FILES[agent], groups_for(agent) if enabled else None)


def status(agent: str) -> dict:
    path = FILES[agent]
    info = {"path": str(path).replace(str(Path.home()), "~"), "exists": path.exists(),
            "installed": 0, "expected": len(groups_for(agent)), "vibe_island": 0}
    if not info["exists"]:
        return info
    try:
        hooks = json.loads(path.read_text()).get("hooks", {})
    except ValueError:
        info["error"] = "配置文件不是合法的 JSON"
        return info
    for groups in hooks.values():
        for group in groups:
            if is_ours(group):
                info["installed"] += 1
            elif any("vibe-island" in (h.get("command") or "") for h in group.get("hooks", [])):
                info["vibe_island"] += 1
    return info
