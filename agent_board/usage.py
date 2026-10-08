"""Subscription quota readings.

Nothing here logs in anywhere or reads a credential:
- Codex writes its rate limits into its own session records after every reply.
- Claude Code answers a usage request on its command line's control channel,
  with the sign-in the command line already has.

A Claude reading goes stale quickly, because every Claude app on the account
spends the same quota, so it is asked for again every few minutes and only
trusted while it is recent.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import time
import urllib.request
from datetime import datetime
from pathlib import Path

FIVE_HOUR, SEVEN_DAY = "five_hour", "seven_day"
WINDOWS = (FIVE_HOUR, SEVEN_DAY)

CODEX_SESSIONS = Path.home() / ".codex" / "sessions"
TAIL_BYTES = 256_000

CLAUDE_BINARIES = (Path.home() / ".local" / "bin" / "claude", Path.home() / ".claude" / "local" / "claude")
# Nothing of the user's is loaded (so our own hooks do not fire), no tools, nothing saved.
CLAUDE_ARGS = ("--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
               "--tools", "", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose")
# Set inside a Claude Code session; with them the command line acts as part of that session.
CLAUDE_SESSION_ENV = ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
                      "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID")
CLAUDE_EVERY = 5 * 60
CLAUDE_TIMEOUT = 15
CLAUDE_MAX_AGE = 20 * 60


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


def claude_bin() -> str | None:
    for path in CLAUDE_BINARIES:
        if os.access(path, os.X_OK):
            return str(path)
    return shutil.which("claude")


def _claude_env() -> dict:
    """The environment to ask in: outside any Claude Code session this process was
    started from, and through the system proxy, which a launchd job is not told about."""
    env = {k: v for k, v in os.environ.items() if k not in CLAUDE_SESSION_ENV}
    for scheme, url in urllib.request.getproxies().items():
        if scheme in ("http", "https"):
            env.setdefault(f"{scheme.upper()}_PROXY", url)
    return env


def _ask_claude(binary: str, timeout: float = CLAUDE_TIMEOUT) -> dict | None:
    """The command line's answer to a usage request, or None when it gives none in time."""
    deadline, pending = time.monotonic() + timeout, b""
    with subprocess.Popen([binary, *CLAUDE_ARGS], cwd=Path.home(), env=_claude_env(), stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as child:

        def send(request_id: str, subtype: str) -> None:
            request = {"type": "control_request", "request_id": request_id, "request": {"subtype": subtype}}
            child.stdin.write(json.dumps(request).encode() + b"\n")
            child.stdin.flush()

        try:
            send("init", "initialize")
            while True:
                ready, _, _ = select.select([child.stdout], [], [], max(0, deadline - time.monotonic()))
                chunk = os.read(child.stdout.fileno(), 65536) if ready else b""
                if not chunk:  # out of time, or the command line went away
                    return None
                *lines, pending = (pending + chunk).split(b"\n")
                for line in lines:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    reply = message.get("response") if isinstance(message, dict) else None
                    if message.get("type") != "control_response" or not isinstance(reply, dict):
                        continue
                    if reply.get("subtype") != "success":
                        return None
                    if reply.get("request_id") == "init":
                        send("usage", "get_usage")
                    elif reply.get("request_id") == "usage":
                        return reply.get("response")
        finally:
            child.kill()


def _claude_windows(limits) -> dict:
    windows = {}
    for kind in WINDOWS:
        window = limits.get(kind) if isinstance(limits, dict) else None
        if isinstance(window, dict) and isinstance(window.get("utilization"), (int, float)):
            # the reported reset time wobbles by a fraction of a second from one ask to the next
            windows[kind] = {"used": float(window["utilization"]), "resets_at": round(_iso(window.get("resets_at")) / 60) * 60.0}
    return windows


_claude = {"asked_at": 0.0, "reading": None}


def read_claude(now: float | None = None, ask=_ask_claude) -> dict | None:
    """Claude's limits as the command line last reported them. Asking starts a
    process and reaches Anthropic, so it is done every few minutes and the answer
    kept; an ask that fails leaves the earlier reading to age out."""
    now = time.time() if now is None else now
    if now - _claude["asked_at"] >= CLAUDE_EVERY:
        _claude["asked_at"] = now
        binary = claude_bin()
        try:
            answer = ask(binary) if binary else None
        except OSError:
            answer = None
        windows = _claude_windows(answer.get("rate_limits")) if isinstance(answer, dict) else {}
        if windows:
            _claude["reading"] = {"observed_at": now, "windows": windows}
    return _claude["reading"]


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
    claude, codex = read_claude(now), read_codex()
    return {
        "claude": {"windows": _left("claude", claude, now), "observed_at": claude["observed_at"] if claude else 0},
        "codex": {"windows": _left("codex", codex, now), "observed_at": codex["observed_at"] if codex else 0},
    }
