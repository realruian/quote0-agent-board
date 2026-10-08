"""Session state machine: turns agent hook events into what the board shows."""

from __future__ import annotations

import os
import re
import time
from dataclasses import asdict, dataclass

IDLE, RUNNING, WAITING, DONE, ERROR = "idle", "running", "waiting", "done", "error"

# Tools that mean "the agent is blocked on the user" as soon as they start.
QUESTION_TOOLS = {"AskUserQuestion"}
PLAN_TOOLS = {"ExitPlanMode"}

_SORT_ORDER = {WAITING: 0, RUNNING: 1, ERROR: 2, DONE: 3}
_FINISHED = (IDLE, DONE, ERROR)


def project_name(cwd: str) -> str:
    """Short label for a session, derived from its working directory."""
    if not cwd:
        return "未知项目"
    path = cwd.rstrip("/")
    worktree = re.search(r"/([^/]+)/\.claude/worktrees/[^/]+$", path)
    if worktree:
        return worktree.group(1)
    name = os.path.basename(path) or path
    if re.match(r"^scratch-\d{4}-\d{2}-\d{2}", name):
        return "临时会话"
    return name


_MARKUP = re.compile(r"<([a-zA-Z][\w-]*)\b[^>]*>.*?</\1>", re.S)
_CODEX_REQUEST = re.compile(r"^#+\s*My request for Codex:?\s*$", re.M | re.I)
TITLE_MIN_CHARS = 6
TITLE_MAX_CHARS = 60


def task_title(prompt) -> str:
    """One line saying what a prompt asks for, or "" when it says too little
    to name the task ("继续", "ok", a slash command)."""
    if not isinstance(prompt, str):
        return ""
    text = _MARKUP.sub(" ", prompt)  # reminders and pasted blocks wrapped in tags
    request = _CODEX_REQUEST.search(text)  # Codex apps list attached files first
    if request:
        text = text[request.end():]
    lines = [part.strip() for part in text.splitlines()]
    line = next((part for part in lines if part and not part.startswith("#")), "")
    line = " ".join(line.split())
    if line.startswith("/") or len(line) < TITLE_MIN_CHARS:
        return ""
    return line[:TITLE_MAX_CHARS]


@dataclass
class Session:
    key: str
    source: str
    project: str
    name: str = ""  # the conversation's name in its own app; filled in by the daemon
    title: str = ""  # stand-in until a name exists: the start of the user's prompt
    transcript: str = ""  # where the agent records the session, for looking the name up
    state: str = IDLE
    wait_kind: str = ""  # permission | question | plan
    detail: str = ""  # tool name behind a permission request
    resume_state: str = ""  # state to go back to once a wait is resolved
    waiting_since: float = 0.0
    started_at: float = 0.0
    updated_at: float = 0.0
    finished_at: float = 0.0


class Board:
    def __init__(self, done_ttl: float = 1800, stale_running: float = 3600, stale_waiting: float = 43200):
        self.sessions: dict[str, Session] = {}
        self.done_ttl = done_ttl
        self.stale_running = stale_running
        self.stale_waiting = stale_waiting
        self.last_finished: dict | None = None

    # -- events ---------------------------------------------------------

    def apply(self, source: str, event: str, payload: dict, now: float | None = None) -> bool:
        """Apply one hook event. Returns True when the visible board changed."""
        now = time.time() if now is None else now
        cwd = payload.get("cwd") or ""
        sid = payload.get("session_id") or payload.get("conversation_id") or cwd or "default"
        key = f"{source}:{sid}"
        before = self._snapshot(now)

        if event == "SessionEnd":
            self.sessions.pop(key, None)
            return self._snapshot(now) != before

        s = self.sessions.get(key)
        if s is None:
            s = self.sessions[key] = Session(key=key, source=source, project=project_name(cwd))
        elif cwd:
            s.project = project_name(cwd)

        s.transcript = payload.get("transcript_path") or s.transcript
        tool = payload.get("tool_name") or ""
        # Events from a background subagent must not revive a finished session.
        background = bool(payload.get("agent_id")) and s.state in _FINISHED

        if event == "UserPromptSubmit":
            # A short follow-up keeps the title of the task it follows up on.
            s.title = task_title(payload.get("prompt")) or s.title
            self._run(s, now, new_turn=True)
        elif event == "PreToolUse":
            if tool in QUESTION_TOOLS:
                self._wait(s, "question", tool, now)
            elif tool in PLAN_TOOLS:
                self._wait(s, "plan", tool, now)
            elif not background:
                self._run(s, now)
        elif event == "PermissionRequest":
            self._wait(s, "permission", tool, now)
        elif event in ("PostToolUse", "PostToolUseFailure"):
            if s.state == WAITING:
                s.state, s.wait_kind, s.detail = s.resume_state or RUNNING, "", ""
            elif not background:
                self._run(s, now)
        elif event == "Notification":
            if payload.get("notification_type") == "elicitation_dialog":
                self._wait(s, "question", "", now)
        elif event == "Stop":
            self._finish(s, DONE, now)
        elif event == "StopFailure":
            self._finish(s, ERROR, now)
        # SessionStart and anything unknown only registers the session.

        s.updated_at = now
        return self._snapshot(now) != before

    def _run(self, s: Session, now: float, new_turn: bool = False) -> None:
        if new_turn or s.state in _FINISHED:
            s.started_at = now
        s.state, s.wait_kind, s.detail = RUNNING, "", ""

    def _wait(self, s: Session, kind: str, detail: str, now: float) -> None:
        if s.state != WAITING:
            s.resume_state = s.state if s.state in _FINISHED else RUNNING
            s.waiting_since = now
        s.state, s.wait_kind, s.detail = WAITING, kind, detail

    def _finish(self, s: Session, state: str, now: float) -> None:
        s.state, s.wait_kind, s.detail = state, "", ""
        s.finished_at = now
        self.last_finished = {"project": s.project, "title": s.name or s.title, "source": s.source, "at": now,
                              "state": state}

    # -- views ----------------------------------------------------------

    def visible(self, now: float | None = None) -> list[Session]:
        """Sessions worth showing, most urgent first."""
        now = time.time() if now is None else now
        shown = [
            s
            for s in self.sessions.values()
            if s.state in (RUNNING, WAITING)
            or (s.state in (DONE, ERROR) and now - s.finished_at < self.done_ttl)
        ]
        shown.sort(key=lambda s: (_SORT_ORDER[s.state], -s.updated_at))
        return shown

    def _snapshot(self, now: float) -> list[tuple]:
        return [(s.key, s.project, s.name, s.title, s.state, s.wait_kind, s.detail, s.started_at, s.finished_at)
                for s in self.visible(now)]

    def prune(self, now: float | None = None) -> None:
        """Drop sessions that went quiet (crashed terminals, interrupted turns)."""
        now = time.time() if now is None else now
        for key, s in list(self.sessions.items()):
            quiet = now - s.updated_at
            if (
                (s.state == RUNNING and quiet > self.stale_running)
                or (s.state == WAITING and quiet > self.stale_waiting)
                or (s.state in (DONE, ERROR) and now - s.finished_at > self.done_ttl)
                or (s.state == IDLE and quiet > 86400)
            ):
                del self.sessions[key]

    # -- persistence ----------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "sessions": [asdict(s) for s in self.sessions.values()],
            "last_finished": self.last_finished,
        }

    def load_dict(self, data: dict) -> None:
        self.sessions = {}
        for raw in data.get("sessions", []):
            try:
                s = Session(**raw)
            except TypeError:
                continue
            self.sessions[s.key] = s
        self.last_finished = data.get("last_finished")
