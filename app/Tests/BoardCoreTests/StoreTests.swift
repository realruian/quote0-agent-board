import XCTest
@testable import BoardCore

final class ConfigTests: BoardTestCase {
    func testAcceptsAndCleans() throws {
        let clean = try ConfigStore.validate(["max_rows": 2, "aliases": [" alpha ": " 甲 ", "beta": ""], "hidden_projects": ["b", "a", "a"]])
        XCTAssertEqual(JSON.object(clean), ["max_rows": 2, "aliases": ["alpha": "甲"], "hidden_projects": ["a", "b"]])
    }

    func testRejectsBadValues() {
        let bad: [JSON] = [["max_rows": 9], ["max_rows": true], ["max_rows": .number("2.5")], ["device_id": "x"], ["show_detail": 1],
                           ["quiet_hours": ["start": "25:00"]], ["quiet_hours": ["start": "07:00", "end": "07:00"]],
                           ["takeover": ["nope": true]], ["aliases": []], ["font": "comic"], ["paused": "yes"], "not an object"]
        for patch in bad {
            XCTAssertThrowsError(try ConfigStore.validate(patch), patch.compact) { XCTAssertTrue($0 is ConfigError) }
        }
    }

    func testPartialNestedPatchKeepsTheRest() throws {
        try ConfigStore.save(try ConfigStore.validate(["takeover": ["permission": false]]))
        try ConfigStore.save(try ConfigStore.validate(["takeover": ["plan": false]]))
        XCTAssertEqual(ConfigStore.load().takeover, ["permission": false, "question": true, "plan": false])
        try ConfigStore.save(try ConfigStore.validate(["quiet_hours": ["enabled": true]]))
        XCTAssertEqual(ConfigStore.load().quietHours, QuietHours(enabled: true, start: "23:00", end: "07:00"))
    }

    func testReadsTheFileThePythonVersionWroteAndKeepsWhatItDoesNotKnow() throws {
        _ = write("{\n  \"device_id\": \"D0\",\n  \"future_option\": [1, 2],\n  \"max_rows\": 3,\n  \"font\": 7\n}\n", "config.json")
        let settings = ConfigStore.load()
        XCTAssertEqual([settings.deviceID, String(settings.maxRows), settings.font], ["D0", "3", "pingfang"])  // a wrong type falls back
        try ConfigStore.save(["paused": true])
        let text = try String(contentsOf: Paths.config, encoding: .utf8)
        XCTAssertTrue(text.contains("\"future_option\": [\n    1,\n    2\n  ]"))
        XCTAssertTrue(ConfigStore.load().paused)
    }

    func testQuietHoursWindowMayCrossMidnight() {
        func at(_ clock: String) -> Double {
            let parts = clock.split(separator: ":").map { Int($0)! }
            return Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: parts[0], minute: parts[1]))!.timeIntervalSince1970
        }
        var night = Settings()
        night.quietHours = QuietHours(enabled: true, start: "23:00", end: "07:00")
        XCTAssertTrue(Engine.inQuietHours(night, now: at("23:30")))
        XCTAssertTrue(Engine.inQuietHours(night, now: at("06:59")))
        XCTAssertFalse(Engine.inQuietHours(night, now: at("07:00")))
        XCTAssertFalse(Engine.inQuietHours(night, now: at("12:00")))
        var noon = Settings()
        noon.quietHours = QuietHours(enabled: true, start: "12:00", end: "14:00")
        XCTAssertTrue(Engine.inQuietHours(noon, now: at("13:00")))
        XCTAssertFalse(Engine.inQuietHours(noon, now: at("14:00")))
        night.quietHours.enabled = false
        XCTAssertFalse(Engine.inQuietHours(night, now: at("23:30")))
    }
}

final class HooksTests: BoardTestCase {
    private let other = #"{"hooks": [{"type": "command", "command": "'/x/.vibe-island/bin/vibe-island-bridge' --source claude"}]}"#

    func testAddIsAdditiveAndRemoveRestoresTheFile() throws {
        // the way Python's json.dumps(indent=2) writes it, which is how these files usually look
        let original = "{\n  \"model\": \"x\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"'/x/.vibe-island/bin/vibe-island-bridge' --source claude\"\n          }\n        ]\n      }\n    ],\n    \"PreCompact\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"'/x/.vibe-island/bin/vibe-island-bridge' --source claude\"\n          }\n        ]\n      }\n    ]\n  }\n}"
        let theirs = try JSON(parsing: other)
        for agent in Hooks.agents {
            let path = write(original, "\(agent).json")
            XCTAssertEqual(try Hooks.edit(path, add: Hooks.groups(for: agent)), "updated")
            XCTAssertEqual(try Hooks.edit(path, add: Hooks.groups(for: agent)), "already up to date")
            let data = try JSON(parsing: Data(contentsOf: path))
            XCTAssertEqual(data.object?.keys, ["model", "hooks"])
            XCTAssertEqual(data["hooks"]?["Stop"]?.array?[0], theirs)
            XCTAssertTrue(Hooks.isOurs(data["hooks"]!["Stop"]!.array![1]))
            XCTAssertEqual(data["hooks"]?["PreCompact"], .array([theirs]))
            XCTAssertEqual(try Hooks.edit(path, add: nil), "updated")
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: Paths.backups.path).filter { $0.contains("\(agent).json") }.count >= 1, true)
        }
    }

    func testKeepsTheStyleOfAFileASwiftToolWrote() throws {
        let original = "{\n  \"hooks\" : {\n    \"Stop\" : [\n      {\n        \"hooks\" : [\n          {\n            \"command\" : \"\\/x\\/other\",\n            \"type\" : \"command\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        let path = write(original, "codex.json")
        XCTAssertEqual(try Hooks.edit(path, add: Hooks.groups(for: "codex")), "updated")
        let edited = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(edited.contains("\"_agent_board\" : true") && edited.contains("\\/bin\\/agent-board-hook") && edited.hasSuffix("}\n"))
        XCTAssertEqual(try Hooks.edit(path, add: nil), "updated")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
    }

    func testStatusCountsOursAndLeavesAMissingFileAlone() throws {
        let path = write("{\"hooks\": {\"Stop\": [\(other)]}}", "claude.json")
        Hooks.files = ["claude": path, "codex": home.appendingPathComponent("missing.json")]
        XCTAssertEqual([Hooks.status("claude").installed, Hooks.status("claude").expected, Hooks.status("claude").vibeIsland], [0, 9, 1])
        XCTAssertEqual(try Hooks.setEnabled("claude", true), "updated")
        XCTAssertEqual(Hooks.status("claude").installed, 9)
        XCTAssertEqual(try Hooks.setEnabled("codex", true), "not found, skipped")
        XCTAssertFalse(Hooks.status("codex").exists)
        // the commands are the ones the Python version installed, so its hooks count as already there
        let stop = try JSON(parsing: Data(contentsOf: path))["hooks"]!["Stop"]!.array![1]
        XCTAssertEqual(stop["hooks"]?.array?[0]["command"]?.string,
                       "/bin/sh -c '[ -x \"$HOME/.quote0-agent-board/bin/agent-board-hook\" ] && \"$HOME/.quote0-agent-board/bin/agent-board-hook\" claude Stop; exit 0'")
    }
}

final class ReviewerTests: BoardTestCase {
    private func turn(_ reviewer: String) -> String {
        #"{"type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"\#(reviewer)","model":"m"}}"#
    }

    func testTheLatestTurnSaysWhoAnswers() {
        // What a tool printed has its quotes escaped, and is not the record's own field.
        let output = #"{"type":"response_item","payload":{"output":"{\"approvals_reviewer\":\"user\"}"}}"#
        let padding = String(repeating: "x", count: 3 << 20)  // the turn's record is several chunks back
        let auto = write([turn("user"), turn("auto_review"), output, padding].joined(separator: "\n") + "\n", "auto.jsonl").path
        XCTAssertTrue(Reviewer.codexReviewsItself(transcript: auto))
        let user = write([turn("auto_review"), turn("user"), padding].joined(separator: "\n") + "\n", "user.jsonl").path
        XCTAssertFalse(Reviewer.codexReviewsItself(transcript: user))
        XCTAssertFalse(Reviewer.codexReviewsItself(transcript: write("{}\n", "plain.jsonl").path))
        XCTAssertFalse(Reviewer.codexReviewsItself(transcript: home.appendingPathComponent("missing.jsonl").path))
    }

    func testARequestCodexReviewsItselfDoesNotWaitForTheUser() {
        let engine = Engine(dryRun: true)
        let path = write(turn("auto_review") + "\n", "codex.jsonl").path
        let request = alpha.with(["tool_name": "shell", "transcript_path": .string(path), "turn_id": "t1"])
        engine.onEvent("codex", "UserPromptSubmit", alpha)
        engine.onEvent("codex", "PermissionRequest", request)
        XCTAssertEqual(engine.board.visible().map(\.state), [.running])
        // The same request in Claude Code, or in a Codex turn the user answers, does wait.
        engine.onEvent("claude", "PermissionRequest", request)
        _ = write(turn("user") + "\n", "codex.jsonl")
        engine.onEvent("codex", "PermissionRequest", request.with(["turn_id": "t2"]))
        XCTAssertEqual(engine.board.visible().map(\.state), [.waiting, .waiting])
    }
}

final class NamesTests: BoardTestCase {
    func testLatestTitleRecordWins() {
        let path = write([
            #"{"type": "custom-title", "customTitle": "旧名字", "sessionId": "a"}"#,
            #"{"type": "user", "message": {"content": "he said \"custom-title\" once"}}"#,
            #"{"type": "ai-title", "aiTitle": "给登录页加上\n短信验证码", "sessionId": "a"}"#,
            #"{"type": "agent-name", "agentName": "别的东西", "sessionId": "a"}"#,
            "not json but mentions \"custom-title\"",
        ].joined(separator: "\n") + "\n", "session.jsonl").path
        XCTAssertEqual(Names.claude(transcript: path), "给登录页加上 短信验证码")
        XCTAssertEqual(Names.lookup(source: "claude", sessionID: "a", transcript: path), "给登录页加上 短信验证码")
    }

    func testNoRecordOrNoFileIsEmpty() {
        XCTAssertEqual(Names.claude(transcript: write("{\"type\": \"user\"}\n", "plain.jsonl").path), "")
        XCTAssertEqual(Names.claude(transcript: home.appendingPathComponent("missing.jsonl").path), "")
        XCTAssertEqual(Names.claude(transcript: ""), "")
        XCTAssertEqual(Names.claude(transcript: "/etc/passwd"), "")
    }

    func testLastCodexEntryForTheSession() {
        Names.codexIndex = write([
            #"{"id": "s1", "thread_name": "初稿", "updated_at": "x"}"#,
            #"{"id": "s2", "thread_name": "另一个对话", "updated_at": "x"}"#,
            #"{"id": "s1", "thread_name": "把首页改成响应式布局", "updated_at": "y"}"#,
        ].joined(separator: "\n") + "\n", "session_index.jsonl").path
        XCTAssertEqual(Names.codex(sessionID: "s1"), "把首页改成响应式布局")
        XCTAssertEqual(Names.codex(sessionID: "s2"), "另一个对话")
        XCTAssertEqual(Names.codex(sessionID: "s3"), "")
        XCTAssertEqual(Names.codex(sessionID: ""), "")
        Names.codexIndex = home.appendingPathComponent("missing.jsonl").path
        XCTAssertEqual(Names.codex(sessionID: "s1"), "")
    }
}

final class UsageTests: BoardTestCase {
    private let now = 1_791_425_520.0

    private func codexLine(_ stamp: String, _ primary: String, _ secondary: String = "null") -> String {
        #"{"timestamp": "\#(stamp)", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": \#(primary), "secondary": \#(secondary)}}}"#
    }

    func testCodexTakesTheLastRecordOfTheNewestSession() throws {
        let old = write(codexLine("2026-10-08T01:00:00Z", #"{"used_percent": 50, "window_minutes": 10080, "resets_at": 5}"#) + "\n", "sessions/2026/10/08/rollout-old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: old.path)  // long before the next file
        _ = write([
            #"{"type": "session_meta", "payload": {}}"#,
            codexLine("2026-10-08T12:00:00Z", #"{"used_percent": 3, "window_minutes": 300, "resets_at": 111}"#),
            "not json",
            codexLine("2026-10-08T13:30:27.413Z", #"{"used_percent": 4.0, "window_minutes": 300, "resets_at": 222}"#,
                      #"{"used_percent": 12.5, "window_minutes": 10080, "resets_at": 333}"#),
            #"{"type": "response_item", "payload": {"type": "message"}}"#,
        ].joined(separator: "\n") + "\n", "sessions/2026/10/08/rollout-new.jsonl")
        UsageReader.codexSessions = home.appendingPathComponent("sessions")
        let reading = try XCTUnwrap(UsageReader.readCodex())
        XCTAssertEqual(reading.windows, [fiveHour: QuotaUsed(used: 4, resetsAt: 222), sevenDay: QuotaUsed(used: 12.5, resetsAt: 333)])
        XCTAssertEqual(reading.observedAt, 1_791_466_227.413, accuracy: 0.01)
        UsageReader.codexSessions = home.appendingPathComponent("nowhere")
        XCTAssertNil(UsageReader.readCodex())
    }

    func testClaudeReadsBothWindowsWithTheResetOnTheMinuteAndAsksOnlyNowAndThen() throws {
        // the shape the command line answers a usage request with
        let answer = try JSON(parsing: #"{"subscription_type": "max", "rate_limits_available": true, "rate_limits": {"five_hour": {"utilization": 77, "resets_at": "2026-10-08T16:59:59.555743+00:00", "limit_dollars": null}, "seven_day": {"utilization": 39.5, "resets_at": "2026-10-10T13:00:00.070005+00:00"}, "seven_day_opus": null}}"#)
        UsageReader.forgetClaude()
        var asked = 0
        let ask: (String) -> JSON? = { _ in asked += 1; return answer }
        let reading = try XCTUnwrap(UsageReader.readClaude(now: now, binary: "/x/claude", ask: ask))
        XCTAssertEqual(reading, QuotaReading(observedAt: now, windows: [fiveHour: QuotaUsed(used: 77, resetsAt: 1_791_478_800),
                                                                         sevenDay: QuotaUsed(used: 39.5, resetsAt: 1_791_637_200)]))
        XCTAssertEqual(UsageReader.readClaude(now: now + 30, binary: "/x/claude", ask: ask)?.observedAt, now)
        XCTAssertEqual(UsageReader.readClaude(now: now + UsageReader.claudeEvery, binary: "/x/claude", ask: ask)?.observedAt, now + UsageReader.claudeEvery)
        XCTAssertEqual(asked, 2)
        // an ask that fails leaves the earlier reading; no command line means no asking at all
        XCTAssertEqual(UsageReader.readClaude(now: now + 2 * UsageReader.claudeEvery, binary: "/x/claude", ask: { _ in nil })?.observedAt, now + UsageReader.claudeEvery)
        UsageReader.forgetClaude()
        XCTAssertNil(UsageReader.readClaude(now: now, binary: nil, ask: { _ in XCTFail("asked without a command line"); return nil }))
        UsageReader.forgetClaude()
    }

    func testTalksToTheCommandLineOverItsControlChannel() throws {
        // answers each request the way the command line does
        let fake = write("""
        #!/bin/sh
        while read line; do
          id=$(printf '%s' "$line" | sed 's/.*"request_id":"\\([a-z]*\\)".*/\\1/')
          echo '{"type":"system","subtype":"noise"}'
          if [ "$id" = usage ]; then
            echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits":{"five_hour":{"utilization":5}}}}}'
          else
            echo '{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}'
          fi
        done

        """, "claude")
        let silent = write("#!/bin/sh\nexec sleep 30\n", "silent")
        for script in [fake, silent] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path) }
        XCTAssertEqual(UsageReader.readCodex(), reading)  // kept until a later one turns up
        UsageReader.forgetCodex()
        XCTAssertEqual(UsageReader.askClaude(fake.path), ["rate_limits": ["five_hour": ["utilization": 5]]])
        XCTAssertNil(UsageReader.askClaude(silent.path, timeout: 0.3))
    }
    func testCodexLooksThroughTheLastDaysAndTheConversationsNowOpen() throws {
        func week(_ used: Int) -> String { #"{"used_percent": \#(used), "window_minutes": 10080, "resets_at": 5}"# }
        // A conversation begun long ago, and the one written to last.
        let resumed = write(codexLine("2026-10-08T15:00:00Z", week(80)) + "\n", "sessions/2025/01/02/rollout-resumed.jsonl")
        for day in 1...UsageReader.codexDays {
            let path = write(codexLine("2026-10-0\(day)T12:00:00Z", week(day)) + "\n", "sessions/2026/10/0\(day)/rollout-\(day).jsonl").path
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000 + Double(day))], ofItemAtPath: path)
        }
        _ = write("not a day folder", "sessions/2026/10/notes.txt")
        UsageReader.codexSessions = home.appendingPathComponent("sessions")
        XCTAssertEqual(UsageReader.readCodex()?.windows[sevenDay]?.used, 7)
        XCTAssertEqual(UsageReader.readCodex(also: [resumed.path])?.windows[sevenDay]?.used, 80)
        XCTAssertEqual(UsageReader.readCodex()?.windows[sevenDay]?.used, 80)  // once it is off the board, the earlier readings do not come back
    }


    func testTrustRules() {
        func reading(_ age: Double, _ resetIn: Double) -> QuotaReading {
            QuotaReading(observedAt: now - age, windows: [fiveHour: QuotaUsed(used: 64.2, resetsAt: now + resetIn)])
        }
        // Claude is shown only while recent and inside its window
        XCTAssertEqual(UsageReader.left("claude", reading(60, 3600), now), [fiveHour: QuotaLeft(left: 36, resetsAt: now + 3600)])
        XCTAssertEqual(UsageReader.left("claude", reading(3 * 3600, 3600), now), [:])
        XCTAssertEqual(UsageReader.left("claude", reading(60, -10), now), [:])
        XCTAssertEqual(UsageReader.left("claude", nil, now), [:])
        // Codex holds until reset, then is full
        XCTAssertEqual(UsageReader.left("codex", reading(3 * 86400, 3600), now)[fiveHour]?.left, 36)
        XCTAssertEqual(UsageReader.left("codex", reading(3 * 86400, -10), now), [fiveHour: QuotaLeft(left: 100, resetsAt: 0)])
    }
}
