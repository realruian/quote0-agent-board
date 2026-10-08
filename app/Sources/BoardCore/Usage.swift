// Subscription quota readings.
//
// Nothing here logs in anywhere or reads a credential:
// - Codex writes its rate limits into its own session records after every reply.
// - Claude Code answers a usage request on its command line's control channel,
//   with the sign-in the command line already has.
//
// A Claude reading goes stale quickly, because every Claude app on the account
// spends the same quota, so it is asked for again every few minutes and only
// trusted while it is recent.

import CFNetwork
import Foundation

/// A window as the agent reports it: percent used, and when it starts over.
public struct QuotaUsed: Equatable {
    public var used: Double
    public var resetsAt: Double
}

public struct QuotaReading: Equatable {
    public var observedAt: Double
    public var windows: [String: QuotaUsed]
}

public enum UsageReader {
    public static var codexSessions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private static let tailBytes = 256_000

    static let claudeEvery = 5.0 * 60
    static let claudeTimeout = 15.0
    static let claudeMaxAge = 20.0 * 60
    // Nothing of the user's is loaded (so our own hooks do not fire), no tools, nothing saved.
    private static let claudeArguments = ["--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--mcp-config",
                                          "{\"mcpServers\":{}}", "--tools", "", "--output-format", "stream-json", "--input-format",
                                          "stream-json", "--verbose"]
    // Set inside a Claude Code session; with them the command line acts as part of that session.
    private static let claudeSessionEnvironment = ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
                                                   "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID"]

    /// First value stored under `key` anywhere inside nested objects.
    static func find(_ value: JSON, _ key: String) -> JSON? {
        guard let object = value.object else { return nil }
        if let found = object[key] { return found }
        for (_, child) in object.pairs {
            if let found = find(child, key), !found.isNull { return found }
        }
        return nil
    }

    static func kind(_ windowMinutes: JSON?) -> String? {
        guard let minutes = windowMinutes?.double else { return nil }
        if minutes <= 360 { return fiveHour }
        return minutes >= 10000 ? sevenDay : nil
    }

    static func iso(_ stamp: JSON?) -> Double {
        guard let text = stamp?.string else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        // more digits after the second than the formatter takes: drop them
        let trimmed = text.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        return formatter.date(from: trimmed)?.timeIntervalSince1970 ?? 0
    }

    // MARK: Codex

    /// The last rate-limit record in one Codex session file.
    static func codex(from path: String) throws -> QuotaReading? {
        for line in try tailLines(path, bytes: tailBytes).reversed() where line.contains("\"rate_limits\"") {
            guard let record = try? JSON(parsing: line), let limits = find(record, "rate_limits"), limits.object != nil else { continue }
            var windows: [String: QuotaUsed] = [:]
            for slot in ["primary", "secondary"] {
                guard let window = limits[slot], let kind = kind(window["window_minutes"]), let used = window["used_percent"]?.double else { continue }
                windows[kind] = QuotaUsed(used: used, resetsAt: window["resets_at"]?.double ?? 0)
            }
            guard !windows.isEmpty else { continue }
            var observed = iso(record["timestamp"])
            if observed == 0 { observed = modified(path) }
            return QuotaReading(observedAt: observed, windows: windows)
        }
        return nil
    }

    private static func modified(_ path: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
    }

    static let codexDays = 7  // how many of the newest day folders are looked through
    private static var codexReading: QuotaReading?

    static func forgetCodex() { codexReading = nil }

    /// Codex's limits as its newest session record has them. The folders hold every
    /// conversation ever had, so only the last few days' are looked through, with the
    /// records of the conversations now open (`also`), wherever those are. A reading
    /// is kept until a later one turns up.
    public static func readCodex(also transcripts: [String] = []) -> QuotaReading? {
        // sessions/<year>/<month>/<day>/rollout-*.jsonl; the folders' names sort by date
        let manager = FileManager.default
        func children(_ path: String) -> [String] { ((try? manager.contentsOfDirectory(atPath: path)) ?? []).sorted(by: >) }
        func dated(_ path: String) -> [String] { children(path).filter { $0.allSatisfy(\.isNumber) }.map { "\(path)/\($0)" } }
        func isRecord(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        }
        var files = Set(transcripts.filter(isRecord))
        var days = 0
        search: for year in dated(codexSessions.path) {
            for month in dated(year) {
                for day in dated(month) {
                    let records = children(day).map { "\(day)/\($0)" }.filter(isRecord)
                    if records.isEmpty { continue }
                    files.formUnion(records)
                    days += 1
                    if days == codexDays { break search }
                }
            }
        }
        for (path, _) in files.map({ ($0, modified($0)) }).sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let reading = (try? codex(from: path)) ?? nil else { continue }
            if reading.observedAt >= codexReading?.observedAt ?? 0 { codexReading = reading }
            break
        }
        return codexReading
    }

    // MARK: Claude

    public static func claudeBinary() -> String? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first { manager.isExecutableFile(atPath: $0) }
    }

    /// The environment to ask in: outside any Claude Code session this process was
    /// started from, and through the system proxy, which a launchd job is not told about.
    private static func claudeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !claudeSessionEnvironment.contains($0.key) }
        if let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            for (scheme, enabled, host, port) in [("HTTP", "HTTPEnable", "HTTPProxy", "HTTPPort"), ("HTTPS", "HTTPSEnable", "HTTPSProxy", "HTTPSPort")] {
                guard (proxies[enabled] as? Int) == 1, let name = proxies[host] as? String, environment["\(scheme)_PROXY"] == nil else { continue }
                environment["\(scheme)_PROXY"] = "http://\(name)" + ((proxies[port] as? Int).map { ":\($0)" } ?? "")
            }
        }
        return environment
    }

    /// The command line's answer to a usage request, or nil when it gives none in time.
    static func askClaude(_ binary: String, timeout: Double = claudeTimeout) -> JSON? {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = claudeArguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = claudeEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
        }

        func send(_ id: String, _ subtype: String) {
            let request: JSON = ["type": "control_request", "request_id": .string(id), "request": ["subtype": .string(subtype)]]
            try? input.fileHandleForWriting.write(contentsOf: Data((request.compact + "\n").utf8))
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()
        send("init", "initialize")
        while true {
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard poll(&watched, 1, wait) > 0 else { return nil }  // out of time
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return nil }  // the command line went away
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[(newline + 1)...]
                guard let message = try? JSON(parsing: Data(line)), message["type"]?.string == "control_response",
                      let reply = message["response"], reply.object != nil else { continue }
                guard reply["subtype"]?.string == "success" else { return nil }
                if reply["request_id"]?.string == "init" {
                    send("usage", "get_usage")
                } else if reply["request_id"]?.string == "usage" {
                    return reply["response"]
                }
            }
        }
    }

    static func claudeWindows(_ limits: JSON?) -> [String: QuotaUsed] {
        var windows: [String: QuotaUsed] = [:]
        for kind in usageWindows {
            guard let window = limits?[kind], let used = window["utilization"]?.double else { continue }
            // the reported reset time wobbles by a fraction of a second from one ask to the next
            windows[kind] = QuotaUsed(used: used, resetsAt: (iso(window["resets_at"]) / 60).rounded() * 60)
        }
        return windows
    }

    private static var claudeAskedAt = 0.0
    private static var claudeReading: QuotaReading?

    static func forgetClaude() {
        claudeAskedAt = 0
        claudeReading = nil
    }

    /// Claude's limits as the command line last reported them. Asking starts a
    /// process and reaches Anthropic, so it is done every few minutes and the answer
    /// kept; an ask that fails leaves the earlier reading to age out.
    static func readClaude(now: Double = Date().timeIntervalSince1970, binary: String? = claudeBinary(),
                                  ask: (String) -> JSON? = { askClaude($0) }) -> QuotaReading? {
        if now - claudeAskedAt >= claudeEvery {
            claudeAskedAt = now
            let windows = claudeWindows(binary.flatMap(ask)?["rate_limits"])
            if !windows.isEmpty { claudeReading = QuotaReading(observedAt: now, windows: windows) }
        }
        return claudeReading
    }

    // MARK: what is left

    /// Remaining percent per window, keeping only what can still be trusted.
    static func left(_ agent: String, _ reading: QuotaReading?, _ now: Double) -> [String: QuotaLeft] {
        guard let reading = reading else { return [:] }
        let age = now - reading.observedAt
        var out: [String: QuotaLeft] = [:]
        for (kind, window) in reading.windows {
            var reset = window.resetsAt
            let rolledOver = reset != 0 && now >= reset
            var left: Double
            if agent == "claude" {
                if age > claudeMaxAge || rolledOver { continue }
                left = 100 - window.used
            } else {
                // Codex's own record: nothing was spent from this machine after it,
                // so it holds until the window resets, and is full again after.
                left = rolledOver ? 100 : 100 - window.used
                if rolledOver { reset = 0 }
            }
            left = max(0, min(100, left.rounded(.toNearestOrEven)))
            out[kind] = QuotaLeft(left: Int(left), resetsAt: reset)
        }
        return out
    }

    /// Per agent and window, percent left and reset time. An agent has no windows
    /// when there is no reading worth showing.
    public static func snapshot(now: Double = Date().timeIntervalSince1970, codexTranscripts: [String] = []) -> Usage {
        let claude = readClaude(now: now), codex = readCodex(also: codexTranscripts)
        return [
            "claude": AgentUsage(windows: left("claude", claude, now), observedAt: claude?.observedAt ?? 0),
            "codex": AgentUsage(windows: left("codex", codex, now), observedAt: codex?.observedAt ?? 0),
        ]
    }
}
