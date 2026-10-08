"""Turn the board state into a 296x152 black-and-white frame for the Quote/0."""

from __future__ import annotations

import glob
import io
import json
import os
import threading
import time
from functools import lru_cache

from PIL import Image, ImageDraw, ImageFont

from .config import DEFAULTS
from .state import DONE, ERROR, RUNNING, WAITING, Board
from .usage import FIVE_HOUR, SEVEN_DAY

W, H = 296, 152
BLACK, WHITE = 0, 255
# One grid for every screen: the same side margin, a top bar, then rows on a fixed pitch.
MARGIN = 8
GAP = 8  # between columns
BAR_Y, RULE_Y = 12, 24
ROW_Y, ROW_PITCH, MAX_ROWS = 42, 31, 4
# One size per role, so rows never differ from each other.
SMALL, NAME, WAIT_NAME, TITLE = 12, 16, 20, 36

_USER_FONTS = os.path.expanduser("~/Library/Fonts")
_HIRAGINO = "/System/Library/Fonts/Hiragino Sans GB.ttc"
_ARK_PIXEL = os.path.join(os.path.dirname(__file__), "fonts", "ark-pixel-12px-proportional-zh_hans.otf")


def _pingfang() -> str:
    """Newer macOS keeps PingFang in a downloadable-asset folder whose name changes
    between releases; older ones ship it with the other system fonts."""
    found = sorted(glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc"))
    if found:
        return found[-1]
    legacy = "/System/Library/Fonts/PingFang.ttc"
    return legacy if os.path.exists(legacy) else ""


# family -> (label, regular face, bold face); a face is (file, family name, style name),
# the names picking one face out of a collection file.
FONTS = {
    "pingfang": ("苹方", (_pingfang(), "PingFang SC", "Regular"), (_pingfang(), "PingFang SC", "Semibold")),
    "misans": ("MiSans", (f"{_USER_FONTS}/MiSans-Regular.otf", "MiSans", "Regular"),
               (f"{_USER_FONTS}/MiSans-Demibold.otf", "MiSans", "Demibold")),
    "hiragino": ("冬青黑体", (_HIRAGINO, "Hiragino Sans GB", "W3"), (_HIRAGINO, "Hiragino Sans GB", "W6")),
    "arkpixel": ("方舟像素", (_ARK_PIXEL, "Ark Pixel 12px Prop zh-Hans", "Regular"),
                 (_ARK_PIXEL, "Ark Pixel 12px Prop zh-Hans", "Regular")),
}
# Pixel fonts are drawn dot by dot for one size and are only sharp at whole multiples
# of it. A role keeps to a multiple when one is close to its size; otherwise it is drawn
# at its own size, with uneven strokes, rather than visibly smaller than other fonts.
PIXEL_FONTS = {"arkpixel": 12}
PIXEL_SNAP = 0.85  # how far below a role's size a multiple may fall and still be used
# Used when the chosen family is not installed, so a frame can always be drawn:
# two system fonts, then the font that ships with this project.
FALLBACK_FACES = [(_HIRAGINO, "Hiragino Sans GB", "W3"), ("/System/Library/Fonts/STHeiti Medium.ttc", "Heiti SC", "Medium"),
                  (_ARK_PIXEL, "Ark Pixel 12px Prop zh-Hans", "Regular")]


# Drawn in place of single characters the chosen font has no glyph for. The bundled
# pixel font lacks about one common Chinese character in twenty.
SUBSTITUTE_FACES = [FALLBACK_FACES[0], FALLBACK_FACES[1], FONTS["pingfang"][1]]


def available_fonts() -> list[dict]:
    return [{"key": key, "label": label} for key, (label, regular, _) in FONTS.items() if os.path.exists(regular[0])]

AGENT_LABEL = {"claude": "Claude", "codex": "Codex"}

# 14x14 marks, dot by dot for a screen with no greys: Claude's spark and the OpenAI
# knot (the icon the Codex app shows in the Dock). Other agents get their initial.
ICON_SIZE, TAG_SIZE = 14, 18
ICONS = {
    "Claude": (
        "...##...#.....",
        "...##..##.....",
        "....##.##.##..",
        ".##..#.#.##...",
        "..#########...",
        "....######..##",
        "##...#########",
        ".###########..",
        "....######.###",
        "..##.######...",
        "..#.##.#####..",
        "....#.##.#....",
        "...#..#...#...",
        "......#.......",
    ),
    "Codex": (
        "....####......",
        "...##..#####..",
        "..##..##...##.",
        ".##..#..##..#.",
        "#.#.#####.###.",
        "#.#..####..##.",
        "#.##.#..###..#",
        "#..###..#.##.#",
        ".##..####..#.#",
        ".###.#####.#.#",
        ".#..##..#..##.",
        ".##...##..##..",
        "..#####..##...",
        "......####....",
    ),
}
WAIT_TITLE = {"permission": "等你批准", "question": "等你回答", "plan": "等你看计划"}

# The pusher and the web console render from different threads; FreeType faces are shared.
_RENDER_LOCK = threading.Lock()


def _hhmm(ts: float) -> str:
    return time.strftime("%H:%M", time.localtime(ts))


DURATION_TICK = 300  # seconds between refreshes that exist only to update running times


FRESH_MINUTES = 5  # a running task is only "under five minutes" until then


def _duration(seconds: float, running: bool = False) -> str:
    """How long something has taken, the short way: 27m, 3h. A running task
    starts out as "<5m" rather than counting each minute, which would mean a
    screen refresh a minute per task."""
    minutes = int(max(0, seconds) // 60)
    if running and minutes < FRESH_MINUTES:
        return f"<{FRESH_MINUTES}m"
    if minutes < 1:
        return "<1m"
    return f"{minutes}m" if minutes < 60 else f"{minutes // 60}h"


WINDOW_LABEL = {FIVE_HOUR: "5 小时", SEVEN_DAY: "本周"}
WINDOW_SHORT = {FIVE_HOUR: "5h", SEVEN_DAY: "7d"}
SAMPLE_USAGE = {
    "claude": {"windows": {FIVE_HOUR: {"left": 36, "resets_at": 0}, SEVEN_DAY: {"left": 73, "resets_at": 0}}},
    "codex": {"windows": {SEVEN_DAY: {"left": 95, "resets_at": 0}}},
}


def _reset_label(resets_at: float, now: float) -> str:
    """When a quota window starts over: a clock time if within a day, else the weekday.
    A fixed moment rather than a countdown, so it stays true between refreshes."""
    if not resets_at or resets_at <= now:
        return ""
    if resets_at - now < 86400:
        return _hhmm(resets_at)
    return f"周{'一二三四五六日'[time.localtime(resets_at).tm_wday]}"


def _quota(usage: dict | None, now: float) -> list[dict]:
    """One entry per agent: percent left per window, plus rows for the idle screen."""
    quota = []
    for agent in ("claude", "codex"):
        windows = ((usage or {}).get(agent) or {}).get("windows") or {}
        entry = {"agent": AGENT_LABEL[agent], "rows": []}
        for kind in (FIVE_HOUR, SEVEN_DAY):
            if kind in windows:
                entry[kind] = windows[kind]["left"]
                entry["rows"].append({"window": WINDOW_LABEL[kind], "short": WINDOW_SHORT[kind],
                                      "left": windows[kind]["left"],
                                      "reset": _reset_label(windows[kind]["resets_at"], now)})
        quota.append(entry)
    return quota


def signature(view: dict, step: int = 5) -> str:
    """Identity of a frame for deciding whether to refresh. Numbers that drift
    on their own count in steps, so the screen does not flash for each change:
    quota in five-point steps; a running time once it passes five minutes, then
    on a five-minute beat shared by every row."""
    def coarse(node):
        if isinstance(node, dict):
            out = {}
            for key, value in node.items():
                if key in ("minutes", "tick"):
                    continue
                if key == "when" and "minutes" in node:
                    out[key] = "fresh" if node["minutes"] < FRESH_MINUTES else f"beat {node['tick']}"
                elif key in ("left", FIVE_HOUR, SEVEN_DAY) and isinstance(value, (int, float)):
                    out[key] = round(value / step) * step
                else:
                    out[key] = coarse(value)
            return out
        return [coarse(v) for v in node] if isinstance(node, list) else node
    return json.dumps(coarse(view), ensure_ascii=False, sort_keys=True)


def build_view(board: Board, now: float | None = None, cfg: dict | None = None, usage: dict | None = None) -> dict:
    """Describe the frame as plain data. Equal views render to equal frames."""
    now = time.time() if now is None else now
    opt = {**DEFAULTS, **(cfg or {})}
    hidden = set(opt["hidden_projects"])
    takeover = {**DEFAULTS["takeover"], **opt["takeover"]}
    quota = _quota(usage, now) if opt["show_usage"] and usage is not None else None

    def name(project: str) -> str:
        return opt["aliases"].get(project, project)

    def headline(s) -> str:
        """What a session is called on screen: the conversation's name, else its project."""
        return ((s.name or s.title) if opt["show_titles"] else "") or name(s.project)

    shown = [s for s in board.visible(now) if s.project not in hidden]
    waiting = [s for s in shown if s.state == WAITING]
    running = [s for s in shown if s.state == RUNNING]
    blocking = [s for s in waiting if takeover.get(s.wait_kind, True)]

    if blocking:
        first = min(blocking, key=lambda s: s.waiting_since)
        others = []
        if len(waiting) > 1:
            others.append(f"另有 {len(waiting) - 1} 个在等")
        if running:
            others.append(f"{len(running)} 个运行中")
        return {
            "kind": "wait",
            "font": opt["font"],
            "title": WAIT_TITLE.get(first.wait_kind, "等你处理"),
            "task": headline(first),
            "agent": AGENT_LABEL.get(first.source, first.source),
            "detail": first.detail if opt["show_detail"] and first.wait_kind == "permission" else "",
            "since": f"{_hhmm(first.waiting_since)} 开始等",
            "footer": " · ".join(others) or "其他 Agent 空闲",
        }

    if shown:
        counts = [(len(waiting), "等你"), (len(running), "运行"),
                  (sum(s.state == DONE for s in shown), "完成"), (sum(s.state == ERROR for s in shown), "出错")]
        summary = " · ".join(f"{n} {label}" for n, label in counts if n)
        if all(s.state == DONE for s in shown):
            summary = "全部完成"
        limit = min(opt["max_rows"], MAX_ROWS)
        keep, more = len(shown), 0
        if len(shown) > limit:  # the last line then says how many are not shown
            keep = max(limit - 1, 1)
            more = len(shown) - keep
        rows = []
        for s in shown[:keep]:
            # The agent's tag carries the state (solid while working, outlined once finished).
            # The right-hand column is how long the task has run, or took; or a word when it needs a look.
            row = {"state": s.state, "agent": AGENT_LABEL.get(s.source, s.source), "title": headline(s)}
            if s.state == RUNNING:
                row.update(when=_duration(now - s.started_at, running=True), minutes=int((now - s.started_at) // 60),
                           tick=int(now // DURATION_TICK))
            elif s.state == DONE:
                row["when"] = _duration(s.finished_at - s.started_at)
            else:
                row["when"] = "等你" if s.state == WAITING else "出错"
            rows.append(row)
        return {"kind": "list", "font": opt["font"], "summary": summary, "rows": rows, "more": more, "quota": quota}

    last = board.last_finished
    show_last = opt["idle_show_last"] and last and last["project"] not in hidden
    last_label = (opt["show_titles"] and last.get("title")) or name(last["project"]) if show_last else ""
    return {
        "kind": "idle",
        "font": opt["font"],
        "line": "没有运行中的 Agent",
        "last": f"上次：{last_label} · {_hhmm(last['at'])}" if show_last else "",
        "quota": quota,
    }


def sample_board(kind: str, now: float | None = None) -> Board:
    """A made-up board for previewing settings without touching the real one."""
    now = time.time() if now is None else now
    board = Board()
    if kind == "idle":
        board.last_finished = {"project": "website", "title": "把首页改成响应式布局", "source": "claude",
                               "at": now - 900, "state": DONE}
        return board
    def ask(agent: str, sid: str, project: str, prompt: str, ago: float) -> None:
        board.apply(agent, "UserPromptSubmit", {"session_id": sid, "cwd": f"/demo/{project}", "prompt": prompt}, now - ago)

    ask("claude", "1", "mobile-app", "给登录页加上短信验证码", 1500)
    ask("codex", "2", "data-pipeline", "修复订单导出的时区问题", 600)
    ask("claude", "3", "website", "把首页改成响应式布局", 2400)
    board.apply("claude", "Stop", {"session_id": "3"}, now - 900)
    ask("codex", "4", "docs", "更新接口文档里的鉴权说明", 1200)
    board.apply("codex", "StopFailure", {"session_id": "4"}, now - 300)
    if kind == "wait":
        board.apply("claude", "PermissionRequest", {"session_id": "1", "tool_name": "Bash"}, now - 45)
    return board


@lru_cache(maxsize=16)
def _face_index(path: str, family: str, style: str) -> int:
    """Position of one named face inside a font file (collections hold many)."""
    for index in range(64):
        try:
            if ImageFont.truetype(path, 12, index=index).getname() == (family, style):
                return index
        except OSError:
            break
    return 0


@lru_cache(maxsize=96)
def _load(family: str, size: int, bold: bool) -> ImageFont.FreeTypeFont:
    if family in PIXEL_FONTS:
        unit = PIXEL_FONTS[family]
        sharp = max(1, round(size / unit)) * unit
        size = sharp if sharp >= size * PIXEL_SNAP else size
    chosen = FONTS.get(family, FONTS["hiragino"])[2 if bold else 1]
    for path, name, style in (chosen, *FALLBACK_FACES):
        if path and os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=_face_index(path, name, style))
            except OSError:
                continue
    raise RuntimeError("no usable Chinese font found; see FONTS in render.py")


@lru_cache(maxsize=32)
def _sized(path: str, index: int, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size, index=index)


_family = "hiragino"  # set per frame by _render, which holds the render lock


def _font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return _load(_family, size, bold)


@lru_cache(maxsize=16)
def _probe(path: str, index: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, 12, index=index)


@lru_cache(maxsize=8192)
def _covers(path: str, index: int, char: str) -> bool:
    """Whether a face has its own drawing for a character. Pillow does not say, so
    compare with what the face draws for a code point that no font assigns."""
    def drawn(text: str) -> tuple:
        mask = _probe(path, index).getmask(text, mode="1")
        return mask.size, bytes(mask)
    return char.isspace() or drawn(char) != drawn("\U0010ffff")


def _runs(text: str, font: ImageFont.FreeTypeFont) -> list[tuple[str, ImageFont.FreeTypeFont]]:
    """Split text by the face that draws it: the chosen one where it has the character,
    otherwise the first substitute that does, so a gap in a font is not a blank box."""
    runs: list[tuple[str, ImageFont.FreeTypeFont]] = []
    for char in text:
        face = font
        if not _covers(font.path, font.index, char):
            for path, name, style in SUBSTITUTE_FACES:
                if path and os.path.exists(path) and _covers(path, _face_index(path, name, style), char):
                    face = _sized(path, _face_index(path, name, style), font.size)
                    break
        if runs and runs[-1][1] is face:
            runs[-1] = (runs[-1][0] + char, face)
        else:
            runs.append((char, face))
    return runs


def _length(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont) -> float:
    return sum(draw.textlength(part, font=face) for part, face in _runs(text, font))


def _text(draw: ImageDraw.ImageDraw, xy, text: str, font: ImageFont.FreeTypeFont, fill, anchor: str) -> None:
    """`draw.text` for one line, with characters the font lacks drawn from a substitute."""
    runs = _runs(text, font)
    if all(face is font for _, face in runs):
        draw.text(xy, text, font=font, fill=fill, anchor=anchor)
        return
    x, y = xy
    x -= {"l": 0, "m": 0.5, "r": 1}[anchor[0]] * _length(draw, text, font)
    if anchor[1] == "m":  # every run sits on the chosen font's baseline
        ascent, descent = font.getmetrics()
        y += (ascent - descent) / 2
    for part, face in runs:
        draw.text((x, y), part, font=face, fill=fill, anchor="ls")
        x += draw.textlength(part, font=face)


def _fit(draw: ImageDraw.ImageDraw, text: str, font, max_width: float) -> str:
    if _length(draw, text, font) <= max_width:
        return text
    while text and _length(draw, text + "…", font) > max_width:
        text = text[:-1]
    return text + "…"


@lru_cache(maxsize=8)
def _icon(agent: str) -> Image.Image | None:
    rows = ICONS.get(agent)
    if not rows:
        return None
    icon = Image.new("1", (ICON_SIZE, ICON_SIZE), 0)
    icon.putdata([255 if cell == "#" else 0 for row in rows for cell in row])
    return icon


def _mark(draw: ImageDraw.ImageDraw, x: int, y: int, agent: str, ink: int) -> None:
    """The agent's mark with its top-left corner at (x, y)."""
    icon = _icon(agent)
    if icon:
        draw.bitmap((x, y), icon, fill=ink)
    else:
        _text(draw, (x + ICON_SIZE / 2, y + ICON_SIZE / 2), agent[:1], font=_font(SMALL, True), fill=ink, anchor="mm")


def _tag(draw: ImageDraw.ImageDraw, x: int, y: int, agent: str, ink: int, paper: int, solid: bool = False) -> int:
    """The agent's mark in a small square centred on y: solid while the conversation
    is at work, outlined once it has finished. Returns the square's right edge."""
    half, inset = TAG_SIZE // 2, (TAG_SIZE - ICON_SIZE) // 2
    draw.rounded_rectangle([(x, y - half), (x + TAG_SIZE - 1, y + half - 1)], radius=3,
                           outline=ink, fill=ink if solid else paper)
    _mark(draw, x + inset, y - half + inset, agent, paper if solid else ink)
    return x + TAG_SIZE


def _header(draw: ImageDraw.ImageDraw, right: str, ink: int) -> None:
    _text(draw, (MARGIN, BAR_Y), "AGENTS", font=_font(SMALL, True), fill=ink, anchor="lm")
    if right:
        _text(draw, (W - MARGIN, BAR_Y), right, font=_font(SMALL), fill=ink, anchor="rm")


def _quota_header(draw: ImageDraw.ImageDraw, quota: list[dict], ink: int) -> None:
    """Top bar while agents are working: per agent its mark, then what is left of each
    window and when that window resets, e.g. `5h 36% 14:30  7d 73% 周六`."""
    font = _font(SMALL)

    def texts(resets: int) -> list[str]:
        # resets: 2 = every window shows its reset, 1 = only the first of each agent, 0 = none
        out = []
        for entry in quota:
            parts = [" ".join(filter(None, (row["short"], f"{row['left']}%", row["reset"] if i < resets else "")))
                     for i, row in enumerate(entry["rows"])]
            out.append("  ".join(parts) or "—")
        return out

    def width(parts: list[str]) -> float:
        return sum(ICON_SIZE + 4 + _length(draw, text, font) for text in parts) + GAP

    parts = next((t for t in map(texts, (2, 1, 0)) if width(t) <= W - 2 * MARGIN), texts(0))
    top = BAR_Y - ICON_SIZE // 2
    _mark(draw, MARGIN, top, quota[0]["agent"], ink)
    _text(draw, (MARGIN + ICON_SIZE + 4, BAR_Y), parts[0], font=font, fill=ink, anchor="lm")
    right_x = W - MARGIN - _length(draw, parts[1], font)
    _text(draw, (right_x, BAR_Y), parts[1], font=font, fill=ink, anchor="lm")
    _mark(draw, round(right_x) - 4 - ICON_SIZE, top, quota[1]["agent"], ink)


def _quota_panel(draw: ImageDraw.ImageDraw, quota: list[dict], ink: int) -> None:
    """Idle screen: one bar per quota window, showing what is left and when it resets."""
    label_x, bar_x, bar_w = MARGIN + ICON_SIZE + GAP, 76, 84
    y = 40
    for entry in quota:
        _mark(draw, MARGIN, y - ICON_SIZE // 2, entry["agent"], ink)
        if not entry["rows"]:
            _text(draw, (label_x, y), "暂无数据", font=_font(SMALL), fill=ink, anchor="lm")
            y += 22
        for row in entry["rows"]:
            _text(draw, (label_x, y), row["window"], font=_font(SMALL), fill=ink, anchor="lm")
            draw.rectangle([(bar_x, y - 5), (bar_x + bar_w, y + 5)], outline=ink)
            filled = round((bar_w - 4) * row["left"] / 100)
            if filled:
                draw.rectangle([(bar_x + 2, y - 3), (bar_x + 2 + filled, y + 3)], fill=ink)
            _text(draw, (bar_x + bar_w + GAP, y), f"{row['left']}%", font=_font(SMALL, True), fill=ink, anchor="lm")
            if row["reset"]:
                _text(draw, (W - MARGIN, y), f"{row['reset']} 重置", font=_font(SMALL), fill=ink, anchor="rm")
            y += 22


def render(view: dict) -> Image.Image:
    with _RENDER_LOCK:
        return _render(view)


def _render(view: dict) -> Image.Image:
    global _family
    _family = view.get("font") or DEFAULTS["font"]
    kind = view["kind"]
    paper, ink = (BLACK, WHITE) if kind == "wait" else (WHITE, BLACK)
    img = Image.new("1", (W, H), paper)
    draw = ImageDraw.Draw(img)
    draw.fontmode = "1"  # no antialiasing: the panel has no greys

    if kind == "wait":
        _header(draw, view["since"], ink)
        _text(draw, (MARGIN, 52), view["title"], font=_font(TITLE, True), fill=ink, anchor="lm")
        name_x = _tag(draw, MARGIN, 98, view["agent"], ink, paper, solid=True) + GAP
        name_font = _font(WAIT_NAME, True)
        _text(draw, (name_x, 98), _fit(draw, view["task"], name_font, W - MARGIN - name_x),
                  font=name_font, fill=ink, anchor="lm")
        footer = " · ".join(part for part in (view["detail"], view["footer"]) if part)
        _text(draw, (MARGIN, 136), _fit(draw, footer, _font(SMALL), W - 2 * MARGIN),
                  font=_font(SMALL), fill=ink, anchor="lm")
        return img

    if kind == "test":
        draw.rectangle([(0, 0), (W - 1, H - 1)], outline=ink)
        for x, y in ((4, 4), (W - 16, 4), (4, H - 16), (W - 16, H - 16)):
            draw.rectangle([(x, y), (x + 11, y + 11)], fill=ink)
        _text(draw, (W // 2, 66), "测试画面", font=_font(28, True), fill=ink, anchor="mm")
        _text(draw, (W // 2, 100), view["note"], font=_font(13), fill=ink, anchor="mm")
        return img

    quota = view.get("quota")
    if kind == "list" and quota:
        _quota_header(draw, quota, ink)
    else:
        _header(draw, "空闲" if kind == "idle" and quota else view.get("summary", ""), ink)
    draw.line([(MARGIN, RULE_Y), (W - MARGIN, RULE_Y)], fill=ink, width=1)

    if kind == "idle" and quota:
        _quota_panel(draw, quota, ink)
        if view["last"]:
            _text(draw, (MARGIN, 139), _fit(draw, view["last"], _font(SMALL), W - 2 * MARGIN),
                      font=_font(SMALL), fill=ink, anchor="lm")
        return img

    if kind in ("idle", "quiet"):
        _text(draw, (W // 2, 78), view["line"], font=_font(18, True), fill=ink, anchor="mm")
        if view["last"]:
            _text(draw, (W // 2, 108), _fit(draw, view["last"], _font(12), W - 24),
                      font=_font(12), fill=ink, anchor="mm")
        return img

    # One line per conversation, in three columns that hold their place from row to row:
    # the agent's tag, the conversation's name, and how long it has run on the right.
    small, name_font = _font(SMALL), _font(NAME, True)
    name_x = MARGIN + TAG_SIZE + GAP
    when_width = max(_length(draw, text, small) for text in ("<5m", "59m", "等你", "出错"))
    name_width = W - MARGIN - when_width - GAP - name_x
    y = ROW_Y
    for row in view["rows"]:
        _tag(draw, MARGIN, y, row["agent"], ink, paper, solid=row["state"] in (RUNNING, WAITING))
        _text(draw, (name_x, y), _fit(draw, row["title"], name_font, name_width), font=name_font, fill=ink, anchor="lm")
        _text(draw, (W - MARGIN, y), row["when"], font=small, fill=ink, anchor="rm")
        y += ROW_PITCH
    if view["more"]:
        _text(draw, (name_x, y), f"还有 {view['more']} 个", font=small, fill=ink, anchor="lm")
    return img


def to_png(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.convert("L").save(buf, format="PNG", optimize=True)
    return buf.getvalue()
