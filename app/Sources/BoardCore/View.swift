// What a frame says, as plain data. Equal views render to equal frames, so the
// decision to refresh the screen is made here and not by comparing pictures.

import Foundation

public let fiveHour = "five_hour"
public let sevenDay = "seven_day"
let usageWindows = [fiveHour, sevenDay]

/// Quota left in one window, and when the window starts over (0 when not known).
public struct QuotaLeft: Equatable {
    public var left: Int
    public var resetsAt: Double

    public init(left: Int, resetsAt: Double) {
        self.left = left
        self.resetsAt = resetsAt
    }
}

public struct AgentUsage: Equatable {
    public var windows: [String: QuotaLeft] = [:]
    public var observedAt = 0.0

    public init(windows: [String: QuotaLeft] = [:], observedAt: Double = 0) {
        self.windows = windows
        self.observedAt = observedAt
    }
}

/// Readings per agent ("claude", "codex").
public typealias Usage = [String: AgentUsage]

public struct QuotaRow: Equatable {
    var window: String
    var short: String
    var left: Int
    var reset: String
}

public struct QuotaEntry: Equatable {
    var agent: String
    var rows: [QuotaRow]
}

public struct ViewRow: Equatable {
    public var state: SessionState
    public var agent: String
    public var title: String
    public var when: String
    var minutes: Int?  // a running task's age; with `tick`, decides when its time is worth a refresh
    var tick: Int?
}

public struct FrameView: Equatable {
    public enum Kind: String { case wait, list, idle, quiet, test }

    public var kind: Kind
    public var font: String
    // wait
    public var title = ""
    public var task = ""
    public var agent = ""
    public var detail = ""
    public var since = ""
    public var footer = ""
    // list
    public var summary = ""
    public var rows: [ViewRow] = []
    public var quota: [QuotaEntry]?
    // idle, and notices such as quiet hours
    public var line = ""
    public var last = ""
    // test
    public var note = ""

    public init(kind: Kind, font: String) {
        self.kind = kind
        self.font = font
    }

    /// A screen that only says one thing: quiet hours, paused, quit.
    public static func notice(_ line: String, _ last: String, font: String) -> FrameView {
        var view = FrameView(kind: .quiet, font: font)
        view.line = line
        view.last = last
        return view
    }

    /// Identity of a frame for deciding whether to refresh. Numbers that drift on their
    /// own count in steps, so the screen does not flash for each change: quota in
    /// five-point steps; a running time once it passes five minutes, then on a
    /// five-minute beat shared by every row.
    public var signature: String {
        func step(_ value: Int) -> Int { Int((Double(value) / 5).rounded()) * 5 }
        let rowText = rows.map { row -> String in
            let when = row.minutes.map { $0 < freshMinutes ? "fresh" : "beat \(row.tick ?? 0)" } ?? row.when
            return [row.state.rawValue, row.agent, row.title, when].joined(separator: "\u{1}")
        }
        let quotaText = quota.map { entries in
            entries.map { entry in
                entry.agent + "\u{1}" + entry.rows.map { "\($0.window) \($0.short) \(step($0.left)) \($0.reset)" }.joined(separator: "\u{1}")
            }.joined(separator: "\u{2}")
        } ?? "none"
        return [kind.rawValue, font, title, task, agent, detail, since, footer, summary, rowText.joined(separator: "\u{2}"),
                quotaText, line, last, note].joined(separator: "\u{3}")
    }
}

let agentLabel = ["claude": "Claude", "codex": "Codex"]
let waitTitle = ["permission": "等你批准", "question": "等你回答", "plan": "等你看计划"]
let maxRows = 4
let durationTick = 300.0  // seconds between refreshes that exist only to update running times
let freshMinutes = 5  // a running task is only "under five minutes" until then

func hhmm(_ timestamp: Double) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: timestamp))
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

/// How long something has taken, the short way: 27m, 3h. A running task starts out
/// as "<5m" rather than counting each minute, which would mean a screen refresh a
/// minute per task.
func duration(_ seconds: Double, running: Bool = false) -> String {
    let minutes = Int(max(0, seconds) / 60)
    if running && minutes < freshMinutes { return "<\(freshMinutes)m" }
    if minutes < 1 { return "<1m" }
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
}

/// When a quota window starts over: a clock time if within a day, else the weekday.
/// A fixed moment rather than a countdown, so it stays true between refreshes.
func resetLabel(_ resetsAt: Double, _ now: Double) -> String {
    if resetsAt == 0 || resetsAt <= now { return "" }
    if resetsAt - now < 86400 { return hhmm(resetsAt) }
    let weekday = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: resetsAt))  // Sunday is 1
    return "周" + String(Array("一二三四五六日")[(weekday + 5) % 7])
}

/// One entry per agent: percent left per window, with the labels each screen uses.
func quotaEntries(_ usage: Usage, _ now: Double) -> [QuotaEntry] {
    let label = [fiveHour: ("5 小时", "5h"), sevenDay: ("本周", "7d")]
    return ["claude", "codex"].map { agent in
        let windows = usage[agent]?.windows ?? [:]
        let rows = usageWindows.compactMap { kind -> QuotaRow? in
            guard let window = windows[kind], let (long, short) = label[kind] else { return nil }
            return QuotaRow(window: long, short: short, left: window.left, reset: resetLabel(window.resetsAt, now))
        }
        return QuotaEntry(agent: agentLabel[agent]!, rows: rows)
    }
}

/// Describe the frame for the board as it stands.
public func buildView(_ board: Board, now: Double = Date().timeIntervalSince1970, settings: Settings = Settings(),
                      usage: Usage? = nil) -> FrameView {
    let hidden = Set(settings.hiddenProjects)
    let quota = settings.showUsage ? usage.map { quotaEntries($0, now) } : nil

    func name(_ project: String) -> String { settings.aliases[project] ?? project }

    /// What a session is called on screen: the conversation's name, else its project.
    func headline(_ s: Session) -> String {
        let own = settings.showTitles ? (s.name.isEmpty ? s.title : s.name) : ""
        return own.isEmpty ? name(s.project) : own
    }

    let shown = board.visible(now).filter { !hidden.contains($0.project) }
    let waiting = shown.filter { $0.state == .waiting }
    let running = shown.filter { $0.state == .running }
    let blocking = waiting.filter { settings.takeover[$0.waitKind] ?? true }

    if let first = blocking.min(by: { $0.waitingSince < $1.waitingSince }) {
        var others: [String] = []
        if waiting.count > 1 { others.append("另有 \(waiting.count - 1) 个在等") }
        if !running.isEmpty { others.append("\(running.count) 个运行中") }
        var view = FrameView(kind: .wait, font: settings.font)
        view.title = waitTitle[first.waitKind] ?? "等你处理"
        view.task = headline(first)
        view.agent = agentLabel[first.source] ?? first.source
        view.detail = settings.showDetail && first.waitKind == "permission" ? first.detail : ""
        view.since = "\(hhmm(first.waitingSince)) 开始等"
        view.footer = others.isEmpty ? "其他 Agent 空闲" : others.joined(separator: " · ")
        return view
    }

    if !shown.isEmpty {
        let counts = [(waiting.count, "等你"), (running.count, "运行"), (shown.filter { $0.state == .done }.count, "完成"),
                      (shown.filter { $0.state == .error }.count, "出错")]
        var view = FrameView(kind: .list, font: settings.font)
        view.summary = shown.allSatisfy { $0.state == .done } ? "全部完成"
            : counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        // most urgent first; the rest wait for a free line
        view.rows = shown.prefix(min(settings.maxRows, maxRows)).map { s in
            // The agent's tag carries the state (solid while working, outlined once finished).
            // The right-hand column is how long the task has run, or took; or a word when it needs a look.
            var row = ViewRow(state: s.state, agent: agentLabel[s.source] ?? s.source, title: headline(s), when: "")
            switch s.state {
            case .running:
                row.when = duration(now - s.startedAt, running: true)
                row.minutes = Int((now - s.startedAt) / 60)
                row.tick = Int(now / durationTick)
            case .done: row.when = duration(s.finishedAt - s.startedAt)
            default: row.when = s.state == .waiting ? "等你" : "出错"
            }
            return row
        }
        view.quota = quota
        return view
    }

    var view = FrameView(kind: .idle, font: settings.font)
    view.line = "没有运行中的 Agent"
    if settings.idleShowLast, let last = board.lastFinished, !hidden.contains(last.project) {
        let title = settings.showTitles ? (last.title ?? "") : ""
        view.last = "上次：\(title.isEmpty ? name(last.project) : title) · \(hhmm(last.at))"
    }
    view.quota = quota
    return view
}

/// Made-up quota for previewing settings.
public let sampleUsage: Usage = [
    "claude": AgentUsage(windows: [fiveHour: QuotaLeft(left: 36, resetsAt: 0), sevenDay: QuotaLeft(left: 73, resetsAt: 0)]),
    "codex": AgentUsage(windows: [sevenDay: QuotaLeft(left: 95, resetsAt: 0)]),
]

/// A made-up board for previewing settings without touching the real one.
public func sampleBoard(_ kind: String, now: Double = Date().timeIntervalSince1970) -> Board {
    let board = Board()
    if kind == "idle" {
        board.lastFinished = LastFinished(project: "website", title: "把首页改成响应式布局", source: "claude", at: now - 900, state: "done")
        return board
    }
    func ask(_ agent: String, _ sid: String, _ project: String, _ prompt: String, _ ago: Double) {
        board.apply(agent, "UserPromptSubmit", ["session_id": .string(sid), "cwd": .string("/demo/\(project)"), "prompt": .string(prompt)],
                    now: now - ago)
    }
    ask("claude", "1", "mobile-app", "给登录页加上短信验证码", 1500)
    ask("codex", "2", "data-pipeline", "修复订单导出的时区问题", 600)
    ask("claude", "3", "website", "把首页改成响应式布局", 2400)
    board.apply("claude", "Stop", ["session_id": "3"], now: now - 900)
    ask("codex", "4", "docs", "更新接口文档里的鉴权说明", 1200)
    board.apply("codex", "StopFailure", ["session_id": "4"], now: now - 300)
    if kind == "wait" {
        board.apply("claude", "PermissionRequest", ["session_id": "1", "tool_name": "Bash"], now: now - 45)
    }
    return board
}
