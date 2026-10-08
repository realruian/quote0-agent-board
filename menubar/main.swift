// Menu bar app for the Quote/0 agent status board.
//
// The board itself is a background process with nothing to look at on the Mac.
// This puts an icon in the menu bar that says whether the board is healthy, shows
// what is on the screen and which conversations are open, and turns the board on
// and off: quitting here stops the background process, opening the app starts it.
//
// It only talks to the daemon's local console (agent_board/web.py). install.py
// compiles it on the user's own machine, so it needs no developer signature.

import AppKit

let daemonLabel = "com.quote0.agent-board"
let menubarLabel = daemonLabel + ".menubar"
let environment = ProcessInfo.processInfo.environment
// Set for a development instance, which launchd does not manage.
let developmentHome = environment["AGENT_BOARD_HOME"]
let boardHome = URL(fileURLWithPath: developmentHome ?? NSHomeDirectory() + "/.quote0-agent-board")

let boardSymbol = "list.bullet.rectangle"
let maxRows = 8

/// What `/api/overview` answers with; only the fields used here.
struct Overview: Decodable {
    struct Session: Decodable {
        let project: String
        let alias: String?
        let title: String?
        let state: String
        let wait_kind: String?
        let hidden: Bool?
    }

    struct Push: Decodable {
        let at: Double?
        let ok: Bool?
        let message: String?
        let delivered: Bool?
    }

    let dry_run: Bool
    let view_kind: String
    let paused: Bool
    let sessions: [Session]
    let last_push: Push
}

@discardableResult
func launchctl(_ arguments: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Has launchd run the daemon if it is not already; `restart` also replaces one that is running.
func startDaemon(restart: Bool = false) {
    let domain = "gui/\(getuid())"
    if launchctl("print", "\(domain)/\(daemonLabel)") != 0 {
        launchctl("bootstrap", domain, NSHomeDirectory() + "/Library/LaunchAgents/\(daemonLabel).plist")
    } else if restart {
        launchctl("kickstart", "-k", "\(domain)/\(daemonLabel)")
    }
}

/// The daemon's local console. The daemon writes where it listens, and the token
/// it wants, into a file that only this user can read.
final class Console {
    private struct Address: Decodable {
        let port: Int
        let token: String
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // a system proxy has no business with 127.0.0.1
        return URLSession(configuration: configuration)
    }()

    private var address: Address? {
        guard let data = try? Data(contentsOf: boardHome.appendingPathComponent("run/console.json")) else { return nil }
        return try? JSONDecoder().decode(Address.self, from: data)
    }

    var page: URL? {
        address.flatMap { URL(string: "http://127.0.0.1:\($0.port)/") }
    }

    /// Calls back on the main thread with the reply's body, or nil when the daemon did not answer with success.
    func request(_ path: String, post body: [String: Any]? = nil, timeout: TimeInterval = 4, then: @escaping (Data?) -> Void) {
        guard let address = address, let url = URL(string: "http://127.0.0.1:\(address.port)\(path)") else {
            DispatchQueue.main.async { then(nil) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(address.token, forHTTPHeaderField: "X-Board-Token")
        if let body = body {
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("http://127.0.0.1:\(address.port)", forHTTPHeaderField: "Origin")
        }
        session.dataTask(with: request) { data, response, _ in
            let succeeded = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { then(succeeded ? data : nil) }
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let console = Console()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var overview: Overview?
    private var misses = 0  // polls in a row the daemon has not answered
    private var frame: NSImage?
    private var frameAt: Double?
    private var openSettingsWhenReady = false

    /// The last answer, unless the daemon has stopped answering since.
    private var live: Overview? { misses < 2 ? overview : nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundle = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: { $0 != NSRunningApplication.current }) {
            openSettings()  // already in the menu bar: opening it again asks for the settings
            NSApp.terminate(nil)
            return
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if developmentHome == nil {
            startDaemon()
        }
        // Opened by hand rather than at login: show the settings, since opening an app should show something.
        openSettingsWhenReady = environment["XPC_SERVICE_NAME"] != menubarLabel
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        draw()
        poll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // -- what the daemon says ------------------------------------------------

    private func poll() {
        console.request("/api/overview") { [weak self] data in
            guard let self = self else { return }
            if let data = data, let overview = try? JSONDecoder().decode(Overview.self, from: data) {
                self.overview = overview
                self.misses = 0
                if self.openSettingsWhenReady {
                    self.openSettingsWhenReady = false
                    self.openSettings()
                }
                if self.frame == nil || overview.last_push.at != self.frameAt {
                    self.loadFrame(pushedAt: overview.last_push.at)
                }
            } else {
                self.misses += 1
            }
            self.draw()
        }
    }

    private func loadFrame(pushedAt: Double?) {
        console.request("/api/frame.png") { [weak self] data in
            guard let self = self, let image = data.flatMap(NSImage.init(data:)) else { return }
            self.frame = image
            self.frameAt = pushedAt
        }
    }

    /// The icon and the one line that say how the board is doing, the worst thing first.
    private func status() -> (symbol: String, line: String) {
        guard let overview = live else {
            return misses < 2 ? (boardSymbol, "正在连接后台进程…") : ("exclamationmark.triangle", "连不上后台进程")
        }
        let push = overview.last_push
        if overview.paused {
            return ("pause.rectangle", "已暂停，屏幕不再更新")
        }
        if overview.dry_run {
            return (boardSymbol, "空跑模式，画面不会发到屏幕上")
        }
        if push.at != nil && push.ok != true {
            return ("exclamationmark.triangle", "最近一次刷新失败：\(push.message ?? "原因不明")")
        }
        if push.ok == true && push.delivered == false {
            return ("moon.zzz", "设备休眠或离线，最新画面还没显示")
        }
        if overview.view_kind == "quiet" {
            return (boardSymbol, "夜间免打扰中，屏幕暂不刷新")
        }
        guard let at = push.at else {
            return (boardSymbol, "还没有刷新过屏幕")
        }
        return (boardSymbol, "屏幕已是最新 · \(ago(at))刷新")
    }

    private func ago(_ at: Double) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970 - at))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }

    private func shown(_ overview: Overview) -> [Overview.Session] {
        overview.sessions.filter { $0.hidden != true }  // hidden projects are kept off the screen, and off here
    }

    private func draw() {
        guard let button = statusItem.button else { return }
        let (symbol, line) = status()
        let waiting = live.map { shown($0).filter { $0.state == "waiting" }.count } ?? 0
        let name = waiting > 0 && symbol == boardSymbol ? boardSymbol + ".fill" : symbol
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Agent 状态牌")
        button.imagePosition = .imageLeading
        // How many conversations are waiting for the user: the thing the board exists to say.
        button.title = waiting > 0 ? " \(waiting)" : (button.image == nil ? "状态牌" : "")
        button.toolTip = "Agent 状态牌：\(line)"
    }

    // -- the menu ------------------------------------------------------------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (symbol, line) = status()
        if let frame = frame, live != nil {
            menu.addItem(frameItem(frame))
        }
        add(line, symbol: symbol)
        menu.addItem(.separator())

        if let overview = live {
            let sessions = shown(overview)
            if sessions.isEmpty {
                add("现在没有对话")
            }
            for session in sessions.prefix(maxRows) {
                add(rowTitle(session), #selector(openSettings), symbol: rowSymbol(session))
            }
            if sessions.count > maxRows {
                add("还有 \(sessions.count - maxRows) 个")
            }
            menu.addItem(.separator())
        }

        add("打开设置…", console.page == nil ? nil : #selector(openSettings), key: ",")
        if let overview = live {
            add("刷新屏幕", #selector(refreshScreen))
            add(overview.paused ? "恢复" : "暂停", #selector(togglePause))
        } else if misses >= 2 && developmentHome == nil {
            add("重新启动后台进程", #selector(restartDaemon))
        }
        menu.addItem(.separator())
        add("退出", #selector(quit), key: "q")
    }

    /// A row without an action is a caption: it shows greyed and cannot be chosen.
    private func add(_ title: String, _ action: Selector? = nil, key: String = "", symbol: String? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        if let symbol = symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }

    /// The frame as the screen shows it: one image pixel to one point, kept sharp.
    private func frameItem(_ frame: NSImage) -> NSMenuItem {
        let margin: CGFloat = 14
        let picture = NSView(frame: NSRect(x: margin, y: 4, width: frame.size.width, height: frame.size.height))
        picture.wantsLayer = true
        picture.layer?.contents = frame
        picture.layer?.magnificationFilter = .nearest
        picture.layer?.cornerRadius = 5
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 1
        picture.layer?.borderColor = NSColor.gray.withAlphaComponent(0.5).cgColor
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: frame.size.width + 2 * margin, height: frame.size.height + 8))
        holder.addSubview(picture)
        let item = NSMenuItem()
        item.view = holder
        return item
    }

    private func rowTitle(_ session: Overview.Session) -> String {
        var name = [session.title, session.alias].compactMap { $0 }.first { !$0.isEmpty } ?? session.project
        if name.count > 24 {
            name = name.prefix(23) + "…"
        }
        let state: String
        switch session.state {
        case "waiting":
            state = ["permission": "等你批准", "question": "等你回答", "plan": "等你看计划"][session.wait_kind ?? ""] ?? "等你处理"
        case "running":
            state = "运行中"
        case "error":
            state = "出错"
        default:
            state = "已完成"
        }
        return "\(name) · \(state)"
    }

    private func rowSymbol(_ session: Overview.Session) -> String {
        switch session.state {
        case "waiting": return "hand.raised.fill"
        case "running": return "ellipsis.circle"
        case "error": return "xmark.circle"
        default: return "checkmark.circle"
        }
    }

    // -- what the menu can do ------------------------------------------------

    @objc private func openSettings() {
        if let page = console.page {
            NSWorkspace.shared.open(page)
        }
    }

    @objc private func refreshScreen() {
        console.request("/api/refresh", post: [:]) { _ in }
    }

    @objc private func togglePause() {
        guard let paused = live?.paused else { return }
        console.request("/api/settings", post: ["paused": !paused]) { [weak self] _ in self?.poll() }
    }

    @objc private func restartDaemon() {
        startDaemon(restart: true)
    }

    @objc private func quit() {
        statusItem.button?.appearsDisabled = true
        // The screen keeps its last frame once nothing updates it, so the daemon says goodbye on it first.
        console.request("/api/farewell", post: [:], timeout: 12) { _ in
            if developmentHome == nil {
                launchctl("bootout", "gui/\(getuid())/\(daemonLabel)")
            }
            NSApp.terminate(nil)
        }
    }
}

if CommandLine.arguments.contains("--quit") {
    // install.py asks this before it replaces or removes the app: stop the copy that is running, however it was started.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: menubarLabel).filter { $0 != .current }
    running.forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
