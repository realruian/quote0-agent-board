"""Quota readings from local files, and how they appear on the frame."""

from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path

from agent_board import usage
from agent_board.render import H, SAMPLE_USAGE, W, build_view, render, sample_board, signature
from agent_board.state import Board

NOW = 1_800_000_000.0


def codex_line(stamp: str, primary: dict | None, secondary: dict | None) -> str:
    return json.dumps({"timestamp": stamp, "type": "event_msg", "payload": {
        "type": "token_count", "rate_limits": {"limit_id": "codex", "primary": primary, "secondary": secondary}}})


class CodexReadingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.day = Path(self.tmp.name) / "2026" / "10" / "08"
        self.day.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_takes_the_last_record_of_the_newest_session(self):
        old = self.day / "rollout-old.jsonl"
        old.write_text(codex_line("2026-10-08T01:00:00Z", {"used_percent": 50, "window_minutes": 10080, "resets_at": 5}, None) + "\n")
        os.utime(old, (1_000_000_000, 1_000_000_000))  # long before the file written next
        new = self.day / "rollout-new.jsonl"
        new.write_text("\n".join([
            json.dumps({"type": "session_meta", "payload": {}}),
            codex_line("2026-10-08T12:00:00Z", {"used_percent": 3, "window_minutes": 300, "resets_at": 111}, None),
            "not json",
            codex_line("2026-10-08T13:30:27.413Z", {"used_percent": 4.0, "window_minutes": 300, "resets_at": 222},
                       {"used_percent": 12.5, "window_minutes": 10080, "resets_at": 333}),
            json.dumps({"type": "response_item", "payload": {"type": "message"}}),
        ]) + "\n")
        reading = usage.read_codex(Path(self.tmp.name))
        self.assertEqual(reading["windows"], {"five_hour": {"used": 4.0, "resets_at": 222.0},
                                              "seven_day": {"used": 12.5, "resets_at": 333.0}})
        self.assertAlmostEqual(reading["observed_at"], 1791466227.413, places=2)

    def test_weekly_only_plan_and_missing_files(self):
        (self.day / "rollout-a.jsonl").write_text(
            codex_line("2026-10-08T13:30:27Z", {"used_percent": 4.0, "window_minutes": 10080, "resets_at": 333}, None) + "\n")
        self.assertEqual(list(usage.read_codex(Path(self.tmp.name))["windows"]), ["seven_day"])
        self.assertIsNone(usage.read_codex(Path(self.tmp.name) / "nowhere"))


class ClaudeReadingTest(unittest.TestCase):
    def test_picks_the_fresher_of_cache_and_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache, db = Path(tmp) / "rl.json", Path(tmp) / "usage.sqlite"
            self.assertIsNone(usage.read_claude(cache, db))
            cache.write_text(json.dumps({"five_hour": {"used_percentage": 16, "resets_at": 100},
                                         "seven_day": {"used_percentage": 2, "resets_at": 200}}))
            os.utime(cache, (NOW - 500, NOW - 500))
            self.assertEqual(usage.read_claude(cache, db)["windows"]["five_hour"], {"used": 16.0, "resets_at": 100.0})
            conn = sqlite3.connect(db)
            conn.execute("create table usage_limit_records (provider text, snapshot blob)")
            conn.execute("insert into usage_limit_records values ('anthropic', ?)", (json.dumps(
                {"fetched_at": NOW - 60, "five_hour": {"used_percentage": 64, "resets_at": 300},
                 "seven_day": {"used_percentage": 27, "resets_at": 400}}),))
            conn.execute("insert into usage_limit_records values ('openai', ?)", (json.dumps({"fetched_at": NOW}),))
            conn.commit()
            conn.close()
            reading = usage.read_claude(cache, db)
            self.assertEqual((reading["observed_at"], reading["windows"]["five_hour"]["used"]), (NOW - 60, 64.0))


class TrustTest(unittest.TestCase):
    def reading(self, age: float, reset_in: float) -> dict:
        return {"observed_at": NOW - age, "windows": {"five_hour": {"used": 64.2, "resets_at": NOW + reset_in}}}

    def test_claude_is_shown_only_while_recent_and_inside_its_window(self):
        self.assertEqual(usage._left("claude", self.reading(60, 3600), NOW), {"five_hour": {"left": 36, "resets_at": NOW + 3600}})
        self.assertEqual(usage._left("claude", self.reading(3 * 3600, 3600), NOW), {})
        self.assertEqual(usage._left("claude", self.reading(60, -10), NOW), {})
        self.assertEqual(usage._left("claude", None, NOW), {})

    def test_codex_holds_until_reset_then_is_full(self):
        self.assertEqual(usage._left("codex", self.reading(3 * 86400, 3600), NOW)["five_hour"]["left"], 36)
        self.assertEqual(usage._left("codex", self.reading(3 * 86400, -10), NOW), {"five_hour": {"left": 100, "resets_at": 0}})


class QuotaOnScreenTest(unittest.TestCase):
    def test_header_carries_quota_while_working(self):
        view = build_view(sample_board("list", NOW), NOW, None, SAMPLE_USAGE)
        self.assertEqual([(q["agent"], q.get("five_hour"), q.get("seven_day")) for q in view["quota"]],
                         [("Claude", 36, 73), ("Codex", None, 95)])
        self.assertEqual(render(view).size, (W, H))

    def test_idle_lists_windows_and_says_when_there_is_nothing(self):
        reset = NOW + 3600
        live = {"claude": {"windows": {}}, "codex": {"windows": {"seven_day": {"left": 95, "resets_at": reset}}}}
        view = build_view(Board(), NOW, None, live)
        claude, codex = view["quota"]
        self.assertEqual(claude["rows"], [])
        self.assertEqual(codex["rows"], [{"window": "本周", "short": "7d", "left": 95,
                                          "reset": time.strftime("%H:%M", time.localtime(reset))}])
        self.assertEqual(render(view).size, (W, H))

    def test_turned_off_or_unread_leaves_the_frame_as_before(self):
        self.assertIsNone(build_view(Board(), NOW, {"show_usage": False}, SAMPLE_USAGE)["quota"])
        self.assertIsNone(build_view(Board(), NOW)["quota"])

    def test_small_changes_do_not_ask_for_a_refresh(self):
        def with_left(n):
            return build_view(Board(), NOW, None, {"claude": {"windows": {}},
                                                   "codex": {"windows": {"seven_day": {"left": n, "resets_at": 0}}}})
        self.assertEqual(signature(with_left(95)), signature(with_left(96)))
        self.assertNotEqual(signature(with_left(95)), signature(with_left(88)))
        self.assertNotEqual(with_left(95), with_left(96))


if __name__ == "__main__":
    unittest.main()
