"""Minimal client for the MindReset Dot open API (https://dot.mindreset.tech/docs/service/open)."""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request

from . import config


class DotError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message


def _call(cfg: dict, method: str, path: str, body: dict | None = None, timeout: float = 20) -> dict | list:
    url = f"{cfg['api_base']}/api/authV2/open/device/{cfg['device_id']}/{path}"
    req = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {config.api_key(cfg)}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            message = json.loads(raw).get("message", raw)
        except (ValueError, AttributeError):
            message = raw[:200]
        raise DotError(e.code, message) from None


def push_image(cfg: dict, png: bytes, black_border: bool = False) -> str:
    """Show a 296x152 PNG now, in the loop list's Image API slot."""
    result = _call(cfg, "POST", "image", {
        "taskType": "loop",
        "refreshNow": True,
        "image": base64.b64encode(png).decode(),
        "border": 1 if black_border else 0,
        "ditherType": "NONE",
        "taskAlias": "Agent 状态牌",
    })
    return result.get("message", "") if isinstance(result, dict) else ""


def get_settings(cfg: dict) -> dict:
    return _call(cfg, "GET", "settings")


def update_settings(cfg: dict, body: dict) -> dict:
    """Fields left out of `body` keep their current value on the device."""
    return _call(cfg, "POST", "settings", body)


def get_status(cfg: dict) -> dict:
    return _call(cfg, "GET", "status")


def set_intervals(cfg: dict, power_ms: int | None = None, battery_ms: int | None = None) -> dict:
    interval = {}
    if power_ms is not None:
        interval["powerMs"] = power_ms
    if battery_ms is not None:
        interval["batteryMs"] = battery_ms
    return _call(cfg, "POST", "settings", {"interval": interval})


def showing_image_slot(cfg: dict) -> bool | None:
    """Whether the device's current frame comes from the Image API slot the board
    writes to. None when the status does not say what is on screen."""
    current = (get_status(cfg).get("renderInfo") or {}).get("current") or {}
    images = current.get("image") or []
    if not images:
        return None
    return any("image_api" in str(url) for url in images)


def loop_list(cfg: dict) -> list:
    return _call(cfg, "GET", "loop/list")
