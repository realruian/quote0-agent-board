import CoreText
import XCTest
@testable import BoardCore

final class ViewTests: BoardTestCase {
    private func settings(_ change: (inout Settings) -> Void) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    func testViewsAndFrameSize() {
        let b = Board()
        XCTAssertEqual(buildView(b, now: 0).kind, .idle)
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        XCTAssertEqual(buildView(b, now: 1).kind, .list)
        b.apply("claude", "PermissionRequest", alpha.with(["tool_name": "Bash"]), now: 2)
        let view = buildView(b, now: 2)
        XCTAssertEqual([view.kind.rawValue, view.title, view.task, view.agent, view.detail], ["wait", "等你批准", "alpha", "Claude", ""])
        XCTAssertEqual(buildView(b, now: 2, settings: settings { $0.showDetail = true }).detail, "Bash")
        let frame = render(view)
        XCTAssertEqual(frame.pixels.count, frameWidth * frameHeight)
        XCTAssertTrue(frame.pixels.allSatisfy { $0 == 0 || $0 == 255 })  // the panel has no greys
        XCTAssertGreaterThan(frame.pixels.filter { $0 == 0 }.count, frame.pixels.count / 2)  // waiting takes the screen over in black
        XCTAssertEqual(Array(frame.png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testRowsShowTheTaskAndKeepItAcrossShortFollowUps() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha.with(["prompt": "修复订单导出的时区问题"]), now: 1)
        let row = buildView(b, now: 2).rows[0]
        XCTAssertEqual([row.title, row.agent, row.state.rawValue], ["修复订单导出的时区问题", "Claude", "running"])
        b.apply("claude", "UserPromptSubmit", alpha.with(["prompt": "继续"]), now: 3)
        XCTAssertEqual(buildView(b, now: 4).rows[0].title, "修复订单导出的时区问题")
        XCTAssertEqual(buildView(b, now: 4, settings: settings { $0.showTitles = false }).rows[0].title, "alpha")
        b.apply("claude", "PermissionRequest", alpha.with(["tool_name": "Bash"]), now: 5)
        let wait = buildView(b, now: 6, settings: settings { $0.showDetail = true })
        XCTAssertEqual([wait.task, wait.agent, wait.detail], ["修复订单导出的时区问题", "Claude", "Bash"])
        b.apply("claude", "Stop", alpha, now: 7)
        b.apply("claude", "SessionEnd", alpha, now: 8)
        XCTAssertTrue(buildView(b, now: 9).last.contains("修复订单导出的时区问题"))
    }

    func testNameBeatsThePromptWhichBeatsTheProject() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha.with(["prompt": "修复订单导出的时区问题"]), now: 1)
        b.sessions["claude:a"]?.name = "订单导出"
        XCTAssertEqual(buildView(b, now: 2).rows[0].title, "订单导出")
    }

    func testDisplayOptions() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("codex", "UserPromptSubmit", beta, now: 2)
        XCTAssertEqual(buildView(b, now: 3, settings: settings { $0.aliases = ["alpha": "甲"] }).rows[1].title, "甲")
        XCTAssertEqual(buildView(b, now: 3, settings: settings { $0.hiddenProjects = ["beta"] }).rows.map(\.title), ["alpha"])
        XCTAssertEqual(buildView(b, now: 3, settings: settings { $0.maxRows = 1 }).rows.count, 1)
    }

    func testTakeoverCanBeTurnedOffPerKind() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "PermissionRequest", alpha.with(["tool_name": "Bash"]), now: 2)
        let view = buildView(b, now: 3, settings: settings { $0.takeover["permission"] = false })
        XCTAssertEqual([view.kind.rawValue, view.summary, view.rows[0].when], ["list", "1 等你", "等你"])
        // a hidden project never takes the screen over
        XCTAssertEqual(buildView(b, now: 3, settings: settings { $0.hiddenProjects = ["alpha"] }).kind, .idle)
    }

    func testIdleRespectsPrivacyOptions() {
        let b = Board(doneTTL: 10)
        b.apply("claude", "UserPromptSubmit", alpha, now: 1)
        b.apply("claude", "Stop", alpha, now: 2)
        XCTAssertTrue(buildView(b, now: 100).last.contains("alpha"))
        XCTAssertEqual(buildView(b, now: 100, settings: settings { $0.idleShowLast = false }).last, "")
        XCTAssertEqual(buildView(b, now: 100, settings: settings { $0.hiddenProjects = ["alpha"] }).last, "")
    }

    func testEveryFontChoiceRendersAndChangesTheFrameIdentity() {
        XCTAssertEqual(Set(Settings.fontChoices), Set(Fonts.families.map(\.key)))
        let views = Settings.fontChoices.map { font in buildView(sampleBoard("list"), now: 5, settings: settings { $0.font = font }) }
        XCTAssertEqual(Set(views.map(\.signature)).count, views.count)
        var missing = views[0]
        missing.font = "not-installed"
        for view in views + [missing] { XCTAssertEqual(render(view).pixels.count, frameWidth * frameHeight) }
        // the pixel font and a smooth font do not draw the same dots
        XCTAssertNotEqual(render(views[0]), render(views[3]))
    }

    func testLongNamesStayOnOneLineWithAnEllipsis() {
        XCTAssertEqual(fitted("更新接口文档", family: "pingfang", size: 16, bold: true, width: 160), "更新接口文档")
        let cut = fitted("一个特别特别特别长的对话名称放不下", family: "pingfang", size: 16, bold: true, width: 160)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(textWidth(cut, family: "pingfang", size: 16, bold: true), 160)
    }

    func testPixelFontIsNeverMuchSmallerThanTheOtherFonts() {
        let sizes = [12, 16, 20, 36].map { Int(CTFontGetSize(Fonts.load("arkpixel", size: $0, bold: true))) }
        XCTAssertEqual(sizes, [12, 16, 24, 36])  // a sharp multiple when one is near
    }

    func testCharactersAFontLacksComeFromASubstitute() {
        // the pixel font has no 鉴: it takes the width of a substitute's glyph instead of an empty box's
        let whole = textWidth("鉴权说明", family: "arkpixel", size: 12, bold: false)
        XCTAssertEqual(whole, textWidth("权说明", family: "arkpixel", size: 12, bold: false) + 12)
        let cut = fitted(String(repeating: "鉴权说明", count: 8), family: "arkpixel", size: 16, bold: true, width: 160)
        XCTAssertLessThanOrEqual(textWidth(cut, family: "arkpixel", size: 16, bold: true), 160)
    }

    func testSamplesAndSpecialFramesRender() {
        for kind in ["list", "wait", "idle"] { XCTAssertEqual(buildView(sampleBoard(kind)).kind.rawValue, kind) }
        var test = FrameView(kind: .test, font: "pingfang")
        test.note = "x"
        for view in [test, .notice("夜间免打扰", "07:00 恢复", font: "pingfang")] {
            XCTAssertTrue(render(view).pixels.contains(0))
        }
    }

    func testRunningTimeRefreshesAtFiveMinutesThenOnASharedBeat() {
        let b = Board()
        b.apply("claude", "UserPromptSubmit", alpha, now: 1000)
        func at(_ seconds: Double) -> FrameView { buildView(b, now: 1000 + seconds) }
        XCTAssertEqual([5, 70, 27 * 60, 3 * 3600 + 5].map { at($0).rows[0].when }, ["<5m", "<5m", "27m", "3h"])
        // tool activity alone never asks for a refresh
        b.apply("claude", "PostToolUse", alpha.with(["tool_name": "Read"]), now: 1010)
        XCTAssertEqual(at(5).signature, at(50).signature)
        XCTAssertEqual(at(50).signature, at(290).signature)  // still "<5m": no refresh
        XCTAssertNotEqual(at(290).signature, at(310).signature)  // five minutes in
        XCTAssertEqual(at(400).signature, at(450).signature)  // inside one five-minute beat
        XCTAssertNotEqual(at(400).signature, at(1000).signature)  // a later beat
        // a finished task shows how long it took, and that never changes
        b.apply("claude", "Stop", alpha, now: 1000 + 12 * 60)
        XCTAssertEqual(at(12 * 60 + 5).rows[0].when, "12m")
        XCTAssertEqual(at(12 * 60 + 5).signature, at(25 * 60).signature)
    }

    func testOverflowRows() {
        let b = Board()
        for i in 0..<6 { b.apply("claude", "UserPromptSubmit", ["session_id": .string("\(i)"), "cwd": .string("/p/\(i)")], now: Double(i)) }
        XCTAssertEqual(buildView(b, now: 10).rows.map(\.title), ["5", "4", "3", "2"])  // every line goes to a conversation
        let listed = buildView(b, now: 10).named
        XCTAssertEqual(b.visible(10).filter { !listed.contains($0.key) }.map(\.project), ["1", "0"])  // the menu lists the rest
        b.apply("claude", "PermissionRequest", ["session_id": "3", "cwd": "/p/3", "tool_name": "Bash"], now: 11)
        XCTAssertEqual(buildView(b, now: 12).named, b.visible(12).filter { $0.state == .waiting }.map(\.key))  // taken over: only the one waiting
    }

    // -- quota on the frame --

    func testHeaderCarriesQuotaWhileWorking() {
        let view = buildView(sampleBoard("list", now: 1_791_425_520), now: 1_791_425_520, usage: sampleUsage)
        XCTAssertEqual(view.quota?.map { "\($0.agent) " + $0.rows.map { "\($0.short)=\($0.left)" }.joined(separator: ",") },
                       ["Claude 5h=36,7d=73", "Codex 7d=95"])
        XCTAssertTrue(render(view).pixels.contains(0))
    }

    func testIdleListsWindowsAndSaysWhenThereIsNothing() {
        let now = 1_791_425_520.0
        let live: Usage = ["claude": AgentUsage(), "codex": AgentUsage(windows: [sevenDay: QuotaLeft(left: 95, resetsAt: now + 3600)])]
        let view = buildView(Board(), now: now, usage: live)
        XCTAssertEqual(view.quota?[0].rows, [])
        XCTAssertEqual(view.quota?[1].rows, [QuotaRow(window: "本周", short: "7d", left: 95, reset: hhmm(now + 3600))])
        XCTAssertTrue(render(view).pixels.contains(0))
    }

    func testTurnedOffOrUnreadLeavesTheFrameAsBefore() {
        XCTAssertNil(buildView(Board(), now: 5, settings: settings { $0.showUsage = false }, usage: sampleUsage).quota)
        XCTAssertNil(buildView(Board(), now: 5).quota)
    }

    func testSmallChangesDoNotAskForARefresh() {
        func withLeft(_ n: Int) -> FrameView {
            buildView(Board(), now: 5, usage: ["claude": AgentUsage(), "codex": AgentUsage(windows: [sevenDay: QuotaLeft(left: n, resetsAt: 0)])])
        }
        XCTAssertEqual(withLeft(95).signature, withLeft(96).signature)
        XCTAssertNotEqual(withLeft(95).signature, withLeft(88).signature)
        XCTAssertNotEqual(withLeft(95), withLeft(96))
    }
}
