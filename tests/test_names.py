"""Conversation names: read from the agents' own records, preferred on the frame."""

import json
import tempfile
import unittest
from pathlib import Path

from agent_board import names
from agent_board.render import build_view
from agent_board.state import Board

A = {"session_id": "a", "cwd": "/Users/me/Dev/alpha"}


class ClaudeNameTest(unittest.TestCase):
    def write(self, tmp: str, records: list) -> str:
        path = Path(tmp) / "session.jsonl"
        path.write_text("\n".join(r if isinstance(r, str) else json.dumps(r, ensure_ascii=False) for r in records) + "\n")
        return str(path)

    def test_latest_title_record_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, [
                {"type": "custom-title", "customTitle": "旧名字", "sessionId": "a"},
                {"type": "user", "message": {"content": 'he said "custom-title" once'}},
                {"type": "ai-title", "aiTitle": "给登录页加上\n短信验证码", "sessionId": "a"},
                {"type": "agent-name", "agentName": "别的东西", "sessionId": "a"},
                "not json but mentions \"custom-title\"",
            ])
            self.assertEqual(names.claude_name(path), "给登录页加上 短信验证码")
            self.assertEqual(names.lookup("claude", "a", path), "给登录页加上 短信验证码")

    def test_no_record_or_no_file_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(names.claude_name(self.write(tmp, [{"type": "user"}])), "")
            self.assertEqual(names.claude_name(str(Path(tmp) / "missing.jsonl")), "")
        self.assertEqual(names.claude_name(""), "")
        self.assertEqual(names.claude_name("/etc/passwd"), "")


class CodexNameTest(unittest.TestCase):
    def test_last_entry_for_the_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "session_index.jsonl"
            index.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in [
                {"id": "s1", "thread_name": "初稿", "updated_at": "x"},
                {"id": "s2", "thread_name": "另一个对话", "updated_at": "x"},
                {"id": "s1", "thread_name": "把首页改成响应式布局", "updated_at": "y"},
            ]) + "\n")
            self.assertEqual(names.codex_name("s1", index), "把首页改成响应式布局")
            self.assertEqual(names.codex_name("s2", index), "另一个对话")
            self.assertEqual(names.codex_name("s3", index), "")
            self.assertEqual(names.codex_name("", index), "")
            self.assertEqual(names.codex_name("s1", Path(tmp) / "missing.jsonl"), "")


class NameOnScreenTest(unittest.TestCase):
    def test_name_beats_the_prompt_which_beats_the_project(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", {**A, "transcript_path": "/t/a.jsonl"}, 1)
        self.assertEqual(build_view(b, 2)["rows"][0]["title"], "alpha")
        b.apply("claude", "UserPromptSubmit", {**A, "prompt": "帮我给登录页加一个短信验证码"}, 3)
        self.assertEqual(build_view(b, 4)["rows"][0]["title"], "帮我给登录页加一个短信验证码")
        session = b.sessions["claude:a"]
        self.assertEqual(session.transcript, "/t/a.jsonl")
        session.name = "给登录页加上短信验证码"
        row = build_view(b, 5)["rows"][0]
        self.assertEqual((row["title"], row["agent"]), ("给登录页加上短信验证码", "Claude"))
        self.assertEqual(build_view(b, 5, {"show_titles": False})["rows"][0]["title"], "alpha")
        b.apply("claude", "Stop", A, 6)
        b.apply("claude", "SessionEnd", A, 7)
        self.assertIn("给登录页加上短信验证码", build_view(b, 8)["last"])


if __name__ == "__main__":
    unittest.main()
