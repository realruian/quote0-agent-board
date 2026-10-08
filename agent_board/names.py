"""The name a conversation carries in its own app (the one shown in the sidebar).

Both agents keep it in plain local files:
- Claude Code appends `custom-title` (or `ai-title`) records to the session transcript.
- Codex lists `thread_name` per session in ~/.codex/session_index.jsonl.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

CODEX_INDEX = Path.home() / ".codex" / "session_index.jsonl"
TAIL_BYTES = 262_144
MAX_CHARS = 60


def _tail_lines(path: str | Path) -> list[str]:
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - TAIL_BYTES))
        return f.read().decode("utf-8", "replace").splitlines()


def _clean(name) -> str:
    return " ".join(name.split())[:MAX_CHARS] if isinstance(name, str) else ""


def claude_name(transcript: str) -> str:
    """Latest title record near the end of a Claude Code transcript, or ""."""
    if not transcript or not transcript.endswith(".jsonl"):
        return ""
    try:
        lines = _tail_lines(transcript)
    except OSError:
        return ""
    for line in reversed(lines):
        if '"custom-title"' not in line and '"ai-title"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("type") in ("custom-title", "ai-title"):
            name = _clean(record.get("customTitle") or record.get("aiTitle"))
            if name:
                return name
    return ""


def codex_name(session_id: str, index: Path = CODEX_INDEX) -> str:
    """Latest thread name Codex recorded for this session, or ""."""
    if not session_id:
        return ""
    try:
        lines = _tail_lines(index)
    except OSError:
        return ""
    for line in reversed(lines):
        if session_id not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("id") == session_id:
            return _clean(record.get("thread_name"))
    return ""


def lookup(source: str, session_id: str, transcript: str) -> str:
    return codex_name(session_id) if source == "codex" else claude_name(transcript)
