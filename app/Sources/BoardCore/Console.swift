// Local settings console: a small HTTP server on 127.0.0.1, inside the app.
//
// Nothing here is reachable from other machines. Requests must name this host
// (blocks DNS rebinding), carry the per-run token the page was served with, and,
// when they change something, come from this origin (blocks other sites' pages).
// The device API key is never sent to the browser; connecting a device takes one
// from the page, checks it with MindReset and stores it.

import Foundation

/// A request that cannot be served; the message is shown to the user.
public struct Problem: Error {
    public let message: String
    public let status: Int

    public init(_ message: String, _ status: Int = 400) {
        self.message = message
        self.status = status
    }
}

public final class Console {
    public struct Request {
        public var method: String
        public var path: String
        public var headers: [String: String]  // names in lower case
        public var body: Data

        public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }
    }

    public struct Response {
        public var status: Int
        public var contentType: String
        public var body: Data
        public var extra: [(String, String)] = []
    }

    static let holdIntervalMs = 12 * 60 * 60 * 1000  // the device API's maximum
    static let maxIntervalMinutes = holdIntervalMs / 60000  // and its minimum is one minute
    static let defaultIntervalMs = 5 * 60 * 1000
    static let maxBody = 65536
    static let logTailBytes = 48_000
    static let staticFiles = ["app.css": "text/css; charset=utf-8", "app.js": "text/javascript; charset=utf-8"]

    let engine: Engine
    public private(set) var port = 0
    public let token: String
    public var version = "dev"
    /// Asked for from the diagnostics page; the app knows how to start itself again.
    public var restart: () -> Void = {}
    private var listener: Int32 = -1

    public init(engine: Engine) {
        self.engine = engine
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public var page: String { "http://127.0.0.1:\(port)" }

    // MARK: - what each page needs

    private func usageJSON(_ usage: Usage?) -> JSON {
        var out = JSONObject()
        for agent in ["claude", "codex"] {
            guard let reading = usage?[agent] else { continue }
            var windows = JSONObject()
            for kind in usageWindows {
                if let window = reading.windows[kind] { windows[kind] = ["left": JSON(window.left), "resets_at": JSON(window.resetsAt)] }
            }
            out[agent] = ["windows": .object(windows), "observed_at": JSON(reading.observedAt)]
        }
        return .object(out)
    }

    func overview() -> JSON {
        engine.locked {
            let now = Date().timeIntervalSince1970
            let settings = engine.settings
            let hidden = Set(settings.hiddenProjects)
            let sessions: [JSON] = engine.board.visible(now).map { s in
                let since = s.state == .waiting ? s.waitingSince : s.state == .running ? s.startedAt : s.finishedAt
                return ["project": .string(s.project), "alias": .string(settings.aliases[s.project] ?? ""),
                        "title": .string(s.name.isEmpty ? s.title : s.name), "source": .string(s.source), "state": .string(s.state.rawValue),
                        "wait_kind": .string(s.waitKind), "since": JSON(since), "hidden": .bool(hidden.contains(s.project))]
            }
            return ["version": .string(version), "dry_run": .bool(engine.dryRun), "started_at": JSON(engine.startedAt), "now": JSON(now),
                    "view_kind": .string(engine.currentView(now: now).kind.rawValue), "sessions": .array(sessions),
                    "last_push": engine.lastPush?.json ?? .object(JSONObject()), "usage": usageJSON(engine.usage),
                    "show_usage": .bool(settings.showUsage), "paused": .bool(settings.paused),
                    "needs_setup": .bool(!engine.dryRun && !settings.ready)]
        }
    }

    /// Render a frame with unsaved settings, without sending it anywhere.
    func preview(_ body: JSON) throws -> Data {
        var stored = ConfigStore.stored()
        for (key, value) in try checked({ try ConfigStore.validate(body["config"] ?? .object(JSONObject())) }).pairs { stored[key] = value }
        let draft = Settings(stored: stored)
        let sample = body["sample"]?.string ?? "live"
        switch sample {
        case "live": return render(engine.locked { buildView(engine.board, settings: draft, usage: engine.usage) }).png
        case "list", "wait", "idle": return render(buildView(sampleBoard(sample), settings: draft, usage: sampleUsage)).png
        default: throw Problem("未知的示例画面")
        }
    }

    func settings() -> JSON {
        let (settings, known) = engine.locked { (engine.settings, Array(Set(engine.board.sessions.values.map(\.project))).sorted()) }
        return ["config": settings.editableJSON, "known_projects": JSON(known),
                "fonts": .array(Fonts.available().map { ["key": .string($0.key), "label": .string($0.label)] })]
    }

    @discardableResult
    private func checked<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ConfigError {
            throw Problem(error.message)
        }
    }

    func saveSettings(_ body: JSON) throws -> JSON {
        try checked { try engine.applyConfig(body) }
        return settings()
    }

    private func keyState(_ settings: Settings) -> JSON {
        guard let key = try? settings.apiKey() else { return ["present": false, "looks_valid": false] }
        return ["present": true, "looks_valid": .bool(key.hasPrefix("dot_app"))]
    }

    /// Give a device back the loop interval it had before the board was kept up on it.
    private func releaseHold(_ settings: Settings) {
        do {
            if let previous = try JSON(parsing: Data(contentsOf: Paths.deviceBackup))["powerMs"]?.int, previous > 0 {
                try DotAPI.setIntervals(settings, powerMs: previous)
            }
        } catch {  // the device may be gone, which is often why another is being chosen
            Log.warning("could not restore the previous device's loop interval: \(describe(error))")
        }
        try? FileManager.default.removeItem(at: Paths.deviceBackup)
    }

    /// For uninstalling: the device goes back to rotating through its loop as it did before.
    public func restoreDeviceInterval() {
        if FileManager.default.fileExists(atPath: Paths.deviceBackup.path) { releaseHold(engine.settings) }
    }

    /// Where connecting a device has got to: the key, then the device it is for.
    func setup() -> JSON {
        let settings = engine.settings
        var state: JSONObject = ["ready": .bool(settings.ready), "key": keyState(settings), "device_id": .string(settings.deviceID), "devices": []]
        guard state["key"]?["present"]?.bool == true else { return .object(state) }
        let found: [JSON]
        do {
            found = try DotAPI.devices(settings)
        } catch {
            state["error"] = .string(describe(error))
            return .object(state)
        }
        state["devices"] = .array(found.map { item in
            let id = item["id"]?.string ?? ""
            var probe = settings
            probe.deviceID = id
            // the name it has in the Dot app tells two devices apart better than a serial number
            let alias = (try? DotAPI.getSettings(probe))?["alias"]?.string ?? ""
            return ["id": .string(id), "model": .string(item["model"]?.string ?? ""), "alias": .string(alias)]
        })
        return .object(state)
    }

    func saveSetup(_ body: JSON) throws -> JSON {
        let settings = engine.settings
        if let given = body["key"] {
            let key = (given.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
            guard key.hasPrefix("dot_app"), key.count <= 300, plain else { throw Problem("这不像 Dot 的 API 密钥，它以 dot_app 开头") }
            do {
                _ = try DotAPI.devices(settings, key: key)
            } catch let error as DotError {
                throw Problem([400, 401, 403].contains(error.status) ? "MindReset 说这个密钥无效，请重新复制一次" : "MindReset 服务没有接受这个密钥：\(error.message)")
            } catch {
                throw Problem("连不上 MindReset 服务：\(describe(error))", 502)
            }
            do {
                try ConfigStore.write(Data((key + "\n").utf8), to: settings.apiKeyPath, mode: 0o600)
            } catch {
                throw Problem("密钥没有保存：\(describe(error))", 500)
            }
            Log.info("API key saved from the settings page")
        }
        if let wanted = body["device_id"] {
            let known: Set<String>
            do {
                known = Set(try DotAPI.devices(settings).compactMap { $0["id"]?.string })
            } catch {
                throw Problem("连不上 MindReset 服务：\(describe(error))", 502)
            }
            guard let id = wanted.string, known.contains(id) else { throw Problem("这个密钥下没有这台设备") }
            if id != settings.deviceID {
                if !settings.deviceID.isEmpty { releaseHold(settings) }
                do {
                    try engine.useDevice(id)
                } catch {
                    throw Problem("设备没有保存：\(describe(error))", 500)
                }
                do {  // other loop content should not replace the board
                    _ = try saveDevice(["keep": true])
                } catch let problem as Problem {
                    Log.warning("could not keep the board up on the new device: \(problem.message)")
                }
            }
        }
        if body["key"] == nil && body["device_id"] == nil { throw Problem("没有要修改的内容") }
        engine.onChange?()
        return setup()
    }

    func device() -> JSON {
        let settings = engine.settings
        var info: JSONObject = ["device_id": .string(settings.deviceID), "key": keyState(settings), "ok": false]
        guard settings.ready else {
            info["error"] = "还没有连接设备"
            info["needs_setup"] = true
            return .object(info)
        }
        do {
            let status = try DotAPI.getStatus(settings)
            let current = try DotAPI.getSettings(settings)
            let slots = Set(try DotAPI.loopList(settings).compactMap { $0["type"]?.string })
            let interval = current["interval"]
            info["ok"] = true
            info["status"] = status["status"]?.object.map(JSON.object) ?? .object(JSONObject())
            info["asleep"] = .bool(DotAPI.asleep(status))
            info["last_render"] = .string(status["renderInfo"]?["last"]?.string ?? "")
            info["alias"] = .string(current["alias"]?.string ?? "")
            info["timezone"] = .string(current["timezone"]?.string ?? "")
            info["battery_minutes"] = JSON(Int(((interval?["batteryMs"]?.double ?? 0) / 60000).rounded()))
            info["keep"] = .bool(interval?["powerMs"]?.int == Console.holdIntervalMs || settings.keepOnScreen)
            info["sleep"] = current["sleep"]?.object.map(JSON.object) ?? ["enabled": false, "start": "23:00", "end": "07:00"]
            info["image_slot"] = .bool(slots.contains("IMAGE_API"))
        } catch {
            info["error"] = .string(describe(error))
        }
        return .object(info)
    }

    func saveDevice(_ body: JSON) throws -> JSON {
        let settings = engine.settings
        var change = JSONObject()
        var interval = JSONObject()
        if let alias = body["alias"] {
            guard let text = alias.string, text.count <= 100 else { throw Problem("设备名称最长 100 个字") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            change["alias"] = trimmed.isEmpty ? .null : .string(trimmed)
        }
        if let keep = body["keep"] {
            // One switch for both halves of keeping the board up: the device stops rotating
            // to other loop content on power, and the board is put back if it is replaced.
            guard let keep = keep.bool else { throw Problem("“始终显示状态牌”需要是开或关") }
            let current: JSON
            do {
                current = try DotAPI.getSettings(settings)["interval"] ?? .object(JSONObject())
            } catch {
                throw Problem("设备设置没有保存：\(describe(error))", 502)
            }
            let held = current["powerMs"]?.int == Console.holdIntervalMs
            let backup = Paths.deviceBackup
            if keep && !held {
                if !FileManager.default.fileExists(atPath: backup.path) { try? ConfigStore.write(Data(current.compact.utf8), to: backup) }
                interval["powerMs"] = JSON(Console.holdIntervalMs)
            } else if !keep && held {
                var previous = (try? JSON(parsing: Data(contentsOf: backup)))?["powerMs"]?.int ?? 0
                if previous == 0 || previous == Console.holdIntervalMs { previous = Console.defaultIntervalMs }
                interval["powerMs"] = JSON(previous)
            }
        }
        if let minutes = body["battery_minutes"] {
            guard let minutes = minutes.int, (1...Console.maxIntervalMinutes).contains(minutes) else {
                throw Problem("用电池时的刷新间隔需要是 1 到 \(Console.maxIntervalMinutes) 之间的整数分钟")
            }
            interval["batteryMs"] = JSON(minutes * 60000)
        }
        if !interval.isEmpty { change["interval"] = .object(interval) }
        if let sleep = body["sleep"] {
            guard let clean = try? ConfigStore.validate(["quiet_hours": sleep])["quiet_hours"] else {  // same shape and rules
                throw Problem("休眠时段需要是 HH:MM 格式，且开始和结束不能相同")
            }
            change["sleep"] = ["enabled": .bool(sleep["enabled"]?.truthy ?? false), "start": sleep["start"] ?? clean["start"] ?? "23:00",
                               "end": sleep["end"] ?? clean["end"] ?? "07:00"]
        }
        if change.isEmpty && body["keep"] == nil { throw Problem("没有要修改的内容") }
        if !change.isEmpty {
            do {
                try DotAPI.updateSettings(settings, .object(change))
            } catch {
                throw Problem("设备设置没有保存：\(describe(error))", 502)
            }
            Log.info("device settings changed: \(change.keys.sorted().joined(separator: ", "))")
        }
        if let keep = body["keep"] { try checked { try engine.applyConfig(["keep_on_screen": keep]) } }
        return device()
    }

    private var hookInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.hook.path) }

    func integrations() -> JSON {
        ["hook_installed": .bool(hookInstalled), "claude": Hooks.status("claude").json, "codex": Hooks.status("codex").json]
    }

    func saveIntegration(_ body: JSON) throws -> JSON {
        guard let agent = body["agent"]?.string, Hooks.agents.contains(agent), let enabled = body["enabled"]?.bool else {
            throw Problem("请求格式不对")
        }
        do {
            let result = try Hooks.setEnabled(agent, enabled)
            Log.info("\(agent) hooks \(enabled ? "enabled" : "disabled"): \(result)")
        } catch {
            throw Problem("没有改成：\(describe(error))", 500)
        }
        return integrations()
    }

    func logTail() -> JSON {
        Log.flush()
        guard let handle = try? FileHandle(forReadingFrom: Paths.log) else { return ["lines": []] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > UInt64(Console.logTailBytes) ? size - UInt64(Console.logTailBytes) : 0)
        let data = handle.readDataToEndOfFile()
        var lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        if data.count >= Console.logTailBytes, !lines.isEmpty { lines.removeFirst() }  // the cut usually lands inside a line
        return ["lines": JSON(lines)]
    }

    private func ago(_ seconds: Double) -> String {
        let seconds = Int(seconds)
        if seconds < 90 { return "\(seconds) 秒" }
        if seconds < 5400 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
    }

    /// Walk the chain from hooks to the screen. ok: true, false, or null for "worth a look".
    func runChecks() -> JSON {
        let settings = engine.settings
        let now = Date().timeIntervalSince1970
        var results: [JSON] = []
        func add(_ name: String, _ ok: Bool?, _ detail: String) {
            results.append(["name": .string(name), "ok": ok.map(JSON.bool) ?? .null, "detail": .string(detail)])
        }

        add("后台进程", true, "已运行 \(ago(now - engine.startedAt))" + (engine.dryRun ? "，空跑模式" : ""))
        add("钩子脚本", hookInstalled, Paths.tilde(Paths.hook.path))
        for (agent, label) in [("claude", "Claude Code 钩子"), ("codex", "Codex 钩子")] {
            let status = Hooks.status(agent)
            if !status.exists {
                add(label, nil, "没有找到它的配置文件")
            } else if status.installed == status.expected {
                add(label, true, "已安装 \(status.installed) 个")
            } else {
                add(label, status.installed == 0 ? nil : false, status.installed == 0 ? "未开启" : "只装了 \(status.installed)/\(status.expected) 个")
            }
        }
        let key = keyState(settings)
        let valid = key["looks_valid"]?.bool == true
        add("API 密钥", valid, valid ? "格式正确" : key["present"]?.bool == true ? "文件里的内容不像 Dot 密钥" : "没有找到 \(settings.apiKeyFile)")
        do {
            if settings.deviceID.isEmpty { throw Problem("还没有选择设备，在设置页的“连接设备”里完成") }
            let slots = Set(try DotAPI.loopList(settings).compactMap { $0["type"]?.string })
            add("连接 MindReset 服务", true, "正常")
            add("图像 API 内容", slots.contains("IMAGE_API"), slots.contains("IMAGE_API") ? "已在循环列表中" : "循环列表里没有，请在 Dot. App 的内容工坊添加")
            let status = try DotAPI.getStatus(settings)["status"]
            add("设备状态", true, [status?["current"]?.string, status?["battery"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        } catch let problem as Problem {
            add("连接 MindReset 服务", false, problem.message)
        } catch {
            add("连接 MindReset 服务", false, describe(error))
        }
        _ = render(buildView(sampleBoard("wait")))
        add("画面生成", !Fonts.available().isEmpty, Fonts.available().isEmpty ? "没有找到可用的中文字体" : "字体可用")
        let usage = engine.usage
        for (agent, label) in [("claude", "Claude 额度数据"), ("codex", "Codex 额度数据")] {
            let reading = usage?[agent] ?? AgentUsage()
            if !reading.windows.isEmpty {
                add(label, true, "\(ago(now - reading.observedAt))前的读数")
            } else if reading.observedAt != 0 {
                add(label, nil, "本机最近一次读数是 \(ago(now - reading.observedAt))前的，太旧，不显示")
            } else if agent == "claude" {
                add(label, nil, UsageReader.claudeBinary() != nil ? "claude 命令行没有给出额度，需要在终端里用 claude auth login 登录过"
                    : "没有找到 claude 命令行，额度靠它读取")
            } else {
                add(label, nil, "本机没有找到读数")
            }
        }
        if let last = engine.lastPush {
            // accepted by the service but not on the screen yet: worth a look, not a fault
            add("最近一次刷新", last.ok && last.delivered == false ? nil : last.ok, "\(ago(now - last.at))前，\(last.message)")
        } else {
            add("最近一次刷新", nil, "启动后还没有刷新过")
        }
        return ["results": .array(results)]
    }

    func about() -> JSON {
        let home = Paths.tilde(Paths.home.path)
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return ["version": .string(version), "runtime": .string("macOS \(system.majorVersion).\(system.minorVersion)"),
                "home": .string(home), "config": .string("\(home)/config.json"), "log": .string("\(home)/logs/daemon.log"),
                "backups": .string("\(home)/backups"), "port": JSON(port), "device_id": .string(engine.settings.deviceID),
                "uninstall": "点菜单栏里的图标，选「卸载…」。它会移除钩子和开机自启，并恢复设备的循环间隔；之后把 App 拖进废纸篓即可。"]
    }

    // MARK: - requests

    private func json(_ payload: JSON, _ status: Int = 200) -> Response {
        Response(status: status, contentType: "application/json; charset=utf-8", body: Data(payload.compact.utf8))
    }

    private func guardRequest(_ request: Request, api: Bool, changing: Bool) throws {
        let origins = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
        guard origins.contains("http://\(request.headers["host"] ?? "")") else { throw Problem("这个页面只能通过本机地址打开", 403) }
        if api {
            let given = Array((request.headers["x-board-token"] ?? "").utf8), wanted = Array(token.utf8)
            // compared without stopping at the first difference
            let same = given.count == wanted.count && zip(given, wanted).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
            guard same else { throw Problem("页面已过期，请刷新", 403) }
        }
        if changing, !origins.contains(request.headers["origin"] ?? "") { throw Problem("来源不对", 403) }
    }

    private func get(_ request: Request) throws -> Response {
        let path = String(request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let web = Resources.directory.appendingPathComponent("web")
        if path == "/" {
            try guardRequest(request, api: false, changing: false)
            let page = try String(contentsOf: web.appendingPathComponent("index.html"), encoding: .utf8)
                .replacingOccurrences(of: "{{TOKEN}}", with: token).replacingOccurrences(of: "{{VERSION}}", with: version)
            return Response(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8), extra: [
                ("Content-Security-Policy", "default-src 'self'; img-src 'self' blob:; style-src 'self' 'unsafe-inline'"),
                ("Referrer-Policy", "no-referrer"),
            ])
        }
        if path.hasPrefix("/static/"), let type = Console.staticFiles[String(path.dropFirst(8))] {
            try guardRequest(request, api: false, changing: false)
            return Response(status: 200, contentType: type, body: try Data(contentsOf: web.appendingPathComponent(String(path.dropFirst(8)))))
        }
        if path == "/api/frame.png" {  // an <img> cannot send the token; the frame is not sensitive to this origin
            try guardRequest(request, api: false, changing: false)
            return Response(status: 200, contentType: "image/png", body: engine.framePNG())
        }
        let pages: [String: () -> JSON] = ["/api/overview": overview, "/api/settings": settings, "/api/device": device, "/api/setup": setup,
                                           "/api/integrations": integrations, "/api/log": logTail, "/api/about": about]
        guard let page = pages[path] else { throw Problem("没有这个页面", 404) }
        try guardRequest(request, api: true, changing: false)
        return json(page())
    }

    private func post(_ request: Request) throws -> Response {
        let path = String(request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let actions: [String: (JSON) throws -> JSON] = [
            "/api/settings": saveSettings, "/api/device": saveDevice, "/api/setup": saveSetup, "/api/integrations": saveIntegration,
            "/api/check": { _ in self.runChecks() },
            "/api/refresh": { _ in self.engine.forceRefresh(); return ["ok": true] },
            "/api/test-frame": { _ in self.engine.showTestFrame(); return ["ok": true] },
            "/api/restart": { _ in
                Log.info("restart requested from the settings page")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.restart() }
                return ["ok": true]
            },
        ]
        guard path == "/api/preview" || actions[path] != nil else { throw Problem("没有这个接口", 404) }
        try guardRequest(request, api: true, changing: true)
        guard request.body.count <= Console.maxBody else { throw Problem("请求太大", 413) }
        guard let body = try? JSON(parsing: request.body.isEmpty ? Data("{}".utf8) : request.body) else { throw Problem("请求不是合法的 JSON") }
        guard body.object != nil else { throw Problem("请求格式不对") }
        if path == "/api/preview" { return Response(status: 200, contentType: "image/png", body: try preview(body)) }
        return json(try actions[path]!(body))
    }

    /// Answer one request. The socket code below only moves bytes; everything else is here.
    public func respond(to request: Request) -> Response {
        do {
            switch request.method {
            case "GET": return try get(request)
            case "POST": return try post(request)
            default: throw Problem("不支持这种请求", 405)
            }
        } catch let problem as Problem {
            return json(["error": .string(problem.message)], problem.status)
        } catch {
            Log.error("settings page request failed: \(request.path): \(describe(error))")
            return json(["error": .string("内部错误：\(describe(error))")], 500)
        }
    }

    // MARK: - the socket

    /// Listen on 127.0.0.1. False when the port cannot be had; the board works without the page.
    @discardableResult
    public func start(port wanted: Int) -> Bool {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(wanted).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard listener >= 0, bound == 0, listen(listener, 64) == 0 else {
            Log.warning("settings page unavailable on port \(wanted): \(String(cString: strerror(errno)))")
            if listener >= 0 { close(listener) }
            listener = -1
            return false
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &length) } }
        port = Int(in_port_t(bigEndian: actual.sin_port))
        let thread = Thread { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return
                }
                DispatchQueue.global().async { self.serve(connection) }
            }
        }
        thread.name = "web"
        thread.start()
        Log.info("settings page at \(page)")
        return true
    }

    public func stop() {
        if listener >= 0 { close(listener) }
        listener = -1
    }

    private static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                                  413: "Payload Too Large", 500: "Internal Server Error", 502: "Bad Gateway"]

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var wait = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        func more() -> Bool {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count > 0 { received.append(contentsOf: buffer[0..<count]) }
            return count > 0
        }
        let blank = Data("\r\n\r\n".utf8)
        var headEnd = received.range(of: blank)
        while headEnd == nil && received.count < 65536 {
            if !more() { return }
            headEnd = received.range(of: blank)
        }
        guard let headEnd = headEnd else { return }
        let lines = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        var response: Response
        if length < 0 || length > Console.maxBody {
            response = json(["error": "请求太大"], 413)
        } else {
            while received.count < headEnd.upperBound + length { if !more() { return } }
            let body = received.subdata(in: headEnd.upperBound..<(headEnd.upperBound + length))
            response = respond(to: Request(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
        }
        var head = "HTTP/1.1 \(response.status) \(Console.reasons[response.status] ?? "OK")\r\n"
        let fields = [("Content-Type", response.contentType), ("Content-Length", String(response.body.count)), ("Cache-Control", "no-store"),
                      ("X-Content-Type-Options", "nosniff"), ("Connection", "close")] + response.extra
        for (name, value) in fields { head += "\(name): \(value)\r\n" }
        var out = Data((head + "\r\n").utf8)
        out.append(response.body)
        out.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = send(connection, bytes.baseAddress! + sent, bytes.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
