"""Paths and settings shared by the daemon, CLI, web console and installer."""

from __future__ import annotations

import copy
import json
import os
import re
from pathlib import Path

DEFAULTS = {
    "device_id": "",
    "api_key_file": "~/.dot_api_key",
    "api_base": "https://dot.mindreset.tech",
    "web_port": 8765,
    # Display. Frames travel through MindReset's servers. The task title (the
    # start of the user's prompt) is on by request; the tool name behind a
    # permission request stays off the screen unless asked for.
    "show_titles": True,
    "show_detail": False,
    "show_usage": True,  # quota left, in the top bar and on the idle screen
    # When the device shows other loop content (its loop moved on, or the list was
    # edited in the Dot app), put the board back.
    "keep_on_screen": True,
    "font": "pingfang",  # falls back to a system font when not installed
    "max_rows": 4,
    "idle_show_last": True,
    "aliases": {},
    "hidden_projects": [],
    "done_ttl_minutes": 30,
    # Alerts
    "takeover": {"permission": True, "question": True, "plan": True},
    "quiet_hours": {"enabled": False, "start": "23:00", "end": "07:00"},
    "min_push_interval_seconds": 10,
    "stale_running_minutes": 60,
}

# What the web console may change. The rest identifies the device and needs a restart.
FONT_CHOICES = ("pingfang", "misans", "hiragino", "arkpixel")

EDITABLE = ("font", "keep_on_screen", "show_titles", "show_detail", "show_usage", "max_rows", "idle_show_last", "aliases", "hidden_projects", "done_ttl_minutes",
            "takeover", "quiet_hours", "min_push_interval_seconds", "stale_running_minutes")

_HHMM = re.compile(r"([01]\d|2[0-3]):[0-5]\d")


def home() -> Path:
    return Path(os.environ.get("AGENT_BOARD_HOME") or Path.home() / ".quote0-agent-board")


def socket_path() -> Path:
    return home() / "run" / "board.sock"


def _stored() -> dict:
    try:
        return json.loads((home() / "config.json").read_text())
    except FileNotFoundError:
        return {}


def load() -> dict:
    cfg = copy.deepcopy(DEFAULTS)
    for key, value in _stored().items():
        if isinstance(cfg.get(key), dict) and isinstance(value, dict) and key in ("takeover", "quiet_hours"):
            cfg[key].update(value)
        else:
            cfg[key] = value
    return cfg


def save(patch: dict) -> None:
    stored = _stored()
    stored.update(patch)
    path = home() / "config.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(stored, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def api_key(cfg: dict) -> str:
    return Path(cfg["api_key_file"]).expanduser().read_text().strip()


def _int(value, low: int, high: int, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError(f"{label}需要是 {low} 到 {high} 之间的整数")
    return value


def _flag(value, label: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{label}需要是开或关")
    return value


def _name(value, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 60:
        raise ValueError(f"{label}需要是 1 到 60 个字符")
    return value.strip()


def validate(patch: dict) -> dict:
    """Check a settings change from the web console; return it cleaned or raise ValueError."""
    if not isinstance(patch, dict):
        raise ValueError("设置格式不对")
    clean: dict = {}
    for key, value in patch.items():
        if key not in EDITABLE:
            raise ValueError(f"不能在这里修改 {key}")
        if key in ("keep_on_screen", "show_titles", "show_detail", "show_usage", "idle_show_last"):
            clean[key] = _flag(value, key)
        elif key == "font":
            if value not in FONT_CHOICES:
                raise ValueError("没有这个字体选项")
            clean[key] = value
        elif key == "max_rows":
            clean[key] = _int(value, 1, 4, "最多显示行数")
        elif key == "done_ttl_minutes":
            clean[key] = _int(value, 1, 720, "完成后保留时间")
        elif key == "stale_running_minutes":
            clean[key] = _int(value, 5, 1440, "无动静移除时间")
        elif key == "min_push_interval_seconds":
            clean[key] = _int(value, 3, 600, "最小刷新间隔")
        elif key == "aliases":
            if not isinstance(value, dict) or len(value) > 100:
                raise ValueError("别名列表格式不对")
            clean[key] = {_name(k, "项目名"): _name(v, "别名") for k, v in value.items() if str(v).strip()}
        elif key == "hidden_projects":
            if not isinstance(value, list) or len(value) > 100:
                raise ValueError("隐藏列表格式不对")
            clean[key] = sorted({_name(v, "项目名") for v in value})
        elif key == "takeover":
            if not isinstance(value, dict) or set(value) - set(DEFAULTS["takeover"]):
                raise ValueError("整屏提醒设置格式不对")
            clean[key] = {**load()["takeover"], **{k: _flag(v, "整屏提醒") for k, v in value.items()}}
        elif key == "quiet_hours":
            if not isinstance(value, dict) or set(value) - set(DEFAULTS["quiet_hours"]):
                raise ValueError("免打扰设置格式不对")
            quiet = {**load()["quiet_hours"], **value}
            _flag(quiet["enabled"], "免打扰")
            for edge in ("start", "end"):
                if not isinstance(quiet[edge], str) or not _HHMM.fullmatch(quiet[edge]):
                    raise ValueError("免打扰时间需要是 HH:MM 格式")
            if quiet["start"] == quiet["end"]:
                raise ValueError("免打扰的开始和结束时间不能相同")
            clean[key] = quiet
    return clean
