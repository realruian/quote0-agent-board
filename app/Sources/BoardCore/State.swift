// Session state machine: turns agent hook events into what the board shows.

import Foundation

public enum SessionState: String, Codable {
    case idle, running, waiting, done, error

    var isFinished: Bool { self == .idle || self == .done || self == .error }
    var sortOrder: Int { [.waiting: 0, .running: 1, .error: 2, .done: 3][self] ?? 4 }
}

// Tools that mean "the agent is blocked on the user" as soon as they start.
private let questionTools: Set<String> = ["AskUserQuestion"]
private let planTools: Set<String> = ["ExitPlanMode"]

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

private let worktree = regex("/([^/]+)/\\.claude/worktrees/[^/]+$")
private let scratch = regex("^scratch-\\d{4}-\\d{2}-\\d{2}")
private let markup = regex("<([a-zA-Z][\\w-]*)\\b[^>]*>.*?</\\1>", [.dotMatchesLineSeparators])
private let codexRequest = regex("^#+\\s*My request for Codex:?\\s*$", [.anchorsMatchLines, .caseInsensitive])

extension String {
    var whole: NSRange { NSRange(startIndex..., in: self) }
}

/// Short label for a session, derived from its working directory.
public func projectName(_ cwd: String) -> String {
    if cwd.isEmpty { return "未知项目" }
    var path = cwd
    while path.hasSuffix("/") { path.removeLast() }
    if let match = worktree.firstMatch(in: path, range: path.whole), let range = Range(match.range(at: 1), in: path) {
        return String(path[range])
    }
    let name = path.split(separator: "/").last.map(String.init) ?? path
    if name.isEmpty { return path }
    if scratch.firstMatch(in: name, range: name.whole) != nil { return "临时会话" }
    return name
}

let titleMinChars = 6
let titleMaxChars = 60

/// One line saying what a prompt asks for, or "" when it says too little
/// to name the task ("继续", "ok", a slash command).
public func taskTitle(_ prompt: String?) -> String {
    guard let prompt = prompt else { return "" }
    var text = markup.stringByReplacingMatches(in: prompt, range: prompt.whole, withTemplate: " ")  // reminders and pasted blocks wrapped in tags
    if let request = codexRequest.firstMatch(in: text, range: text.whole), let range = Range(request.range, in: text) {
        text = String(text[range.upperBound...])  // Codex apps list attached files first
    }
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    let first = lines.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
    let line = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if line.hasPrefix("/") || line.count < titleMinChars { return "" }
    return String(line.prefix(titleMaxChars))
}

public struct Session: Codable, Equatable {
    public var key: String
    public var source: String
    public var project: String
    public var name = ""  // the conversation's name in its own app; filled in by the engine
    public var title = ""  // stand-in until a name exists: the start of the user's prompt
    public var transcript = ""  // where the agent records the session, for looking the name up
    public var state = SessionState.idle
    public var waitKind = ""  // permission | question | plan
    public var detail = ""  // tool name behind a permission request
    public var resumeState = ""  // state to go back to once a wait is resolved
    public var waitingSince = 0.0
    public var startedAt = 0.0
    public var updatedAt = 0.0
    public var finishedAt = 0.0

    enum CodingKeys: String, CodingKey {
        case key, source, project, name, title, transcript, state, detail
        case waitKind = "wait_kind", resumeState = "resume_state", waitingSince = "waiting_since"
        case startedAt = "started_at", updatedAt = "updated_at", finishedAt = "finished_at"
    }

    public init(key: String, source: String, project: String) {
        self.key = key
        self.source = source
        self.project = project
    }

    /// The identity the agent gave the conversation, without the agent's own prefix.
    var id: String { key.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }

    /// When the session came to the state it is in. Tool calls do not move it, so
    /// rows ordered by it keep their places while the agents work.
    var since: Double { state == .waiting ? waitingSince : state == .running ? startedAt : finishedAt }
}

public struct LastFinished: Codable, Equatable {
    public var project: String
    public var title: String?
    public var source: String?
    public var at: Double
    public var state: String?
}

public final class Board {
    public var sessions: [String: Session] = [:]
    public var doneTTL: Double
    public var staleRunning: Double
    public var staleWaiting: Double
    public var lastFinished: LastFinished?
    private var arrival: [String: Int] = [:]  // ties in the order keep the order sessions arrived in
    private var arrivals = 0

    public init(doneTTL: Double = 1800, staleRunning: Double = 3600, staleWaiting: Double = 43200) {
        self.doneTTL = doneTTL
        self.staleRunning = staleRunning
        self.staleWaiting = staleWaiting
    }

    // MARK: events

    /// Apply one hook event. Returns true when the visible board changed.
    @discardableResult
    public func apply(_ source: String, _ event: String, _ payload: JSON, now: Double = Date().timeIntervalSince1970) -> Bool {
        func field(_ name: String) -> String { payload[name]?.string ?? "" }
        let cwd = field("cwd")
        let sid = [field("session_id"), field("conversation_id"), cwd].first { !$0.isEmpty } ?? "default"
        let key = "\(source):\(sid)"
        let before = snapshot(now)

        if event == "SessionEnd" {
            sessions[key] = nil
            return snapshot(now) != before
        }

        var s = sessions[key] ?? Session(key: key, source: source, project: projectName(cwd))
        if sessions[key] == nil {
            arrivals += 1
            arrival[key] = arrivals
        } else if !cwd.isEmpty {
            s.project = projectName(cwd)
        }

        if !field("transcript_path").isEmpty { s.transcript = field("transcript_path") }
        let tool = field("tool_name")
        // Events from a background subagent must not revive a finished session.
        let background = (payload["agent_id"]?.truthy ?? false) && s.state.isFinished

        switch event {
        case "UserPromptSubmit":
            // A short follow-up keeps the title of the task it follows up on.
            let title = taskTitle(payload["prompt"]?.string)
            if !title.isEmpty { s.title = title }
            run(&s, now, newTurn: true)
        case "PreToolUse":
            if questionTools.contains(tool) {
                wait(&s, "question", tool, now)
            } else if planTools.contains(tool) {
                wait(&s, "plan", tool, now)
            } else if !background {
                run(&s, now)
            }
        case "PermissionRequest":
            wait(&s, "permission", tool, now)
        case "PostToolUse", "PostToolUseFailure":
            if s.state == .waiting {
                s.state = SessionState(rawValue: s.resumeState) ?? .running
                s.waitKind = ""
                s.detail = ""
            } else if !background {
                run(&s, now)
            }
        case "Notification":
            if field("notification_type") == "elicitation_dialog" { wait(&s, "question", "", now) }
        case "Stop": finish(&s, .done, now)
        case "StopFailure": finish(&s, .error, now)
        default: break  // SessionStart and anything unknown only registers the session.
        }

        s.updatedAt = now
        sessions[key] = s
        return snapshot(now) != before
    }

    private func run(_ s: inout Session, _ now: Double, newTurn: Bool = false) {
        if newTurn || s.state.isFinished { s.startedAt = now }
        s.state = .running
        s.waitKind = ""
        s.detail = ""
    }

    private func wait(_ s: inout Session, _ kind: String, _ detail: String, _ now: Double) {
        if s.state != .waiting {
            s.resumeState = s.state.isFinished ? s.state.rawValue : SessionState.running.rawValue
            s.waitingSince = now
        }
        s.state = .waiting
        s.waitKind = kind
        s.detail = detail
    }

    private func finish(_ s: inout Session, _ state: SessionState, _ now: Double) {
        s.state = state
        s.waitKind = ""
        s.detail = ""
        s.finishedAt = now
        lastFinished = LastFinished(project: s.project, title: s.name.isEmpty ? s.title : s.name, source: s.source, at: now,
                                    state: state.rawValue)
    }

    // MARK: views

    /// Sessions worth showing, most urgent first; within a state, the newest first.
    public func visible(_ now: Double = Date().timeIntervalSince1970) -> [Session] {
        sessions.values
            .filter { $0.state == .running || $0.state == .waiting || (($0.state == .done || $0.state == .error) && now - $0.finishedAt < doneTTL) }
            .sorted {
                if $0.state.sortOrder != $1.state.sortOrder { return $0.state.sortOrder < $1.state.sortOrder }
                if $0.since != $1.since { return $0.since > $1.since }
                return (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0)
            }
    }

    private struct Snap: Equatable {
        let key, project, name, title: String
        let state: SessionState
        let waitKind, detail: String
        let startedAt, finishedAt: Double
    }

    private func snapshot(_ now: Double) -> [Snap] {
        visible(now).map {
            Snap(key: $0.key, project: $0.project, name: $0.name, title: $0.title, state: $0.state, waitKind: $0.waitKind,
                 detail: $0.detail, startedAt: $0.startedAt, finishedAt: $0.finishedAt)
        }
    }

    /// Drop sessions that went quiet (crashed terminals, interrupted turns).
    public func prune(_ now: Double = Date().timeIntervalSince1970) {
        for (key, s) in sessions {
            let quiet = now - s.updatedAt
            if (s.state == .running && quiet > staleRunning) || (s.state == .waiting && quiet > staleWaiting)
                || ((s.state == .done || s.state == .error) && now - s.finishedAt > doneTTL) || (s.state == .idle && quiet > 86400) {
                sessions[key] = nil
                arrival[key] = nil
            }
        }
    }

    // MARK: persistence

    public struct Saved: Codable {
        public var sessions: [Session]
        public var lastFinished: LastFinished?

        enum CodingKeys: String, CodingKey {
            case sessions
            case lastFinished = "last_finished"
        }
    }

    public var saved: Saved {
        Saved(sessions: sessions.values.sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }, lastFinished: lastFinished)
    }

    public func load(_ saved: Saved) {
        sessions = [:]
        arrival = [:]
        for s in saved.sessions {
            sessions[s.key] = s
            arrivals += 1
            arrival[s.key] = arrivals
        }
        lastFinished = saved.lastFinished
    }
}
