// Add and remove the board's hook entries in the agents' own config files.
//
// Entries are always appended after whatever is already there and are recognised
// again by a marker, so other tools' hooks keep their content and position.

import Foundation

public enum Hooks {
    static let marker = ".quote0-agent-board/bin/agent-board-hook"

    // event -> matcher (nil = no matcher). Only events both agents already use here.
    static let claudeEvents: [(String, String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"), ("PermissionRequest", "*"),
        ("Notification", "*"), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
    ]
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"]

    public static let agents = ["claude", "codex"]

    /// Where each agent keeps its hooks. Tests point these somewhere else.
    public static var files: [String: URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["claude": home.appendingPathComponent(".claude/settings.json"), "codex": home.appendingPathComponent(".codex/hooks.json")]
    }()

    private static func backup(_ path: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: Paths.backups, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var folder = path.deletingLastPathComponent().lastPathComponent
        while folder.hasPrefix(".") { folder.removeFirst() }
        let copy = Paths.backups.appendingPathComponent("\(folder)-\(path.lastPathComponent).\(formatter.string(from: Date()))")
        try? manager.removeItem(at: copy)
        try? manager.copyItem(at: path, to: copy)
    }

    /// Rewrite a JSON file in the style it already uses, to keep the change small.
    private static func write(_ data: JSON, to path: URL, replacing old: String) throws {
        let spacedColons = old.contains("\" : ")  // the style Swift tools write
        var text = data.pretty(colon: spacedColons ? " : " : ": ")
        if spacedColons { text = text.replacingOccurrences(of: "/", with: "\\/") }
        if old.hasSuffix("\n") { text += "\n" }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) ?? 0o644
        let tmp = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".agent-board.tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        guard rename(tmp.path, path.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func isOurs(_ group: JSON) -> Bool {
        if group["_agent_board"]?.truthy == true { return true }
        return (group["hooks"]?.array ?? []).contains { ($0["command"]?.string ?? "").contains(marker) }
    }

    static func groups(for agent: String) -> [(String, JSON)] {
        func command(_ text: String) -> JSON { ["type": "command", "command": .string(text), "timeout": 5] }
        if agent == "claude" {
            return claudeEvents.map { event, matcher in
                let text = "/bin/sh -c '[ -x \"$HOME/\(marker)\" ] && \"$HOME/\(marker)\" claude \(event); exit 0'"
                var group = JSONObject()
                if let matcher = matcher { group["matcher"] = .string(matcher) }
                group["hooks"] = [command(text)]
                return (event, .object(group))
            }
        }
        return codexEvents.map { event in
            (event, ["_agent_board": true, "hooks": [command("'\(Paths.hook.path)' codex \(event)")]])
        }
    }

    /// The same content whatever order the keys are in.
    private static func canonical(_ value: JSON) -> String {
        switch value {
        case .object(let object):
            return "{" + object.keys.sorted().map { JSON.quoted($0) + ":" + canonical(object[$0]!) }.joined(separator: ",") + "}"
        case .array(let items): return "[" + items.map(canonical).joined(separator: ",") + "]"
        default: return value.compact
        }
    }

    /// Drop our hook groups from `path`, then append `add` (event -> group) if given.
    static func edit(_ path: URL, add: [(String, JSON)]?) throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "not found, skipped" }
        let old = try String(contentsOf: path, encoding: .utf8)
        guard var data = try JSON(parsing: old).object else { throw ConfigError(message: "配置文件不是合法的 JSON") }
        var hooks = data["hooks"]?.object ?? JSONObject()
        let before = canonical(.object(hooks))
        for event in hooks.keys {
            guard let groups = hooks[event]?.array else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        for (event, group) in add ?? [] {
            hooks[event] = .array((hooks[event]?.array ?? []) + [group])  // appended last: existing positions stay put
        }
        if canonical(.object(hooks)) == before { return "already up to date" }
        data["hooks"] = .object(hooks)
        backup(path)
        try write(.object(data), to: path, replacing: old)
        return "updated"
    }

    @discardableResult
    public static func setEnabled(_ agent: String, _ enabled: Bool) throws -> String {
        guard let path = files[agent] else { throw ConfigError(message: "请求格式不对") }
        return try edit(path, add: enabled ? groups(for: agent) : nil)
    }

    public struct Status {
        public var path = ""
        public var exists = false
        public var installed = 0
        public var expected = 0
        public var vibeIsland = 0
        public var error: String?

        public var json: JSON {
            var object: JSONObject = ["path": .string(path), "exists": .bool(exists), "installed": JSON(installed),
                                      "expected": JSON(expected), "vibe_island": JSON(vibeIsland)]
            if let error = error { object["error"] = .string(error) }
            return .object(object)
        }
    }

    public static func status(_ agent: String) -> Status {
        guard let path = files[agent] else { return Status() }
        var info = Status(path: Paths.tilde(path.path), exists: FileManager.default.fileExists(atPath: path.path),
                          expected: groups(for: agent).count)
        guard info.exists else { return info }
        guard let text = try? String(contentsOf: path, encoding: .utf8), let data = try? JSON(parsing: text) else {
            info.error = "配置文件不是合法的 JSON"
            return info
        }
        for (_, groups) in data["hooks"]?.object?.pairs ?? [] {
            for group in groups.array ?? [] {
                if isOurs(group) {
                    info.installed += 1
                } else if (group["hooks"]?.array ?? []).contains(where: { ($0["command"]?.string ?? "").contains("vibe-island") }) {
                    info.vibeIsland += 1
                }
            }
        }
        return info
    }
}
