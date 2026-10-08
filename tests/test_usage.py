"""Quota readings, and how they appear on the frame."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

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
    # the shape the command line answers a usage request with
    ANSWER = {"subscription_type": "max", "rate_limits_available": True, "rate_limits": {
        "five_hour": {"utilization": 77, "resets_at": "2026-10-08T16:59:59.555743+00:00", "limit_dollars": None},
        "seven_day": {"utilization": 39.5, "resets_at": "2026-10-10T13:00:00.070005+00:00"},
        "seven_day_opus": None, "limits": [{"kind": "session", "percent": 77}]}}

    def setUp(self):
        usage._claude.update(asked_at=0.0, reading=None)
        patch = mock.patch.object(usage, "claude_bin", return_value="/x/claude")
        patch.start()
        self.addCleanup(patch.stop)
        self.addCleanup(usage._claude.update, asked_at=0.0, reading=None)

    def test_reads_both_windows_with_the_reset_on_the_minute(self):
        reading = usage.read_claude(NOW, lambda binary: self.ANSWER)
        self.assertEqual(reading, {"observed_at": NOW, "windows": {
            "five_hour": {"used": 77.0, "resets_at": 1791478800.0}, "seven_day": {"used": 39.5, "resets_at": 1791637200.0}}})

    def test_asks_once_in_a_while_and_keeps_the_answer(self):
        asked = []
        ask = lambda binary: asked.append(binary) or self.ANSWER
        usage.read_claude(NOW, ask)
        self.assertEqual(usage.read_claude(NOW + 30, ask)["observed_at"], NOW)
        self.assertEqual(usage.read_claude(NOW + usage.CLAUDE_EVERY, ask)["observed_at"], NOW + usage.CLAUDE_EVERY)
        self.assertEqual(asked, ["/x/claude", "/x/claude"])

    def test_an_ask_that_fails_leaves_the_earlier_reading(self):
        def broken(binary):
            raise OSError("gone")
        usage.read_claude(NOW, lambda binary: self.ANSWER)
        for at, ask in ((1, broken), (2, lambda binary: None),
                        (3, lambda binary: {"rate_limits_available": False, "rate_limits": None})):
            self.assertEqual(usage.read_claude(NOW + at * usage.CLAUDE_EVERY, ask)["observed_at"], NOW)

    def test_no_command_line_means_no_reading(self):
        with mock.patch.object(usage, "claude_bin", return_value=None):
            self.assertIsNone(usage.read_claude(NOW, lambda binary: self.fail("asked without a command line")))

    def test_talks_to_the_command_line_over_its_control_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "claude"  # answers each request the way the command line does
            fake.write_text("#!" + sys.executable + """
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    answer = {"rate_limits": {"five_hour": {"utilization": 5}}} if request["request"]["subtype"] == "get_usage" else {}
    print(json.dumps({"type": "system", "subtype": "noise"}), flush=True)
    print(json.dumps({"type": "control_response", "response": {
        "subtype": "success", "request_id": request["request_id"], "response": answer}}), flush=True)
""")
            fake.chmod(0o755)
            self.assertEqual(usage._ask_claude(str(fake)), {"rate_limits": {"five_hour": {"utilization": 5}}})
            silent = Path(tmp) / "silent"
            silent.write_text("#!/bin/sh\nexec sleep 30\n")
            silent.chmod(0o755)
            self.assertIsNone(usage._ask_claude(str(silent), timeout=0.3))


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
