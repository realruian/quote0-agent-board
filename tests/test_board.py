import unittest

from agent_board.daemon import parse_payload
from agent_board.render import H, W, build_view, render, sample_board
from agent_board.state import DONE, ERROR, IDLE, RUNNING, WAITING, Board, project_name, task_title

A = {"session_id": "a", "cwd": "/Users/me/Dev/alpha"}
B = {"session_id": "b", "cwd": "/Users/me/Dev/beta"}


def states(board, now):
    return [(s.project, s.state) for s in board.visible(now)]


class BoardTest(unittest.TestCase):
    def test_turn_lifecycle(self):
        b = Board()
        self.assertFalse(b.apply("claude", "SessionStart", A, 0))
        self.assertEqual(states(b, 0), [])
        self.assertTrue(b.apply("claude", "UserPromptSubmit", A, 1))
        self.assertFalse(b.apply("claude", "PreToolUse", {**A, "tool_name": "Read"}, 2))
        self.assertFalse(b.apply("claude", "PostToolUse", {**A, "tool_name": "Read"}, 3))
        self.assertEqual(states(b, 3), [("alpha", RUNNING)])
        self.assertTrue(b.apply("claude", "Stop", A, 4))
        self.assertEqual(states(b, 4), [("alpha", DONE)])
        self.assertTrue(b.apply("claude", "SessionEnd", A, 5))
        self.assertEqual(states(b, 5), [])

    def test_permission_wait_resolves_on_tool_result(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("claude", "PreToolUse", {**A, "tool_name": "Bash"}, 2)
        self.assertTrue(b.apply("claude", "PermissionRequest", {**A, "tool_name": "Bash"}, 3))
        s = b.visible(3)[0]
        self.assertEqual((s.state, s.wait_kind, s.detail, s.waiting_since), (WAITING, "permission", "Bash", 3))
        self.assertTrue(b.apply("claude", "PostToolUse", {**A, "tool_name": "Bash"}, 9))
        self.assertEqual(states(b, 9), [("alpha", RUNNING)])

    def test_question_and_plan_tools_wait(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("claude", "PreToolUse", {**A, "tool_name": "AskUserQuestion"}, 2)
        self.assertEqual(b.visible(2)[0].wait_kind, "question")
        b.apply("claude", "PostToolUse", {**A, "tool_name": "AskUserQuestion"}, 3)
        b.apply("claude", "PreToolUse", {**A, "tool_name": "ExitPlanMode"}, 4)
        self.assertEqual(b.visible(4)[0].wait_kind, "plan")

    def test_waiting_sorts_first_and_error_shows(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("codex", "UserPromptSubmit", B, 2)
        b.apply("codex", "StopFailure", B, 3)
        b.apply("claude", "PermissionRequest", {**A, "tool_name": "Edit"}, 4)
        self.assertEqual(states(b, 4), [("alpha", WAITING), ("beta", ERROR)])

    def test_background_subagent_does_not_revive_finished_session(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("claude", "Stop", A, 2)
        sub = {**A, "agent_id": "x", "tool_name": "Read"}
        self.assertFalse(b.apply("claude", "PreToolUse", sub, 3))
        self.assertFalse(b.apply("claude", "PostToolUse", sub, 4))
        # ...but it can still need the user, and goes back to done afterwards.
        self.assertTrue(b.apply("claude", "PermissionRequest", {**sub, "tool_name": "Bash"}, 5))
        self.assertTrue(b.apply("claude", "PostToolUse", {**sub, "tool_name": "Bash"}, 6))
        self.assertEqual(states(b, 6), [("alpha", DONE)])

    def test_ageing(self):
        b = Board(done_ttl=100, stale_running=500)
        b.apply("claude", "UserPromptSubmit", A, 0)
        b.apply("claude", "Stop", A, 10)
        b.apply("codex", "UserPromptSubmit", B, 10)
        self.assertEqual(len(b.visible(50)), 2)
        self.assertEqual(states(b, 200), [("beta", RUNNING)])
        b.prune(600)
        self.assertEqual(b.sessions, {})
        self.assertEqual(b.last_finished["project"], "alpha")

    def test_persistence_round_trip(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("claude", "PermissionRequest", {**A, "tool_name": "Bash"}, 2)
        c = Board()
        c.load_dict(b.to_dict())
        self.assertEqual(states(c, 2), states(b, 2))
        self.assertEqual(c.sessions["claude:a"].waiting_since, 2)

    def test_project_name(self):
        self.assertEqual(project_name("/Users/me/Dev/alpha/"), "alpha")
        self.assertEqual(project_name("/Users/me/Dev/alpha/.claude/worktrees/fix-1"), "alpha")
        self.assertEqual(project_name("/x/scratch-2026-10-08-c1b5d9"), "临时会话")
        self.assertEqual(project_name(""), "未知项目")


class PayloadTest(unittest.TestCase):
    def test_complete_json(self):
        self.assertEqual(parse_payload(b'{"session_id":"a","cwd":"/x"}'), {"session_id": "a", "cwd": "/x"})

    def test_truncated_json_keeps_leading_fields(self):
        raw = ('{"session_id":"a","cwd":"/Users/me/Dev/\\u6587\\u6863","hook_event_name":"PostToolUse",'
               '"tool_name":"Write","tool_input":{"content":"\\"session_id\\":\\"fake\\" and then it is cut of')
        self.assertEqual(parse_payload(raw.encode()),
                         {"session_id": "a", "cwd": "/Users/me/Dev/文档", "tool_name": "Write"})

    def test_cut_off_prompt_keeps_its_beginning(self):
        raw = '{"session_id":"a","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"修复订单导出\\n的时区问题，然后\\'
        self.assertEqual(parse_payload(raw.encode()),
                         {"session_id": "a", "cwd": "/x", "prompt": "修复订单导出\n的时区问题，然后"})

    def test_garbage(self):
        self.assertEqual(parse_payload(b""), {})
        self.assertEqual(parse_payload(b"[1,2]"), {})


class RenderTest(unittest.TestCase):
    def test_views_and_frame_size(self):
        b = Board()
        self.assertEqual(build_view(b, 0)["kind"], "idle")
        b.apply("claude", "UserPromptSubmit", A, 1)
        self.assertEqual(build_view(b, 1)["kind"], "list")
        b.apply("claude", "PermissionRequest", {**A, "tool_name": "Bash"}, 2)
        view = build_view(b, 2)
        self.assertEqual((view["kind"], view["title"], view["task"], view["agent"], view["detail"]),
                         ("wait", "等你批准", "alpha", "Claude", ""))
        self.assertEqual(build_view(b, 2, {"show_detail": True})["detail"], "Bash")
        self.assertEqual(render(view).size, (W, H))

    def test_rows_show_the_task_and_keep_it_across_short_follow_ups(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", {**A, "prompt": "修复订单导出的时区问题"}, 1)
        row = build_view(b, 2)["rows"][0]
        self.assertEqual((row["title"], row["agent"], row["state"]), ("修复订单导出的时区问题", "Claude", RUNNING))
        b.apply("claude", "UserPromptSubmit", {**A, "prompt": "继续"}, 3)
        self.assertEqual(build_view(b, 4)["rows"][0]["title"], "修复订单导出的时区问题")
        plain = build_view(b, 4, {"show_titles": False})["rows"][0]
        self.assertEqual((plain["title"], plain["agent"]), ("alpha", "Claude"))
        b.apply("claude", "PermissionRequest", {**A, "tool_name": "Bash"}, 5)
        wait = build_view(b, 6, {"show_detail": True})
        self.assertEqual((wait["task"], wait["agent"], wait["detail"]), ("修复订单导出的时区问题", "Claude", "Bash"))
        self.assertEqual(render(wait).size, (W, H))
        b.apply("claude", "Stop", A, 7)
        b.apply("claude", "SessionEnd", A, 8)
        self.assertIn("修复订单导出的时区问题", build_view(b, 9)["last"])

    def test_task_title_cleans_the_prompt(self):
        self.assertEqual(task_title("  帮我把首页改成响应式\n第二行不要 "), "帮我把首页改成响应式")
        self.assertEqual(task_title("<system-reminder>别管我\n多行</system-reminder>\n修复订单导出的时区问题"), "修复订单导出的时区问题")
        self.assertEqual(len(task_title("长" * 200)), 60)
        codex = "# Files mentioned by the user:\n\n## shot.png: /tmp/shot.png\n\n## My request for Codex:\n按这张截图调整首页的间距\n"
        self.assertEqual(task_title(codex), "按这张截图调整首页的间距")
        self.assertEqual(task_title("# 标题行\n真正要做的事情写在这里"), "真正要做的事情写在这里")
        for too_little in ("继续", "ok", "/compact 然后继续干活", "", None, 42):
            self.assertEqual(task_title(too_little), "", too_little)

    def test_display_options(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("codex", "UserPromptSubmit", B, 2)
        self.assertEqual(build_view(b, 3, {"aliases": {"alpha": "甲"}})["rows"][1]["title"], "甲")
        hidden = build_view(b, 3, {"hidden_projects": ["beta"]})
        self.assertEqual([r["title"] for r in hidden["rows"]], ["alpha"])
        one = build_view(b, 3, {"max_rows": 1})
        self.assertEqual((len(one["rows"]), one["more"]), (1, 1))

    def test_takeover_can_be_turned_off_per_kind(self):
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("claude", "PermissionRequest", {**A, "tool_name": "Bash"}, 2)
        view = build_view(b, 3, {"takeover": {"permission": False}})
        self.assertEqual((view["kind"], view["summary"], view["rows"][0]["when"]), ("list", "1 等你", "等你"))
        self.assertEqual(render(view).size, (W, H))
        # a hidden project never takes the screen over
        self.assertEqual(build_view(b, 3, {"hidden_projects": ["alpha"]})["kind"], "idle")

    def test_idle_respects_privacy_options(self):
        b = Board(done_ttl=10)
        b.apply("claude", "UserPromptSubmit", A, 1)
        b.apply("claude", "Stop", A, 2)
        self.assertIn("alpha", build_view(b, 100)["last"])
        self.assertEqual(build_view(b, 100, {"idle_show_last": False})["last"], "")
        self.assertEqual(build_view(b, 100, {"hidden_projects": ["alpha"]})["last"], "")

    def test_every_font_choice_renders_and_changes_the_frame_identity(self):
        from agent_board.config import FONT_CHOICES
        from agent_board.render import FONTS, signature
        self.assertEqual(set(FONT_CHOICES), set(FONTS))
        views = [build_view(sample_board("list"), 5, {"font": font}) for font in FONT_CHOICES]
        for view in views:
            self.assertEqual(render(view).size, (W, H))
        self.assertEqual(len({signature(view) for view in views}), len(views))
        self.assertEqual(render({**views[0], "font": "not-installed"}).size, (W, H))

    def test_long_names_stay_on_one_line_with_an_ellipsis(self):
        from agent_board.render import _fit, _font
        from PIL import Image, ImageDraw
        draw = ImageDraw.Draw(Image.new("1", (W, H)))
        font = _font(16, True)
        self.assertEqual(_fit(draw, "更新接口文档", font, 160), "更新接口文档")
        cut = _fit(draw, "一个特别特别特别长的对话名称放不下", font, 160)
        self.assertTrue(cut.endswith("…") and draw.textlength(cut, font=font) <= 160)

    def test_pixel_font_is_never_much_smaller_than_the_other_fonts(self):
        from agent_board.render import _load
        sizes = {asked: _load("arkpixel", asked, True).size for asked in (12, 16, 20, 36)}
        self.assertEqual(sizes, {12: 12, 16: 16, 20: 24, 36: 36})  # a sharp multiple when one is near

    def test_characters_a_font_lacks_come_from_a_substitute(self):
        from agent_board.render import _fit, _length, _load, _runs
        from PIL import Image, ImageDraw
        font = _load("arkpixel", 16, True)
        self.assertEqual(_runs("更新接口文档", font), [("更新接口文档", font)])
        parts = _runs("鉴权说明", font)  # the pixel font has no 鉴
        self.assertEqual([text for text, _ in parts], ["鉴", "权说明"])
        self.assertIsNot(parts[0][1], font)
        self.assertEqual(parts[0][1].size, font.size)
        draw = ImageDraw.Draw(Image.new("1", (W, H)))
        self.assertLessEqual(_length(draw, _fit(draw, "鉴权说明" * 8, font, 160), font), 160)
        self.assertEqual(render(build_view(sample_board("list"), 5, {"font": "arkpixel"})).size, (W, H))

    def test_samples_and_special_frames_render(self):
        for kind in ("list", "wait", "idle"):
            self.assertEqual(build_view(sample_board(kind))["kind"], kind)
        for view in ({"kind": "test", "note": "x"}, {"kind": "quiet", "summary": "", "line": "夜间免打扰", "last": "07:00 恢复"}):
            self.assertEqual(render(view).size, (W, H))

    def test_running_time_refreshes_at_five_minutes_then_on_a_shared_beat(self):
        from agent_board.render import signature
        b = Board()
        b.apply("claude", "UserPromptSubmit", A, 1000)
        at = lambda seconds: build_view(b, 1000 + seconds)
        self.assertEqual([at(s)["rows"][0]["when"] for s in (5, 70, 27 * 60, 3 * 3600 + 5)], ["<5m", "<5m", "27m", "3h"])
        # tool activity alone never asks for a refresh
        b.apply("claude", "PostToolUse", {**A, "tool_name": "Read"}, 1010)
        self.assertEqual(signature(at(5)), signature(at(50)))
        self.assertEqual(signature(at(50)), signature(at(290)))          # still "<5m": no refresh
        self.assertNotEqual(signature(at(290)), signature(at(310)))       # five minutes in
        self.assertEqual(signature(at(400)), signature(at(450)))          # inside one five-minute beat
        self.assertNotEqual(signature(at(400)), signature(at(1000)))      # a later beat
        # a finished task shows how long it took, and that never changes
        b.apply("claude", "Stop", A, 1000 + 12 * 60)
        self.assertEqual(at(12 * 60 + 5)["rows"][0]["when"], "12m")
        self.assertEqual(signature(at(12 * 60 + 5)), signature(at(25 * 60)))

    def test_overflow_rows(self):
        b = Board()
        for i in range(6):
            b.apply("claude", "UserPromptSubmit", {"session_id": str(i), "cwd": f"/p/{i}"}, i)
        view = build_view(b, 10)
        self.assertEqual((len(view["rows"]), view["more"]), (3, 3))


if __name__ == "__main__":
    unittest.main()
