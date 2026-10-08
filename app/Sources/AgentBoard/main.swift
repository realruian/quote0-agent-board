// Agent 状态牌: the Quote/0 agent status board as a menu bar app.
//
// The board itself has nothing to look at on the Mac, so the app lives in the menu
// bar: the icon says whether the board is healthy and how many conversations are
// waiting, and its menu shows the frame on the screen and each conversation's state.
// Quitting turns the board off; opening the app turns it on.

import AppKit
import BoardCore

let boardSymbol = "list.bullet.rectangle"
let maxMenuRows = 8

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: Engine!
    private var console: Console!
    private var hooks: HookSocket!
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let reason = Install.misplaced() {
            alert("还不能从这里打开", reason)
            exit(0)
        }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "-")
        where other != NSRunningApplication.current {
            if other.bundleURL == Bundle.main.bundleURL {
                // already in the menu bar: opening it again asks for the settings
                if let page = URL(string: "http://127.0.0.1:\(ConfigStore.load().webPort)/") { NSWorkspace.shared.open(page) }
                exit(0)
            }
            // A copy somewhere else, such as the version this one replaces: only one can have the menu bar.
            other.terminate()
            for _ in 0..<50 where !other.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
        }
        if !Paths.isDevelopment { Install.ensure() }

        let environment = ProcessInfo.processInfo.environment
        engine = Engine(dryRun: !(environment["AGENT_BOARD_DRY_RUN"] ?? "").isEmpty)
        hooks = HookSocket { [engine] source, event, payload in engine?.onEvent(source, event, payload) }
        do {
            try hooks.start()
        } catch {
            Log.error("cannot listen for hook events at \(Paths.socket.path): \(describe(error))")
        }
        console = Console(engine: engine)
        console.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        console.restart = { Install.relaunch() }
        console.start(port: Int(environment["AGENT_BOARD_PORT"] ?? "") ?? engine.settings.webPort)
        engine.onChange = { [weak self] in DispatchQueue.main.async { self?.draw() } }
        engine.start()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        // Opened by hand rather than at login: show the settings, since opening an app should show something.
        if !Install.startedByLaunchd && !Paths.isDevelopment { openSettings() }
        draw()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String] = ["好"]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    // MARK: what the board says

    private struct Snapshot {
        var sessions: [Session] = []
        var aliases: [String: String] = [:]
        var lastPush: Engine.LastPush?
        var quiet = false
        var paused = false
        var needsSetup = false
        var dryRun = false
    }

    private func snapshot() -> Snapshot {
        engine.locked {
            let settings = engine.settings
            let hidden = Set(settings.hiddenProjects)  // hidden projects are kept off the screen, and off here
            return Snapshot(sessions: engine.board.visible().filter { !hidden.contains($0.project) }, aliases: settings.aliases,
                            lastPush: engine.lastPush, quiet: engine.currentView().kind == .quiet, paused: settings.paused,
                            needsSetup: !engine.dryRun && !settings.ready, dryRun: engine.dryRun)
        }
    }

    /// The one line that says how the board is doing, the worst thing first, with the
    /// symbol that goes beside it in the menu and the badge that goes on the icon.
    private func status(_ now: Snapshot) -> (symbol: String, badge: String?, line: String) {
        if now.needsSetup { return ("ellipsis.rectangle", "ellipsis", "还没有连接设备") }
        if now.paused { return ("pause.rectangle", "pause.fill", "已暂停，屏幕不再更新") }
        if now.dryRun { return (boardSymbol, nil, "空跑模式，画面不会发到屏幕上") }
        guard let push = now.lastPush else { return (boardSymbol, nil, "还没有刷新过屏幕") }
        if !push.ok { return ("exclamationmark.triangle", "exclamationmark", "最近一次刷新失败：\(push.message)") }
        if push.delivered == false { return ("moon.zzz", "moon.fill", "设备休眠或离线，最新画面还没显示") }
        if now.quiet { return (boardSymbol, nil, "夜间免打扰中，屏幕暂不刷新") }
        return (boardSymbol, nil, "屏幕已是最新 · \(ago(push.at))刷新")
    }

    /// The board's own mark, the same in every state so it can be found, with a small badge
    /// when there is something to say. Solid when a conversation is waiting.
    private func statusIcon(badge: String?, filled: Bool) -> NSImage? {
        let face = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: filled ? boardSymbol + ".fill" : boardSymbol, accessibilityDescription: "Agent 状态牌")?
            .withSymbolConfiguration(face) else { return nil }
        guard let badge = badge, let mark = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .black)) else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 5, height: base.size.height + 3)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(at: NSPoint(x: 0, y: 3), from: .zero, operation: .sourceOver, fraction: 1)
            let spot = NSRect(x: size.width - mark.size.width - 1, y: 0, width: mark.size.width, height: mark.size.height)
            NSGraphicsContext.current?.compositingOperation = .clear  // a gap around the badge, so it reads apart from the board
            NSBezierPath(ovalIn: spot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            mark.draw(in: spot)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func ago(_ at: Double) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970 - at))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }

    private func draw() {
        guard let button = statusItem.button else { return }
        let now = snapshot()
        let (_, badge, line) = status(now)
        let waiting = now.sessions.filter { $0.state == .waiting }.count
        button.image = statusIcon(badge: badge, filled: waiting > 0)
        button.imagePosition = .imageLeading
        // How many conversations are waiting for the user: the thing the board exists to say.
        button.title = waiting > 0 ? " \(waiting)" : (button.image == nil ? "状态牌" : "")
        button.toolTip = "Agent 状态牌：\(line)"
    }

    // MARK: the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = snapshot()
        let (symbol, _, line) = status(now)
        if !now.needsSetup, let frame = NSImage(data: engine.framePNG()) { menu.addItem(frameItem(frame)) }
        add(line, symbol: symbol)
        menu.addItem(.separator())

        if now.sessions.isEmpty { add("现在没有对话") }
        for session in now.sessions.prefix(maxMenuRows) {
            add(rowTitle(session, now.aliases), #selector(openSettings), symbol: rowSymbol(session))
        }
        if now.sessions.count > maxMenuRows { add("还有 \(now.sessions.count - maxMenuRows) 个") }
        menu.addItem(.separator())

        add(now.needsSetup ? "连接设备…" : "打开设置…", console.port == 0 ? nil : #selector(openSettings), key: ",")
        if console.port == 0 { add("设置页打不开：端口 \(engine.settings.webPort) 被别的程序占用") }
        if !now.needsSetup {
            add("刷新屏幕", #selector(refreshScreen))
            add(now.paused ? "恢复" : "暂停", #selector(togglePause))
        }
        menu.addItem(.separator())
        if !Paths.isDevelopment { add("卸载…", #selector(uninstall)) }
        add("退出", #selector(quit), key: "q")
    }

    /// A row without an action is a caption: it shows greyed and cannot be chosen.
    private func add(_ title: String, _ action: Selector? = nil, key: String = "", symbol: String? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        if let symbol = symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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

    private func rowTitle(_ session: Session, _ aliases: [String: String]) -> String {
        var name = [session.name, session.title, aliases[session.project] ?? ""].first { !$0.isEmpty } ?? session.project
        if name.count > 24 { name = name.prefix(23) + "…" }
        let state: String
        switch session.state {
        case .waiting: state = ["permission": "等你批准", "question": "等你回答", "plan": "等你看计划"][session.waitKind] ?? "等你处理"
        case .running: state = "运行中"
        case .error: state = "出错"
        default: state = "已完成"
        }
        return "\(name) · \(state)"
    }

    private func rowSymbol(_ session: Session) -> String {
        switch session.state {
        case .waiting: return "hand.raised.fill"
        case .running: return "ellipsis.circle"
        case .error: return "xmark.circle"
        default: return "checkmark.circle"
        }
    }

    // MARK: what the menu can do

    /// Until a device is connected the settings have nothing to show, so they open on connecting one.
    @objc private func openSettings() {
        guard console.port != 0 else { return }
        let needsSetup = engine.locked { !engine.dryRun && !engine.settings.ready }
        if let page = URL(string: "\(console.page)/#\(needsSetup ? "setup" : "")") { NSWorkspace.shared.open(page) }
    }

    @objc private func refreshScreen() {
        engine.forceRefresh()
    }

    @objc private func togglePause() {
        let paused = engine.settings.paused
        _ = try? engine.applyConfig(["paused": .bool(!paused)])
    }

    @objc private func quit() {
        statusItem.button?.appearsDisabled = true
        DispatchQueue.global().async { [self] in
            engine.sayFarewell()  // the screen keeps its last frame once nothing updates it, so it says goodbye first
            hooks.stop()
            Log.info("stopped")
            Log.flush()
            exit(0)
        }
    }

    @objc private func uninstall() {
        let text = "会断开 Claude Code 和 Codex、取消开机自启，并把设备的循环间隔恢复原样。设置和日志会保留。"
        guard alert("卸载 Agent 状态牌？", text, buttons: ["卸载", "取消"]) == 0 else { return }
        statusItem.button?.appearsDisabled = true
        DispatchQueue.global().async { [self] in
            engine.sayFarewell()
            hooks.stop()
            Install.remove(console: console)
            DispatchQueue.main.async {
                self.alert("已卸载", "现在可以把「Agent 状态牌」拖进废纸篓。")
                Install.launchctl("bootout", "\(Install.domain)/\(Install.label)")  // ends this process when launchd started it
                exit(0)
            }
        }
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
