"""Subscription quota readings, taken from files that already exist on this machine.

Nothing here logs in anywhere or touches credentials:
- Codex writes its rate limits into its own session records after every reply.
- Claude Code reports its limits only to a terminal status line. Vibe Island
  keeps what it last saw from that, and from its own checks, in two local files.

A Claude reading goes stale quickly, because sessions in the desktop app spend
quota without updating either file, so it is only trusted while it is recent.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from datetime import datetime
from pathlib import Path

FIVE_HOUR, SEVEN_DAY = "five_hour", "seven_day"
WINDOWS = (FIVE_HOUR, SEVEN_DAY)

CODEX_SESSIONS = Path.home() / ".codex" / "sessions"
VIBE_STATUSLINE_CACHE = Path.home() / ".vibe-island" / "cache" / "rl.json"
VIBE_USAGE_DB = Path.home() / ".vibe-island" / "data" / "usage" / "usage.sqlite"

CLAUDE_MAX_AGE = 20 * 60
TAIL_BYTES = 256_000


def _find(obj, key: str):
    """First value stored under `key` anywhere inside nested dicts."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for value in obj.values():
            found = _find(value, key)
            if found is not None:
                return found
    return None


def _kind(window_minutes) -> str | None:
    if not isinstance(window_minutes, (int, float)):
        return None
    if window_minutes <= 360:
        return FIVE_HOUR
    return SEVEN_DAY if window_minutes >= 10000 else None


def _iso(stamp) -> float:
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _codex_from_file(path: Path) -> dict | None:
    """The last rate-limit record in one Codex session file."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - TAIL_BYTES))
        lines = f.read().decode("utf-8", "replace").splitlines()
    for line in reversed(lines):
        if '"rate_limits"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        limits = _find(record, "rate_limits")
        if not isinstance(limits, dict):
            continue
        windows = {}
        for slot in ("primary", "secondary"):
            window = limits.get(slot)
            kind = _kind(window.get("window_minutes")) if isinstance(window, dict) else None
            if kind and isinstance(window.get("used_percent"), (int, float)):
                windows[kind] = {"used": float(window["used_percent"]), "resets_at": float(window.get("resets_at") or 0)}
        if windows:
            return {"observed_at": _iso(record.get("timestamp")) or path.stat().st_mtime, "windows": windows}
    return None


def read_codex(root: Path = CODEX_SESSIONS) -> dict | None:
    try:
        files = sorted(root.glob("*/*/*/rollout-*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return None
    for path in files[:5]:
        try:
            reading = _codex_from_file(path)
        except OSError:
            continue
        if reading:
            return reading
    return None


def _claude_windows(data: dict) -> dict:
    windows = {}
    for kind in WINDOWS:
        window = data.get(kind)
        if isinstance(window, dict) and isinstance(window.get("used_percentage"), (int, float)):
            windows[kind] = {"used": float(window["used_percentage"]), "resets_at": float(window.get("resets_at") or 0)}
    return windows


def read_claude(cache: Path = VIBE_STATUSLINE_CACHE, db: Path = VIBE_USAGE_DB) -> dict | None:
    """The more recent of the two local records of Claude's limits, if any."""
    readings = []
    try:
        windows = _claude_windows(json.loads(cache.read_text()))
        if windows:
            readings.append({"observed_at": cache.stat().st_mtime, "windows": windows})
    except (OSError, ValueError):
        pass
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1) as conn:
            row = conn.execute(
                "select snapshot from usage_limit_records where provider = 'anthropic' and snapshot is not null "
                "order by json_extract(snapshot, '$.fetched_at') desc limit 1").fetchone()
        if row:
            snapshot = json.loads(row[0])
            windows = _claude_windows(snapshot)
            if windows:
                readings.append({"observed_at": float(snapshot.get("fetched_at") or 0), "windows": windows})
    except (sqlite3.Error, ValueError, TypeError):
        pass
    return max(readings, key=lambda r: r["observed_at"], default=None)


def _left(agent: str, reading: dict | None, now: float) -> dict:
    """Remaining percent per window, keeping only what can still be trusted."""
    if not reading:
        return {}
    age = now - reading["observed_at"]
    out = {}
    for kind, window in reading["windows"].items():
        reset = window["resets_at"]
        rolled_over = bool(reset) and now >= reset
        if agent == "claude":
            if age > CLAUDE_MAX_AGE or rolled_over:
                continue
            left = 100 - window["used"]
        else:
            # Codex's own record: nothing was spent from this machine after it,
            # so it holds until the window resets, and is full again after.
            left = 100.0 if rolled_over else 100 - window["used"]
            reset = 0 if rolled_over else reset
        out[kind] = {"left": max(0, min(100, round(left))), "resets_at": reset}
    return out


def snapshot(now: float | None = None) -> dict:
    """{"claude": {...}, "codex": {...}}: per window, percent left and reset time.
    An agent maps to {} when there is no reading worth showing."""
    now = time.time() if now is None else now
    claude, codex = read_claude(), read_codex()
    return {
        "claude": {"windows": _left("claude", claude, now), "observed_at": claude["observed_at"] if claude else 0},
        "codex": {"windows": _left("codex", codex, now), "observed_at": codex["observed_at"] if codex else 0},
    }
