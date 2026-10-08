"""Background process: receives hook events, keeps the board state, pushes frames."""

from __future__ import annotations

import asyncio
import json
import logging
import logging.handlers
import os
import re
import signal
import sys
import time

from . import config, dot_api, names, usage, web
from .render import build_view, render, signature, to_png
from .state import WAITING, Board

log = logging.getLogger("agent_board")

MAX_PAYLOAD = 65536
COALESCE_SECONDS = 2.0
URGENT_SECONDS = 0.4
RETRY_SECONDS = (15, 60, 300)
TEST_FRAME_SECONDS = 15
FAREWELL_SECONDS = 30
NAME_EVENTS = ("SessionStart", "UserPromptSubmit", "Stop")

_TOKEN = re.compile(r"[A-Za-z0-9_-]{1,32}")
_FIELD = re.compile(
    r'"(session_id|conversation_id|transcript_path|cwd|tool_name|agent_id|notification_type)"\s*:\s*"((?:[^"\\]|\\.)*)"'
)
_PROMPT = re.compile(r'"prompt"\s*:\s*"((?:[^"\\]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})){0,300})')


def parse_payload(raw: bytes) -> dict:
    """Decode hook JSON. The hook forwards only the head of large payloads, so a
    cut-off document falls back to picking out the top-level fields we need."""
    text = raw.decode("utf-8", "replace")
    try:
        data = json.loads(text)
        return data if isinstance(data, dict) else {}
    except ValueError:
        pass
    fields: dict = {}
    for name, value in _FIELD.findall(text):
        if name not in fields:
            try:
                fields[name] = json.loads(f'"{value}"')
            except ValueError:
                fields[name] = value
    prompt = _PROMPT.search(text)  # usually the field that got cut: keep its beginning
    if prompt:
        try:
            fields["prompt"] = json.loads(f'"{prompt.group(1)}"')
        except ValueError:
            pass
    return fields


def in_quiet_hours(cfg: dict, now: float | None = None) -> bool:
    quiet = cfg["quiet_hours"]
    if not quiet["enabled"]:
        return False
    clock = time.strftime("%H:%M", time.localtime(now))
    start, end = quiet["start"], quiet["end"]
    return start <= clock < end if start < end else clock >= start or clock < end


class App:
    def __init__(self, cfg: dict, dry_run: bool = False):
        self.cfg = cfg
        self.dry_run = dry_run
        self.board = Board()
        self._apply_timeouts()
        self.state_file = config.home() / "state.json"
        self.frame_file = config.home() / "last-frame.png"
        self.started_at = time.time()
        self.last_sig = ""
        self.last_push_at = 0.0
        self.last_push: dict = {}
        self.test_until = 0.0
        self.farewell_until = 0.0
        self.usage: dict | None = None  # quota readings, refreshed by the ticker
        self._seen_events: set[tuple[str, str]] = set()
        self.names_due = asyncio.Event()
        self._names_read_at = 0.0
        self.dirty = asyncio.Event()
        self.urgent = asyncio.Event()
        self.stop = asyncio.Event()
        self.loop: asyncio.AbstractEventLoop | None = None
        self._load()

    def _apply_timeouts(self) -> None:
        self.board.done_ttl = self.cfg["done_ttl_minutes"] * 60
        self.board.stale_running = self.cfg["stale_running_minutes"] * 60

    # -- persistence ----------------------------------------------------

    def _load(self) -> None:
        try:
            data = json.loads(self.state_file.read_text())
        except (FileNotFoundError, ValueError):
            return
        self.board.load_dict(data.get("board", {}))
        self.last_sig = data.get("last_sig", "")
        self.last_push = data.get("last_push", {})
        if not self.last_push and self.last_sig and self.frame_file.exists():
            # state written before pushes were recorded: the frame file dates the last one
            self.last_push = {"at": self.frame_file.stat().st_mtime, "ok": True, "kind": "", "message": "已推送"}

    def _save(self) -> None:
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps({"board": self.board.to_dict(), "last_sig": self.last_sig,
                                   "last_push": self.last_push}, ensure_ascii=False))
        os.replace(tmp, self.state_file)

    # -- events ---------------------------------------------------------

    def _waiting_keys(self) -> set[str]:
        return {s.key for s in self.board.visible() if s.state == WAITING}

    def on_event(self, source: str, event: str, payload: dict) -> None:
        if (source, event) not in self._seen_events:
            # Field names only, never values: shows what each agent's hooks actually send.
            self._seen_events.add((source, event))
            log.info("first %s %s since start; payload fields: %s", source, event, ", ".join(sorted(payload)))
        was_waiting = self._waiting_keys()
        changed = self.board.apply(source, event, payload)
        log.info("%s %s%s", source, event, " (board changed)" if changed else "")
        unnamed = any(not s.name for s in self.board.visible())
        if event in NAME_EVENTS or (unnamed and time.time() - self._names_read_at > 10):
            self.names_due.set()
        if not changed:
            return
        if self._waiting_keys() - was_waiting:
            self.urgent.set()
        self.dirty.set()
        self._save()

    async def serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """One hook message: `<source> <event> <nbytes>\\n` followed by nbytes of JSON."""
        try:
            header = (await asyncio.wait_for(reader.readline(), 2)).decode("ascii", "replace").split()
            if not header:  # a liveness probe: connected and hung up
                return
            source, event, size = header[0], header[1], int(header[2])
            if not (_TOKEN.fullmatch(source) and _TOKEN.fullmatch(event) and 0 <= size <= MAX_PAYLOAD):
                raise ValueError("malformed header")
            raw = await asyncio.wait_for(reader.readexactly(size), 2) if size else b""
        except Exception as e:  # a bad message must never take the daemon down
            log.warning("ignored hook message: %r", e)
            return
        finally:
            writer.close()
        self.on_event(source, event, parse_payload(raw))

    # -- what the web console can ask for (all run on the event loop) ---

    def call(self, fn, *args):
        """Run `fn` on the event loop from another thread and return its result."""
        async def invoke():
            return fn(*args)
        return asyncio.run_coroutine_threadsafe(invoke(), self.loop).result(timeout=10)

    def current_view(self, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        if now < self.test_until:
            return {"kind": "test", "font": self.cfg["font"], "note": f"{time.strftime('%H:%M:%S', time.localtime(self.test_until - TEST_FRAME_SECONDS))} 发送"}
        if now < self.farewell_until:
            return {"kind": "quiet", "font": self.cfg["font"], "summary": "", "line": "已退出", "last": "打开 Agent 状态牌恢复"}
        if self.cfg["paused"]:
            return {"kind": "quiet", "font": self.cfg["font"], "summary": "", "line": "已暂停", "last": "在菜单栏里恢复"}
        if in_quiet_hours(self.cfg, now):
            return {"kind": "quiet", "font": self.cfg["font"], "summary": "", "line": "夜间免打扰",
                    "last": f"{self.cfg['quiet_hours']['end']} 恢复"}
        return build_view(self.board, now, self.cfg, self.usage)

    def apply_config(self, patch: dict) -> dict:
        clean = config.validate(patch)
        config.save(clean)
        self.cfg = config.load()
        self._apply_timeouts()
        if "paused" in clean:  # asked for by hand: do not make it wait its turn
            self.urgent.set()
        self.dirty.set()
        log.info("settings changed: %s", ", ".join(sorted(clean)))
        return self.cfg

    def use_device(self, device_id: str) -> None:
        config.save({"device_id": device_id})
        self.cfg = config.load()
        log.info("device chosen in setup")
        self.force_refresh()

    def force_refresh(self) -> None:
        self.last_sig = ""
        self.urgent.set()
        self.dirty.set()

    def show_test_frame(self) -> None:
        self.test_until = time.time() + TEST_FRAME_SECONDS
        self.urgent.set()
        self.dirty.set()
        self.loop.call_later(TEST_FRAME_SECONDS + 0.5, self.force_refresh)

    def show_farewell(self) -> None:
        """The menu bar app is about to stop this process. The screen keeps its last
        frame once nothing updates it, so that frame should say the board is off.
        Should the process not be stopped after all, the board comes back by itself."""
        self.farewell_until = time.time() + FAREWELL_SECONDS
        self.urgent.set()
        self.dirty.set()
        self.loop.call_later(FAREWELL_SECONDS + 0.5, self.force_refresh)

    # -- pushing --------------------------------------------------------

    async def _settle(self) -> None:
        """Let a burst of events land. Ordinary changes also keep their distance
        from the previous refresh; a new "needs you" cuts the wait short."""
        if not self.urgent.is_set():
            gap = self.last_push_at + self.cfg["min_push_interval_seconds"] - time.time()
            try:
                await asyncio.wait_for(self.urgent.wait(), timeout=max(COALESCE_SECONDS, gap))
            except asyncio.TimeoutError:
                return
        await asyncio.sleep(URGENT_SECONDS)

    def _push(self, view: dict) -> str:
        png = to_png(render(view))
        self.frame_file.write_bytes(png)
        if self.dry_run:
            log.info("dry run: rendered %s frame, not sent", view["kind"])
            return "空跑模式，没有发送"
        if not config.ready(self.cfg):
            return "还没有连接设备，没有发送"
        message = dot_api.push_image(self.cfg, png, black_border=view["kind"] == "wait")
        log.info("pushed %s frame (%d bytes): %s", view["kind"], len(png), message)
        return message

    async def pusher(self) -> None:
        failures = 0
        while True:
            await self.dirty.wait()
            await self._settle()
            self.dirty.clear()
            self.urgent.clear()
            self.board.prune()
            view = self.current_view()
            sig = signature(view)
            if sig == self.last_sig:
                continue
            try:
                message = await asyncio.to_thread(self._push, view)
            except Exception as e:
                delay = RETRY_SECONDS[min(failures, len(RETRY_SECONDS) - 1)]
                failures += 1
                log.warning("push failed (%s); retrying in %ss", e, delay)
                self.last_push = {"at": time.time(), "ok": False, "kind": view["kind"], "message": str(e)}
                await asyncio.sleep(delay)
                self.dirty.set()
                continue
            failures = 0
            self.last_sig = sig
            self.last_push_at = time.time()
            self.last_push = {"at": self.last_push_at, "ok": True, "kind": view["kind"], "message": message,
                              "delivered": dot_api.delivered(message)}
            self._save()

    async def refresh_names(self) -> None:
        """Pick up each conversation's name from the agent's own records."""
        wanted = [(s.key, s.source, s.key.split(":", 1)[1], s.transcript) for s in self.board.sessions.values()]
        found = await asyncio.to_thread(lambda: {key: names.lookup(source, sid, path) for key, source, sid, path in wanted})
        self._names_read_at = time.time()
        changed = False
        for key, name in found.items():
            session = self.board.sessions.get(key)
            if session and name and name != session.name:  # no record in reach: keep the name we have
                session.name, changed = name, True
        if changed:
            self.dirty.set()
            self._save()

    async def namer(self) -> None:
        """Names appear a little after a conversation starts and can be edited
        later, so look after the events that tend to precede one, and now and then."""
        while True:
            try:
                await asyncio.wait_for(self.names_due.wait(), timeout=30)
            except asyncio.TimeoutError:
                pass
            self.names_due.clear()
            await asyncio.sleep(1)  # give the agent a moment to write its record
            try:
                await self.refresh_names()
            except Exception as e:
                log.warning("could not read conversation names: %s", e)

    async def read_usage(self) -> None:
        try:
            self.usage = await asyncio.to_thread(usage.snapshot)
        except Exception as e:  # a broken reading must not stop the board
            log.warning("could not read quota: %s", e)

    async def check_screen(self) -> None:
        """Put the board back if the device has moved on to other loop content, and
        send the current frame once a device that slept through one is awake again."""
        missed = self.last_push.get("delivered") is False
        if self.dry_run or not config.ready(self.cfg) or not self.last_sig or not (missed or self.cfg["keep_on_screen"]):
            return
        if time.time() - self.last_push_at < 20:  # a frame of ours is still on its way
            return
        try:
            status = await asyncio.to_thread(dot_api.get_status, self.cfg)
        except Exception as e:
            log.warning("could not check what the device is showing: %s", e)
            return
        if missed:
            if not dot_api.asleep(status):
                log.info("the device is awake again; sending the frame it missed")
                self.force_refresh()
        elif dot_api.showing_image_slot(status) is False:  # None means the device did not say; leave it alone
            log.info("the device is showing other content; putting the board back")
            self.force_refresh()

    async def ticker(self) -> None:
        """Sessions age off the board and quota moves without any event; re-check periodically."""
        beat = 0
        while True:
            await self.read_usage()
            if beat % 2:
                await self.check_screen()
            beat += 1
            self.dirty.set()
            await asyncio.sleep(30)


def _setup_logging() -> None:
    logs = config.home() / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    handlers: list[logging.Handler] = [
        logging.handlers.RotatingFileHandler(logs / "daemon.log", maxBytes=512_000, backupCount=2)
    ]
    if sys.stderr.isatty():
        handlers.append(logging.StreamHandler())
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=handlers)


async def main() -> None:
    home = config.home()
    (home / "run").mkdir(parents=True, exist_ok=True)
    os.chmod(home, 0o700)
    _setup_logging()

    cfg = config.load()
    dry_run = bool(os.environ.get("AGENT_BOARD_DRY_RUN"))
    if not config.ready(cfg) and not dry_run:
        log.info("no device yet: waiting for one to be connected in the settings page")

    app = App(cfg, dry_run=dry_run)
    app.loop = asyncio.get_running_loop()
    sock = config.socket_path()
    sock.unlink(missing_ok=True)
    server = await asyncio.start_unix_server(app.serve, path=str(sock))
    os.chmod(sock, 0o600)
    log.info("listening on %s%s", sock, " (dry run)" if dry_run else "")

    console = web.start(app, int(os.environ.get("AGENT_BOARD_PORT") or cfg["web_port"]))

    await app.read_usage()  # before the first frame, so it does not go out without quota
    app.names_due.set()
    tasks = [asyncio.create_task(app.pusher()), asyncio.create_task(app.ticker()), asyncio.create_task(app.namer())]

    for sig in (signal.SIGTERM, signal.SIGINT):
        app.loop.add_signal_handler(sig, app.stop.set)
    await app.stop.wait()

    for task in tasks:
        task.cancel()
    if console:
        console.shutdown()
    server.close()
    sock.unlink(missing_ok=True)
    config.console_path().unlink(missing_ok=True)
    log.info("stopped")


if __name__ == "__main__":
    asyncio.run(main())
