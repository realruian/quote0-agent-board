"""Local settings console: a small HTTP server on 127.0.0.1, run inside the daemon.

Nothing here is reachable from other machines. Requests must name this host
(blocks DNS rebinding), carry the per-run token the page was served with, and,
when they change something, come from this origin (blocks other sites' pages).
The device API key is never sent to the browser.
"""

from __future__ import annotations

import concurrent.futures
import json
import logging
import os
import platform
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import __version__, config, dot_api, hooks
from .render import SAMPLE_USAGE, available_fonts, build_view, render, sample_board, to_png

log = logging.getLogger("agent_board")

WEB_DIR = Path(__file__).parent / "web"
STATIC = {"app.css": "text/css; charset=utf-8", "app.js": "text/javascript; charset=utf-8"}
HOLD_INTERVAL_MS = 12 * 60 * 60 * 1000  # the device API's maximum
MAX_INTERVAL_MINUTES = HOLD_INTERVAL_MS // 60000  # and its minimum is one minute
DEFAULT_INTERVAL_MS = 5 * 60 * 1000
MAX_BODY = 65536
LOG_TAIL_BYTES = 48_000


class Problem(Exception):
    """A request that cannot be served; the message is shown to the user."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


# -- what each page needs ---------------------------------------------------

def overview(app) -> dict:
    def read() -> dict:
        now = time.time()
        hidden = set(app.cfg["hidden_projects"])
        sessions = []
        for s in app.board.visible(now):
            since = {"waiting": s.waiting_since, "running": s.started_at}.get(s.state, s.finished_at)
            sessions.append({
                "project": s.project, "alias": app.cfg["aliases"].get(s.project, ""), "title": s.name or s.title,
                "source": s.source,
                "state": s.state, "wait_kind": s.wait_kind, "since": since, "hidden": s.project in hidden,
            })
        return {
            "version": __version__, "dry_run": app.dry_run, "started_at": app.started_at, "now": now,
            "view_kind": app.current_view(now)["kind"], "sessions": sessions, "last_push": app.last_push,
            "usage": app.usage or {}, "show_usage": app.cfg["show_usage"],
        }
    return app.call(read)


def frame_png(app) -> bytes:
    try:
        return app.frame_file.read_bytes()
    except FileNotFoundError:
        return to_png(render(app.call(app.current_view)))


def preview_png(app, body: dict) -> bytes:
    """Render a frame with unsaved settings, without sending it anywhere."""
    try:
        draft = {**app.cfg, **config.validate(body.get("config") or {})}
    except ValueError as e:
        raise Problem(str(e)) from None
    sample = body.get("sample", "live")
    if sample == "live":
        view = app.call(lambda: build_view(app.board, None, draft, app.usage))
    elif sample in ("list", "wait", "idle"):
        view = build_view(sample_board(sample), None, draft, SAMPLE_USAGE)
    else:
        raise Problem("未知的示例画面")
    return to_png(render(view))


def settings(app) -> dict:
    cfg = app.cfg
    known = app.call(lambda: sorted({s.project for s in app.board.sessions.values()}))
    return {"config": {key: cfg[key] for key in config.EDITABLE}, "known_projects": known, "fonts": available_fonts()}


def save_settings(app, body: dict) -> dict:
    try:
        app.call(app.apply_config, body)
    except ValueError as e:
        raise Problem(str(e)) from None
    return settings(app)


def _key_state(cfg: dict) -> dict:
    try:
        key = config.api_key(cfg)
    except OSError:
        return {"present": False, "looks_valid": False}
    return {"present": True, "looks_valid": key.startswith("dot_app")}


def _device_backup() -> Path:
    return config.home() / "device-settings-backup.json"


def device(app) -> dict:
    cfg = app.cfg
    info: dict = {"device_id": cfg["device_id"], "key": _key_state(cfg), "ok": False}
    try:
        status = dot_api.get_status(cfg)
        current = dot_api.get_settings(cfg)
        slots = {item.get("type") for item in dot_api.loop_list(cfg)}
    except Exception as e:
        info["error"] = str(e)
        return info
    interval = current.get("interval") or {}
    info.update(
        ok=True,
        status=status.get("status") or {},
        asleep=dot_api.asleep(status),
        last_render=(status.get("renderInfo") or {}).get("last", ""),
        alias=current.get("alias") or "",
        timezone=current.get("timezone", ""),
        power_minutes=round(interval.get("powerMs", 0) / 60000),
        battery_minutes=round(interval.get("batteryMs", 0) / 60000),
        hold=interval.get("powerMs") == HOLD_INTERVAL_MS,
        sleep=current.get("sleep") or {"enabled": False, "start": "23:00", "end": "07:00"},
        image_slot="IMAGE_API" in slots,
    )
    return info


def save_device(app, body: dict) -> dict:
    cfg = app.cfg
    change: dict = {}
    if "alias" in body:
        alias = body["alias"]
        if not isinstance(alias, str) or len(alias) > 100:
            raise Problem("设备名称最长 100 个字")
        change["alias"] = alias.strip() or None
    if "hold" in body:
        if not isinstance(body["hold"], bool):
            raise Problem("常显设置需要是开或关")
        backup = _device_backup()
        if body["hold"]:
            if not backup.exists():
                backup.write_text(json.dumps(dot_api.get_settings(cfg).get("interval") or {}))
            change["interval"] = {"powerMs": HOLD_INTERVAL_MS}
        else:
            saved = json.loads(backup.read_text()) if backup.exists() else {}
            previous = saved.get("powerMs")
            if not previous or previous == HOLD_INTERVAL_MS:
                previous = DEFAULT_INTERVAL_MS
            change["interval"] = {"powerMs": previous}
    if "battery_minutes" in body:
        minutes = body["battery_minutes"]
        if isinstance(minutes, bool) or not isinstance(minutes, int) or not 1 <= minutes <= MAX_INTERVAL_MINUTES:
            raise Problem(f"电池唤醒间隔需要是 1 到 {MAX_INTERVAL_MINUTES} 之间的整数分钟")
        change.setdefault("interval", {})["batteryMs"] = minutes * 60000
    if "sleep" in body:
        sleep = body["sleep"]
        try:
            clean = config.validate({"quiet_hours": sleep})["quiet_hours"]  # same shape and rules
        except ValueError:
            raise Problem("睡眠时段需要是 HH:MM 格式，且开始和结束不能相同") from None
        change["sleep"] = {"enabled": bool(sleep.get("enabled")), "start": sleep.get("start", clean["start"]),
                           "end": sleep.get("end", clean["end"])}
    if not change:
        raise Problem("没有要修改的内容")
    try:
        dot_api.update_settings(cfg, change)
    except Exception as e:
        raise Problem(f"设备设置没有保存：{e}", 502) from None
    log.info("device settings changed: %s", ", ".join(sorted(change)))
    return device(app)


def integrations(app) -> dict:
    hook = hooks.hook_path()
    return {
        "hook_installed": hook.exists() and os.access(hook, os.X_OK),
        "claude": hooks.status("claude"),
        "codex": hooks.status("codex"),
    }


def save_integration(app, body: dict) -> dict:
    agent, enabled = body.get("agent"), body.get("enabled")
    if agent not in hooks.FILES or not isinstance(enabled, bool):
        raise Problem("请求格式不对")
    try:
        result = hooks.set_enabled(agent, enabled)
    except (OSError, ValueError) as e:
        raise Problem(f"没有改成：{e}", 500) from None
    log.info("%s hooks %s: %s", agent, "enabled" if enabled else "disabled", result)
    return integrations(app)


def log_tail(app) -> dict:
    path = config.home() / "logs" / "daemon.log"
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - LOG_TAIL_BYTES))
            text = f.read().decode("utf-8", "replace")
    except FileNotFoundError:
        return {"lines": []}
    lines = text.splitlines()
    return {"lines": lines[1:] if len(text) >= LOG_TAIL_BYTES else lines}


def _ago(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 90:
        return f"{seconds} 秒"
    if seconds < 5400:
        return f"{seconds // 60} 分钟"
    return f"{seconds // 3600} 小时 {seconds % 3600 // 60} 分钟"


def run_checks(app) -> dict:
    """Walk the chain from hooks to the screen. ok: True, False, or None for 'worth a look'."""
    cfg = app.cfg
    results = []

    def add(name: str, ok: bool | None, detail: str) -> None:
        results.append({"name": name, "ok": ok, "detail": detail})

    add("后台进程", True, f"已运行 {_ago(time.time() - app.started_at)}" + ("，空跑模式" if app.dry_run else ""))
    hook = hooks.hook_path()
    add("钩子脚本", hook.exists() and os.access(hook, os.X_OK), str(hook).replace(str(Path.home()), "~"))
    for agent, label in (("claude", "Claude Code 钩子"), ("codex", "Codex 钩子")):
        st = hooks.status(agent)
        if not st["exists"]:
            add(label, None, "没有找到它的配置文件")
        elif st["installed"] == st["expected"]:
            add(label, True, f"已安装 {st['installed']} 个")
        else:
            add(label, None if st["installed"] == 0 else False,
                "未开启" if st["installed"] == 0 else f"只装了 {st['installed']}/{st['expected']} 个")
    key = _key_state(cfg)
    add("API 密钥", key["looks_valid"], "格式正确" if key["looks_valid"] else
        ("文件里的内容不像 Dot 密钥" if key["present"] else f"没有找到 {cfg['api_key_file']}"))
    try:
        slots = {item.get("type") for item in dot_api.loop_list(cfg)}
        add("连接 MindReset 服务", True, "正常")
        add("图像 API 内容", "IMAGE_API" in slots,
            "已在循环列表中" if "IMAGE_API" in slots else "循环列表里没有，请在 Dot. App 的内容工坊添加")
        status = dot_api.get_status(cfg).get("status") or {}
        add("设备状态", True, " · ".join(v for v in (status.get("current"), status.get("battery")) if v))
    except Exception as e:
        add("连接 MindReset 服务", False, str(e))
    try:
        render(build_view(sample_board("wait")))
        add("画面渲染", True, "字体可用")
    except Exception as e:
        add("画面渲染", False, str(e))
    for agent, label in (("claude", "Claude 额度数据"), ("codex", "Codex 额度数据")):
        reading = (app.usage or {}).get(agent) or {}
        if reading.get("windows"):
            add(label, True, f"{_ago(time.time() - reading['observed_at'])}前的读数")
        elif reading.get("observed_at"):
            add(label, None, f"本机最近一次读数是 {_ago(time.time() - reading['observed_at'])}前的，太旧，不显示")
        else:
            add(label, None, "本机没有找到读数")
    last = app.last_push
    if last:
        # accepted by the service but not on the screen yet: worth a look, not a fault
        add("最近一次推送", None if last.get("ok") and last.get("delivered") is False else last.get("ok", False),
            f"{_ago(time.time() - last['at'])}前，{last.get('message', '')}")
    else:
        add("最近一次推送", None, "启动后还没有推送过")
    return {"results": results}


def about(app) -> dict:
    import PIL
    home = str(config.home()).replace(str(Path.home()), "~")
    return {
        "version": __version__, "python": platform.python_version(), "pillow": PIL.__version__,
        "home": home, "config": f"{home}/config.json", "log": f"{home}/logs/daemon.log",
        "backups": f"{home}/backups", "port": getattr(app, "web_port", app.cfg["web_port"]),
        "device_id": app.cfg["device_id"],
    }


def refresh(app, body: dict) -> dict:
    app.call(app.force_refresh)
    return {"ok": True}


def test_frame(app, body: dict) -> dict:
    app.call(app.show_test_frame)
    return {"ok": True}


def restart(app, body: dict) -> dict:
    log.info("restart requested from the settings page")
    threading.Timer(0.3, lambda: app.loop.call_soon_threadsafe(app.stop.set)).start()
    return {"ok": True}


GET_JSON = {"/api/overview": overview, "/api/settings": settings, "/api/device": device,
            "/api/integrations": integrations, "/api/log": log_tail, "/api/about": about}
POST_JSON = {"/api/settings": save_settings, "/api/device": save_device, "/api/integrations": save_integration,
             "/api/check": lambda app, body: run_checks(app), "/api/refresh": refresh,
             "/api/test-frame": test_frame, "/api/restart": restart}


# -- HTTP plumbing ----------------------------------------------------------

class BoardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    app = None
    token = ""
    port = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: BoardHTTPServer

    def log_message(self, *args) -> None:  # requests are not worth a log line each
        pass

    def _send(self, status: int, body: bytes, content_type: str, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload, status: int = 200) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _origins(self) -> set[str]:
        return {f"http://127.0.0.1:{self.server.port}", f"http://localhost:{self.server.port}"}

    def _guard(self, api: bool, changing: bool) -> None:
        if f"http://{self.headers.get('Host', '')}" not in self._origins():
            raise Problem("这个页面只能通过本机地址打开", 403)
        if api and not secrets.compare_digest(self.headers.get("X-Board-Token", ""), self.server.token):
            raise Problem("页面已过期，请刷新", 403)
        if changing and self.headers.get("Origin") not in self._origins():
            raise Problem("来源不对", 403)

    def _handle(self, fn) -> None:
        try:
            fn()
        except Problem as e:
            self._json({"error": str(e)}, e.status)
        except (concurrent.futures.CancelledError, concurrent.futures.TimeoutError, RuntimeError):
            # the event loop is going away under a request that was in flight: a restart, not a fault
            self._json({"error": "后台进程正在重启，请稍后再试"}, 503)
        except Exception as e:
            log.exception("settings page request failed: %s", self.path)
            self._json({"error": f"内部错误：{e}"}, 500)

    def do_GET(self) -> None:
        self._handle(self._get)

    def do_POST(self) -> None:
        self._handle(self._post)

    def _get(self) -> None:
        path = self.path.split("?", 1)[0]
        app = self.server.app
        if path == "/":
            self._guard(api=False, changing=False)
            page = (WEB_DIR / "index.html").read_text()
            page = page.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", __version__)
            self._send(200, page.encode(), "text/html; charset=utf-8", {
                "Content-Security-Policy": "default-src 'self'; img-src 'self' blob:; style-src 'self' 'unsafe-inline'",
                "Referrer-Policy": "no-referrer",
            })
        elif path.startswith("/static/") and path[8:] in STATIC:
            self._guard(api=False, changing=False)
            self._send(200, (WEB_DIR / path[8:]).read_bytes(), STATIC[path[8:]])
        elif path == "/api/frame.png":  # an <img> cannot send the token; the frame is not sensitive to this origin
            self._guard(api=False, changing=False)
            self._send(200, frame_png(app), "image/png")
        elif path in GET_JSON:
            self._guard(api=True, changing=False)
            self._json(GET_JSON[path](app))
        else:
            raise Problem("没有这个页面", 404)

    def _post(self) -> None:
        path = self.path.split("?", 1)[0]
        if path != "/api/preview" and path not in POST_JSON:
            raise Problem("没有这个接口", 404)
        self._guard(api=True, changing=True)
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 <= length <= MAX_BODY:
            raise Problem("请求太大", 413)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            raise Problem("请求不是合法的 JSON") from None
        if not isinstance(body, dict):
            raise Problem("请求格式不对")
        if path == "/api/preview":
            self._send(200, preview_png(self.server.app, body), "image/png")
        else:
            self._json(POST_JSON[path](self.server.app, body))


def start(app, port: int) -> BoardHTTPServer | None:
    try:
        server = BoardHTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        log.warning("settings page unavailable on port %s: %s", port, e)
        return None
    server.app, server.token, server.port = app, secrets.token_urlsafe(24), server.server_address[1]
    app.web_port = server.port
    threading.Thread(target=server.serve_forever, name="web", daemon=True).start()
    log.info("settings page at http://127.0.0.1:%s", server.port)
    return server
