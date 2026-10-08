"""The settings console: config rules, hook editing, quiet hours and the HTTP guard."""

import asyncio
import http.client
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

_HOME = tempfile.TemporaryDirectory()
os.environ["AGENT_BOARD_HOME"] = _HOME.name

from agent_board import config, dot_api, hooks, web  # noqa: E402
from agent_board.daemon import App, in_quiet_hours  # noqa: E402


def at(clock: str) -> float:
    return time.mktime(time.strptime(f"2026-10-08 {clock}", "%Y-%m-%d %H:%M"))


class ConfigTest(unittest.TestCase):
    def test_accepts_and_cleans(self):
        clean = config.validate({"max_rows": 2, "aliases": {" alpha ": " 甲 ", "beta": ""}, "hidden_projects": ["b", "a", "a"]})
        self.assertEqual(clean, {"max_rows": 2, "aliases": {"alpha": "甲"}, "hidden_projects": ["a", "b"]})

    def test_rejects_bad_values(self):
        for patch in ({"max_rows": 9}, {"max_rows": True}, {"device_id": "x"}, {"show_detail": 1},
                      {"quiet_hours": {"start": "25:00"}}, {"quiet_hours": {"start": "07:00", "end": "07:00"}},
                      {"takeover": {"nope": True}}, {"aliases": []}, {"font": "comic"}):
            with self.assertRaises(ValueError, msg=patch):
                config.validate(patch)

    def test_partial_nested_patch_keeps_the_rest(self):
        config.save(config.validate({"takeover": {"permission": False}}))
        config.save(config.validate({"takeover": {"plan": False}}))
        self.assertEqual(config.load()["takeover"], {"permission": False, "question": True, "plan": False})
        config.save(config.validate({"quiet_hours": {"enabled": True}}))
        self.assertEqual(config.load()["quiet_hours"], {"enabled": True, "start": "23:00", "end": "07:00"})
        config.save({"takeover": config.DEFAULTS["takeover"], "quiet_hours": config.DEFAULTS["quiet_hours"]})


class QuietHoursTest(unittest.TestCase):
    def test_window_may_cross_midnight(self):
        night = {"quiet_hours": {"enabled": True, "start": "23:00", "end": "07:00"}}
        self.assertTrue(in_quiet_hours(night, at("23:30")))
        self.assertTrue(in_quiet_hours(night, at("06:59")))
        self.assertFalse(in_quiet_hours(night, at("07:00")))
        self.assertFalse(in_quiet_hours(night, at("12:00")))
        noon = {"quiet_hours": {"enabled": True, "start": "12:00", "end": "14:00"}}
        self.assertTrue(in_quiet_hours(noon, at("13:00")))
        self.assertFalse(in_quiet_hours(noon, at("14:00")))
        self.assertFalse(in_quiet_hours({"quiet_hours": {**night["quiet_hours"], "enabled": False}}, at("23:30")))


class HooksTest(unittest.TestCase):
    def test_add_is_additive_and_remove_restores_the_file(self):
        other = {"hooks": [{"type": "command", "command": "'/x/.vibe-island/bin/vibe-island-bridge' --source claude"}]}
        original = json.dumps({"model": "x", "hooks": {"Stop": [other], "PreCompact": [other]}}, indent=2)
        for agent in ("claude", "codex"):
            path = Path(_HOME.name) / f"{agent}.json"
            path.write_text(original)
            self.assertEqual(hooks.edit(path, hooks.groups_for(agent)), "updated")
            self.assertEqual(hooks.edit(path, hooks.groups_for(agent)), "already up to date")
            data = json.loads(path.read_text())
            self.assertEqual(data["hooks"]["Stop"][0], other)
            self.assertTrue(hooks.is_ours(data["hooks"]["Stop"][1]))
            self.assertEqual(data["hooks"]["PreCompact"], [other])
            self.assertEqual(hooks.edit(path, None), "updated")
            self.assertEqual(path.read_text(), original)


class SleepingDeviceTest(unittest.IsolatedAsyncioTestCase):
    # The app is built inside the running loop: before Python 3.10 its asyncio
    # primitives belong to the loop that is current when they are created.
    ASLEEP = {"status": {"current": "休眠中"}}
    AWAKE = {"status": {"current": "电源活跃"}}

    async def check(self, app, status):
        with mock.patch.object(dot_api, "get_status", return_value=status), \
                mock.patch.object(config, "ready", return_value=True):
            await app.check_screen()

    def test_push_reply_says_whether_the_frame_is_on_screen(self):
        self.assertTrue(dot_api.delivered("设备 D0 图片 API 内容已切换。"))
        self.assertFalse(dot_api.delivered("设备 D0 当前休眠或离线，文本 API 内容已更新，将在下次内容切换时显示。"))
        self.assertTrue(dot_api.asleep(self.ASLEEP))
        self.assertFalse(dot_api.asleep(self.AWAKE))
        self.assertFalse(dot_api.asleep({}))

    async def test_missed_frame_is_sent_again_once_the_device_wakes(self):
        app = App({**config.load(), "keep_on_screen": False})
        app.last_sig, app.last_push = "sig", {"at": 1, "ok": True, "delivered": False}
        await self.check(app, self.ASLEEP)
        self.assertEqual(app.last_sig, "sig")
        await self.check(app, self.AWAKE)
        self.assertEqual(app.last_sig, "")

    async def test_board_is_put_back_when_other_content_is_on_screen(self):
        app = App({**config.load(), "keep_on_screen": True})
        app.last_sig, app.last_push = "sig", {"at": 1, "ok": True, "delivered": True}
        await self.check(app, {"renderInfo": {"current": {"image": ["https://cdn/mindreset.image_api/a.png"]}}})
        self.assertEqual(app.last_sig, "sig")
        await self.check(app, {"renderInfo": {"current": {"image": ["https://cdn/mindreset.text_api/a.png"]}}})
        self.assertEqual(app.last_sig, "")


class ConsoleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.loop = asyncio.new_event_loop()
        ready = threading.Event()

        def run():
            asyncio.set_event_loop(cls.loop)
            cls.app = App(config.load(), dry_run=True)
            cls.app.loop = cls.loop
            ready.set()
            cls.loop.run_forever()

        threading.Thread(target=run, daemon=True).start()
        ready.wait(5)
        cls.server = web.start(cls.app, 0)
        cls.port = cls.server.port
        cls.origin = f"http://127.0.0.1:{cls.port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.loop.call_soon_threadsafe(cls.loop.stop)

    def request(self, method, path, body=None, token=True, **headers):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        if token:
            headers.setdefault("X-Board-Token", self.server.token)
        if body is not None:
            headers.setdefault("Origin", self.origin)
            headers["Content-Type"] = "application/json"
            body = json.dumps(body)
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        data = response.read()
        conn.close()
        return response.status, response.getheader("Content-Type"), data

    def test_page_carries_the_token_and_never_the_key(self):
        status, _, page = self.request("GET", "/", token=False)
        self.assertEqual(status, 200)
        self.assertIn(self.server.token.encode(), page)
        for path in ("/api/settings", "/api/about", "/api/overview"):
            self.assertNotIn(b"dot_app", self.request("GET", path)[2])

    def test_api_needs_token_host_and_origin(self):
        self.assertEqual(self.request("GET", "/api/overview", token=False)[0], 403)
        self.assertEqual(self.request("GET", "/api/overview")[0], 200)
        self.assertEqual(self.request("GET", "/api/overview", Host="evil.example:80")[0], 403)
        self.assertEqual(self.request("POST", "/api/settings", {"max_rows": 3}, Origin="http://evil.example")[0], 403)
        self.assertEqual(self.request("POST", "/api/settings", {"max_rows": 3}, token=False)[0], 403)
        self.assertEqual(self.request("GET", "/static/../web.py", token=False)[0], 404)

    def test_settings_round_trip(self):
        status, _, data = self.request("POST", "/api/settings", {"max_rows": 3, "aliases": {"alpha": "甲"}})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["config"]["max_rows"], 3)
        self.assertEqual(self.app.cfg["aliases"], {"alpha": "甲"})
        status, _, data = self.request("POST", "/api/settings", {"max_rows": 99})
        self.assertEqual(status, 400)
        self.assertIn("1 到 4", json.loads(data)["error"])
        self.assertEqual(self.app.cfg["max_rows"], 3)

    def test_preview_renders_without_saving(self):
        before = dict(self.app.cfg)
        status, content_type, png = self.request("POST", "/api/preview", {"sample": "wait", "config": {"show_detail": True}})
        self.assertEqual((status, content_type, png[:4]), (200, "image/png", b"\x89PNG"))
        self.assertEqual(self.app.cfg, before)
        self.assertEqual(self.request("POST", "/api/preview", {"sample": "nope"})[0], 400)

    def test_battery_wake_interval_is_checked_and_sent_alone(self):
        sent = []
        with mock.patch.object(dot_api, "update_settings", side_effect=lambda cfg, body: sent.append(body)), \
                mock.patch.object(web, "device", return_value={"ok": True}):
            self.assertEqual(self.request("POST", "/api/device", {"battery_minutes": 30})[0], 200)
            for bad in (0, 721, 2.5, "30", True):
                self.assertEqual(self.request("POST", "/api/device", {"battery_minutes": bad})[0], 400)
        self.assertEqual(sent, [{"interval": {"batteryMs": 1_800_000}}])

    def test_keeping_the_board_up_sets_the_device_and_the_daemon_together(self):
        sent = []
        on_device = {"interval": {"powerMs": 300_000}}

        def update(cfg, body):
            sent.append(body)
            on_device["interval"].update(body.get("interval", {}))

        with mock.patch.object(dot_api, "update_settings", side_effect=update), \
                mock.patch.object(dot_api, "get_settings", side_effect=lambda cfg: json.loads(json.dumps(on_device))), \
                mock.patch.object(web, "device", return_value={"ok": True}):
            self.assertEqual(self.request("POST", "/api/device", {"keep": True})[0], 200)
            self.assertTrue(self.app.cfg["keep_on_screen"])
            self.assertEqual(self.request("POST", "/api/device", {"keep": True})[0], 200)  # already held: nothing to send
            self.assertEqual(self.request("POST", "/api/device", {"keep": False})[0], 200)
            self.assertFalse(self.app.cfg["keep_on_screen"])
            self.assertEqual(self.request("POST", "/api/device", {"keep": "yes"})[0], 400)
        self.assertEqual(sent, [{"interval": {"powerMs": 43_200_000}}, {"interval": {"powerMs": 300_000}}])

    def test_menu_bar_app_is_told_where_the_console_is(self):
        where = config.console_path()
        self.assertEqual(json.loads(where.read_text()), {"port": self.port, "token": self.server.token})
        self.assertEqual(where.stat().st_mode & 0o777, 0o600)

    def test_pausing_holds_the_screen_on_a_notice(self):
        self.assertFalse(json.loads(self.request("GET", "/api/overview")[2])["paused"])
        self.assertEqual(self.request("POST", "/api/settings", {"paused": True})[0], 200)
        try:
            self.assertTrue(json.loads(self.request("GET", "/api/overview")[2])["paused"])
            self.app.call(self.app.on_event, "claude", "UserPromptSubmit", {"session_id": "p", "cwd": "/p/paused"})
            view = self.app.call(self.app.current_view)
            self.assertEqual((view["kind"], view["line"]), ("quiet", "已暂停"))
        finally:
            self.request("POST", "/api/settings", {"paused": False})
        self.assertEqual(self.app.call(self.app.current_view)["kind"], "list")
        self.assertEqual(self.request("POST", "/api/settings", {"paused": "yes"})[0], 400)

    def test_quitting_leaves_a_farewell_on_the_screen(self):
        self.app.last_push = {"at": 1.0}
        with mock.patch.object(web, "FAREWELL_WAIT", 0.3):
            self.assertEqual(self.request("POST", "/api/farewell", {})[0], 200)
        try:
            view = self.app.call(self.app.current_view)
            self.assertEqual((view["kind"], view["line"]), ("quiet", "已退出"))
        finally:
            self.app.farewell_until = 0.0

    def test_setup_saves_a_key_and_takes_a_device(self):
        key_file = Path(_HOME.name) / "dot_api_key"
        config.save({"api_key_file": str(key_file)})  # never the real one in the user's home
        self.app.cfg = config.load()

        def undo():
            config.save({"api_key_file": config.DEFAULTS["api_key_file"], "device_id": ""})
            self.app.cfg = config.load()
            web._device_backup().unlink(missing_ok=True)
        self.addCleanup(undo)

        def devices(cfg, key=None):
            if (key or config.api_key(cfg)) != "dot_app_good":
                raise dot_api.DotError(400, "This API key is invalid. Check the key and try again.")
            return [{"id": "D0", "model": "quote_0"}, {"id": "D1", "model": "quote_0"}]

        def settings(cfg):
            return {"alias": "书桌" if cfg["device_id"] == "D0" else None, "interval": {"powerMs": 300_000}}

        def state(*request):
            status, _, raw = self.request(*request)
            self.assertNotIn(b"dot_app_good", raw)  # the key goes in and never comes back
            return status, json.loads(raw)

        with mock.patch.object(dot_api, "devices", side_effect=devices), \
                mock.patch.object(dot_api, "get_settings", side_effect=settings), \
                mock.patch.object(dot_api, "update_settings") as update, \
                mock.patch.object(web, "device", return_value={"ok": True}):
            self.assertEqual(state("GET", "/api/setup")[1], {
                "ready": False, "key": {"present": False, "looks_valid": False}, "device_id": "", "devices": []})
            with mock.patch.object(self.app, "dry_run", False):
                self.assertTrue(json.loads(self.request("GET", "/api/overview")[2])["needs_setup"])
            for bad in ("nope", "dot_app_bad", "dot_app with spaces", 7):
                self.assertEqual(state("POST", "/api/setup", {"key": bad})[0], 400, bad)
            self.assertFalse(key_file.exists())

            status, found = state("POST", "/api/setup", {"key": " dot_app_good\n"})
            self.assertEqual((status, found["ready"], found["key"]["looks_valid"]), (200, False, True))
            self.assertEqual(found["devices"], [{"id": "D0", "model": "quote_0", "alias": "书桌"},
                                                {"id": "D1", "model": "quote_0", "alias": ""}])
            self.assertEqual((key_file.read_text(), key_file.stat().st_mode & 0o777), ("dot_app_good\n", 0o600))

            self.assertEqual(state("POST", "/api/setup", {"device_id": "D9"})[0], 400)
            status, found = state("POST", "/api/setup", {"device_id": "D1"})
            self.assertEqual((status, found["ready"], found["device_id"]), (200, True, "D1"))
            self.assertEqual((self.app.cfg["device_id"], config.load()["device_id"]), ("D1", "D1"))
            update.assert_called_once_with(mock.ANY, {"interval": {"powerMs": 43_200_000}})  # the board is kept up
            with mock.patch.object(self.app, "dry_run", False):
                self.assertFalse(json.loads(self.request("GET", "/api/overview")[2])["needs_setup"])
        self.assertEqual(self.request("POST", "/api/setup", {})[0], 400)

    def test_overview_lists_sessions(self):
        self.app.call(self.app.on_event, "claude", "UserPromptSubmit", {"session_id": "s", "cwd": "/p/alpha"})
        data = json.loads(self.request("GET", "/api/overview")[2])
        self.assertEqual([(s["project"], s["state"]) for s in data["sessions"]], [("alpha", "running")])
        self.app.call(self.app.on_event, "claude", "SessionEnd", {"session_id": "s", "cwd": "/p/alpha"})


if __name__ == "__main__":
    unittest.main()
