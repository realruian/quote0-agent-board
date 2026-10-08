import XCTest
@testable import BoardCore

final class StateTests: BoardTestCase {
    func testTurnLifecycle() {
        let b = Board()
        XCTAssertFalse(b.apply("claude", "SessionStart", alpha, now: 0))
        XCTAssertEqual(states(b, 0), [])
        XCTAssertTrue(b.apply("claude", "UserPromptSubmit", alpha, now: 1))
        XCTAssertFalse(b.apply("claude", "PreToolUse", alpha.with(["tool_name": "Read"]), now: 2))
        XCTAssertFalse(b.apply("claude", "PostToolUse", alpha.with(["tool_name": "Read"]), now: 3))
        XCTAssertEqual(states(b, 3), ["alpha running"])
        XCTAssertTrue(b.apply("claude", "Stop", alpha, now: 4))
        XCTAssertEqual(states(b, 4), ["alpha done"])
        XCTAssertTrue(b.apply("claude", "SessionEnd", alpha, now: 5))
        XCTAssertEqual(states(b, 5), [])
    }

    func testPermissionWaitResolvesOnToolResult() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "PreToolUse", alpha.with(["tool_name": "Bash"]), now: 2)
        XCTAssertTrue(b.apply("claude", "PermissionRequest", alpha.with(["tool_name": "Bash"]), now: 3))
        let s = b.visible(3)[0]
        XCTAssertEqual([s.state.rawValue, s.waitKind, s.detail], ["waiting", "permission", "Bash"])
        XCTAssertEqual(s.waitingSince, 3)
        XCTAssertTrue(b.apply("claude", "PostToolUse", alpha.with(["tool_name": "Bash"]), now: 9))
        XCTAssertEqual(states(b, 9), ["alpha running"])
    }

    func testQuestionAndPlanToolsWait() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "PreToolUse", alpha.with(["tool_name": "AskUserQuestion"]), now: 2)
        XCTAssertEqual(b.visible(2)[0].waitKind, "question")
        b.apply("claude", "PostToolUse", alpha.with(["tool_name": "AskUserQuestion"]), now: 3)
        b.apply("claude", "PreToolUse", alpha.with(["tool_name": "ExitPlanMode"]), now: 4)
        XCTAssertEqual(b.visible(4)[0].waitKind, "plan")
        b.apply("claude", "Notification", beta.with(["notification_type": "elicitation_dialog"]), now: 5)
        XCTAssertEqual(b.sessions["claude:b"]?.waitKind, "question")
    }

    func testWaitingSortsFirstAndErrorShows() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("codex", "UserPromptSubmit", beta, now: 2)
        b.apply("codex", "StopFailure", beta, now: 3)
        b.apply("claude", "PermissionRequest", alpha.with(["tool_name": "Edit"]), now: 4)
        XCTAssertEqual(states(b, 4), ["alpha waiting", "beta error"])
    }

    func testToolCallsDoNotReorderRunningSessions() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "UserPromptSubmit", beta, now: 2)
        XCTAssertEqual(states(b, 2), ["beta running", "alpha running"])
        // the older turn working does not move it up: that would redraw the screen for every tool call
        XCTAssertFalse(b.apply("claude", "PreToolUse", alpha.with(["tool_name": "Read"]), now: 3))
        XCTAssertFalse(b.apply("claude", "PostToolUse", alpha.with(["tool_name": "Read"]), now: 4))
        XCTAssertEqual(states(b, 4), ["beta running", "alpha running"])
    }

    func testBackgroundSubagentDoesNotReviveFinishedSession() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "Stop", alpha, now: 2)
        let sub = alpha.with(["agent_id": "x", "tool_name": "Read"])
        XCTAssertFalse(b.apply("claude", "PreToolUse", sub, now: 3))
        XCTAssertFalse(b.apply("claude", "PostToolUse", sub, now: 4))
        // ...but it can still need the user, and goes back to done afterwards.
        XCTAssertTrue(b.apply("claude", "PermissionRequest", sub.with(["tool_name": "Bash"]), now: 5))
        XCTAssertTrue(b.apply("claude", "PostToolUse", sub.with(["tool_name": "Bash"]), now: 6))
        XCTAssertEqual(states(b, 6), ["alpha done"])
    }

    func testAgeing() {
        let b = Board(doneTTL: 100, staleRunning: 500)
        b.apply("claude", "UserPromptSubmit", alpha, now: 0)
        b.apply("claude", "Stop", alpha, now: 10)
        b.apply("codex", "UserPromptSubmit", beta, now: 10)
        XCTAssertEqual(b.visible(50).count, 2)
        XCTAssertEqual(states(b, 200), ["beta running"])
        b.prune(600)
        XCTAssertTrue(b.sessions.isEmpty)
        XCTAssertEqual(b.lastFinished?.project, "alpha")
    }

    func testPersistenceRoundTripInTheFormatThePythonVersionWrote() throws {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "PermissionRequest", alpha.with(["tool_name": "Bash"]), now: 2)
        let data = try JSONEncoder().encode(b.saved)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"waiting_since\":2"))
        let c = Board()
        c.load(try JSONDecoder().decode(Board.Saved.self, from: data))
        XCTAssertEqual(states(c, 2), states(b, 2))
        XCTAssertEqual(c.sessions["claude:a"]?.waitingSince, 2)
        let python = #"{"sessions": [{"key": "codex:s", "source": "codex", "project": "p", "name": "", "title": "t", "transcript": "", "state": "running", "wait_kind": "", "detail": "", "resume_state": "", "waiting_since": 0.0, "started_at": 5.0, "updated_at": 5.0, "finished_at": 0.0}], "last_finished": null}"#
        c.load(try JSONDecoder().decode(Board.Saved.self, from: Data(python.utf8)))
        XCTAssertEqual(states(c, 6), ["p running"])
    }

    func testProjectName() {
        XCTAssertEqual(projectName("/Users/me/Dev/alpha/"), "alpha")
        XCTAssertEqual(projectName("/Users/me/Dev/alpha/.claude/worktrees/fix-1"), "alpha")
        XCTAssertEqual(projectName("/x/scratch-2026-10-08-c1b5d9"), "临时会话")
        XCTAssertEqual(projectName(""), "未知项目")
    }

    func testTaskTitleCleansThePrompt() {
        XCTAssertEqual(taskTitle("  帮我把首页改成响应式\n第二行不要 "), "帮我把首页改成响应式")
        XCTAssertEqual(taskTitle("<system-reminder>别管我\n多行</system-reminder>\n修复订单导出的时区问题"), "修复订单导出的时区问题")
        XCTAssertEqual(taskTitle(String(repeating: "长", count: 200)).count, 60)
        let codex = "# Files mentioned by the user:\n\n## shot.png: /tmp/shot.png\n\n## My request for Codex:\n按这张截图调整首页的间距\n"
        XCTAssertEqual(taskTitle(codex), "按这张截图调整首页的间距")
        XCTAssertEqual(taskTitle("# 标题行\n真正要做的事情写在这里"), "真正要做的事情写在这里")
        for tooLittle in ["继续", "ok", "/compact 然后继续干活", "", nil] { XCTAssertEqual(taskTitle(tooLittle), "") }
    }
}

final class PayloadTests: XCTestCase {
    func testCompleteJSON() {
        XCTAssertEqual(parsePayload(Data(#"{"session_id":"a","cwd":"/x"}"#.utf8)), ["session_id": "a", "cwd": "/x"])
    }

    func testTruncatedJSONKeepsLeadingFields() {
        let raw = #"{"session_id":"a","cwd":"/Users/me/Dev/文档","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"content":"\"session_id\":\"fake\" and then it is cut of"#
        XCTAssertEqual(parsePayload(Data(raw.utf8)), ["session_id": "a", "cwd": "/Users/me/Dev/文档", "tool_name": "Write"])
    }

    func testCutOffPromptKeepsItsBeginning() {
        let raw = #"{"session_id":"a","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"修复订单导出\n的时区问题，然后\"#
        XCTAssertEqual(parsePayload(Data(raw.utf8)), ["session_id": "a", "cwd": "/x", "prompt": "修复订单导出\n的时区问题，然后"])
    }

    func testGarbage() {
        XCTAssertEqual(parsePayload(Data()), .object(JSONObject()))
        XCTAssertEqual(parsePayload(Data("[1,2]".utf8)), .object(JSONObject()))
    }
}

final class JSONTests: XCTestCase {
    func testKeepsKeyOrderAndNumbersAsWritten() throws {
        let text = "{\n  \"zebra\": 1,\n  \"alpha\": [\n    1.50,\n    true,\n    null\n  ],\n  \"empty\": {},\n  \"none\": [],\n  \"路径\": \"a/b\\n\\\"c\\\"\"\n}"
        let value = try JSON(parsing: text)
        XCTAssertEqual(value.object?.keys, ["zebra", "alpha", "empty", "none", "路径"])
        XCTAssertEqual(value.pretty(), text)
        XCTAssertEqual(value["alpha"]?.array?[0].int, nil)
        XCTAssertEqual(value["zebra"]?.int, 1)
        XCTAssertNil(value["alpha"]?.array?[1].int)  // true is not 1
    }

    func testEscapesAndPairs() throws {
        XCTAssertEqual(try JSON(parsing: #""😀 é \/""#).string, "😀 é /")
        XCTAssertEqual(JSON.string("tab\tbell\u{07}").compact, #""tab\tbell\u0007""#)
        XCTAssertThrowsError(try JSON(parsing: "{\"a\": 1,}"))
        XCTAssertThrowsError(try JSON(parsing: "[1] trailing"))
    }
}
