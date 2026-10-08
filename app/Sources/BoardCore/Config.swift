// Paths and settings. The settings file is the one the Python version wrote, so a
// machine can move between the two without setting anything up again.

import Foundation

public enum Paths {
    /// Set by tests, which must never touch the real directory.
    public static var homeOverride: URL?

    public static var home: URL {
        if let homeOverride = homeOverride { return homeOverride }
        if let custom = ProcessInfo.processInfo.environment["AGENT_BOARD_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quote0-agent-board")
    }

    /// A separate instance for trying things out: it leaves launchd and the agents' hooks alone.
    public static var isDevelopment: Bool {
        homeOverride != nil || !(ProcessInfo.processInfo.environment["AGENT_BOARD_HOME"] ?? "").isEmpty
    }

    public static var socket: URL { home.appendingPathComponent("run/board.sock") }
    public static var config: URL { home.appendingPathComponent("config.json") }
    public static var state: URL { home.appendingPathComponent("state.json") }
    public static var frame: URL { home.appendingPathComponent("last-frame.png") }
    public static var log: URL { home.appendingPathComponent("logs/daemon.log") }
    public static var backups: URL { home.appendingPathComponent("backups") }
    public static var hook: URL { home.appendingPathComponent("bin/agent-board-hook") }
    public static var deviceBackup: URL { home.appendingPathComponent("device-settings-backup.json") }

    public static func tilde(_ path: String) -> String {
        let user = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(user) ? "~" + path.dropFirst(user.count) : path
    }
}

/// The files that ship with the app: the settings pages, the pixel font, the hook script.
public enum Resources {
    public static var directory: URL = {
        if let custom = ProcessInfo.processInfo.environment["AGENT_BOARD_RESOURCES"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }()
}

public struct QuietHours: Equatable {
    public var enabled = false
    public var start = "23:00"
    public var end = "07:00"

    var json: JSON { ["enabled": .bool(enabled), "start": .string(start), "end": .string(end)] }
}

public struct Settings: Equatable {
    public var deviceID = ""
    public var apiKeyFile = "~/.dot_api_key"
    public var apiBase = "https://dot.mindreset.tech"
    public var webPort = 8765
    // Display. Frames travel through MindReset's servers. The task title (the start of
    // the user's prompt) is on by request; the tool name behind a permission request
    // stays off the screen unless asked for.
    public var showTitles = true
    public var showDetail = false
    public var showUsage = true  // quota left, in the top bar and on the idle screen
    // When the device shows other loop content (its loop moved on, or the list was
    // edited in the Dot app), put the board back.
    public var keepOnScreen = true
    // Set from the menu bar: the screen says so and stays as it is until this is cleared.
    public var paused = false
    public var font = "pingfang"  // falls back to a system font when not installed
    public var maxRows = 4
    public var idleShowLast = true
    public var aliases: [String: String] = [:]
    public var hiddenProjects: [String] = []
    public var doneTTLMinutes = 30
    public var takeover = Settings.takeoverKinds.reduce(into: [String: Bool]()) { $0[$1] = true }
    public var quietHours = QuietHours()
    public var minPushIntervalSeconds = 10
    public var staleRunningMinutes = 60

    public static let takeoverKinds = ["permission", "question", "plan"]
    public static let fontChoices = ["pingfang", "misans", "hiragino", "arkpixel", "zhengge", "chill"]
    /// What the settings page may change. The rest identifies the device.
    public static let editable = ["font", "keep_on_screen", "paused", "show_titles", "show_detail", "show_usage", "max_rows",
                                  "idle_show_last", "aliases", "hidden_projects", "done_ttl_minutes", "takeover", "quiet_hours",
                                  "min_push_interval_seconds", "stale_running_minutes"]

    public init() {}

    /// Defaults with whatever the file holds laid over them. A value of the wrong type is ignored.
    init(stored: JSONObject) {
        func text(_ key: String, _ into: inout String) { if let v = stored[key]?.string { into = v } }
        func flag(_ key: String, _ into: inout Bool) { if let v = stored[key]?.bool { into = v } }
        func whole(_ key: String, _ into: inout Int) { if let v = stored[key]?.int { into = v } }
        text("device_id", &deviceID)
        text("api_key_file", &apiKeyFile)
        text("api_base", &apiBase)
        whole("web_port", &webPort)
        flag("show_titles", &showTitles)
        flag("show_detail", &showDetail)
        flag("show_usage", &showUsage)
        flag("keep_on_screen", &keepOnScreen)
        flag("paused", &paused)
        text("font", &font)
        whole("max_rows", &maxRows)
        flag("idle_show_last", &idleShowLast)
        if let object = stored["aliases"]?.object {
            aliases = object.pairs.reduce(into: [:]) { if let v = $1.1.string { $0[$1.0] = v } }
        }
        if let items = stored["hidden_projects"]?.array { hiddenProjects = items.compactMap(\.string) }
        whole("done_ttl_minutes", &doneTTLMinutes)
        for kind in Settings.takeoverKinds {
            if let v = stored["takeover"]?[kind]?.bool { takeover[kind] = v }
        }
        if let quiet = stored["quiet_hours"] {
            if let v = quiet["enabled"]?.bool { quietHours.enabled = v }
            if let v = quiet["start"]?.string { quietHours.start = v }
            if let v = quiet["end"]?.string { quietHours.end = v }
        }
        whole("min_push_interval_seconds", &minPushIntervalSeconds)
        whole("stale_running_minutes", &staleRunningMinutes)
    }

    var takeoverJSON: JSON {
        var object = JSONObject()
        for kind in Settings.takeoverKinds { object[kind] = .bool(takeover[kind] ?? true) }
        return .object(object)
    }

    /// The editable settings, as the settings page reads them.
    public var editableJSON: JSON {
        var aliasObject = JSONObject()
        for name in aliases.keys.sorted() { aliasObject[name] = .string(aliases[name]!) }
        return [
            "font": .string(font), "keep_on_screen": .bool(keepOnScreen), "paused": .bool(paused),
            "show_titles": .bool(showTitles), "show_detail": .bool(showDetail), "show_usage": .bool(showUsage),
            "max_rows": JSON(maxRows), "idle_show_last": .bool(idleShowLast), "aliases": .object(aliasObject),
            "hidden_projects": JSON(hiddenProjects), "done_ttl_minutes": JSON(doneTTLMinutes), "takeover": takeoverJSON,
            "quiet_hours": quietHours.json, "min_push_interval_seconds": JSON(minPushIntervalSeconds),
            "stale_running_minutes": JSON(staleRunningMinutes),
        ]
    }

    public var apiKeyPath: URL { URL(fileURLWithPath: (apiKeyFile as NSString).expandingTildeInPath) }

    public func apiKey() throws -> String {
        try String(contentsOf: apiKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether there is a device to send frames to: one has been chosen and its key is in place.
    public var ready: Bool {
        var isDirectory: ObjCBool = false
        return !deviceID.isEmpty && FileManager.default.fileExists(atPath: apiKeyPath.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

/// A change the settings page asked for that cannot be made; the message is shown to the user.
public struct ConfigError: Error, Equatable {
    public let message: String
}

public enum ConfigStore {
    static func stored() -> JSONObject {
        guard let data = try? Data(contentsOf: Paths.config), let json = try? JSON(parsing: data) else { return JSONObject() }
        return json.object ?? JSONObject()
    }

    public static func load() -> Settings { Settings(stored: stored()) }

    public static func save(_ patch: JSONObject) throws {
        var all = stored()
        for (key, value) in patch.pairs { all[key] = value }
        try write(Data((JSON.object(all).pretty() + "\n").utf8), to: Paths.config)
    }

    /// Replace a file in one step, so a reader never sees half of it.
    public static func write(_ data: Data, to url: URL, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode])
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static let clock = try! NSRegularExpression(pattern: "^([01]\\d|2[0-3]):[0-5]\\d$")

    static func isClock(_ text: String) -> Bool {
        clock.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Check a settings change from the settings page; return it cleaned, or say what is wrong with it.
    public static func validate(_ patch: JSON) throws -> JSONObject {
        guard let patch = patch.object else { throw ConfigError(message: "设置格式不对") }

        func whole(_ value: JSON, _ low: Int, _ high: Int, _ label: String) throws -> JSON {
            guard let n = value.int, low <= n, n <= high else {
                throw ConfigError(message: "\(label)需要是 \(low) 到 \(high) 之间的整数")
            }
            return JSON(n)
        }
        func flag(_ value: JSON, _ label: String) throws -> Bool {
            guard let on = value.bool else { throw ConfigError(message: "\(label)需要是开或关") }
            return on
        }
        func name(_ value: JSON, _ label: String) throws -> String {
            guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  (value.string ?? "").count <= 60 else {
                throw ConfigError(message: "\(label)需要是 1 到 60 个字符")
            }
            return text
        }

        var clean = JSONObject()
        for (key, value) in patch.pairs {
            guard Settings.editable.contains(key) else { throw ConfigError(message: "不能在这里修改 \(key)") }
            switch key {
            case "keep_on_screen", "paused", "show_titles", "show_detail", "show_usage", "idle_show_last":
                clean[key] = .bool(try flag(value, key))
            case "font":
                guard let font = value.string, Settings.fontChoices.contains(font) else {
                    throw ConfigError(message: "没有这个字体选项")
                }
                clean[key] = value
            case "max_rows": clean[key] = try whole(value, 1, 4, "最多显示行数")
            case "done_ttl_minutes": clean[key] = try whole(value, 1, 720, "完成后保留时间")
            case "stale_running_minutes": clean[key] = try whole(value, 5, 1440, "无动静移除时间")
            case "min_push_interval_seconds": clean[key] = try whole(value, 3, 600, "最小刷新间隔")
            case "aliases":
                guard let object = value.object, object.keys.count <= 100 else { throw ConfigError(message: "别名列表格式不对") }
                var aliases = JSONObject()
                for (project, alias) in object.pairs {
                    // an alias cleared in the page arrives as an empty string: that entry goes away
                    if let text = alias.string, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    aliases[try name(.string(project), "项目名")] = .string(try name(alias, "别名"))
                }
                clean[key] = .object(aliases)
            case "hidden_projects":
                guard let items = value.array, items.count <= 100 else { throw ConfigError(message: "隐藏列表格式不对") }
                clean[key] = JSON(Array(Set(try items.map { try name($0, "项目名") })).sorted())
            case "takeover":
                guard let object = value.object, object.keys.allSatisfy(Settings.takeoverKinds.contains) else {
                    throw ConfigError(message: "整屏提醒设置格式不对")
                }
                var merged = load().takeover
                for (kind, on) in object.pairs { merged[kind] = try flag(on, "整屏提醒") }
                var settings = Settings()
                settings.takeover = merged
                clean[key] = settings.takeoverJSON
            case "quiet_hours":
                guard let object = value.object, object.keys.allSatisfy(["enabled", "start", "end"].contains) else {
                    throw ConfigError(message: "免打扰设置格式不对")
                }
                var quiet = load().quietHours
                if let on = object["enabled"] { quiet.enabled = try flag(on, "免打扰") }
                for (edge, keyPath) in [("start", \QuietHours.start), ("end", \QuietHours.end)] {
                    guard let given = object[edge] else { continue }
                    guard let text = given.string, isClock(text) else { throw ConfigError(message: "免打扰时间需要是 HH:MM 格式") }
                    quiet[keyPath: keyPath] = text
                }
                guard quiet.start != quiet.end else { throw ConfigError(message: "免打扰的开始和结束时间不能相同") }
                clean[key] = quiet.json
            default: break
            }
        }
        return clean
    }
}
