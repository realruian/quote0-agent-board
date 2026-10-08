// Agent 状态牌: the Quote/0 agent status board as a Mac app.
//
// The app is in the Dock and has one window, which holds the settings (see UI/). The
// board itself works in the background, so there is also an icon in the menu bar,
// which can be turned off: it says whether the board is healthy and how many
// conversations are waiting, and its menu shows the frame on the screen and each
// conversation's state. Closing the window leaves the board running; quitting the
// app turns it off. The Dock icon can be set to go when the window closes, which
// leaves the app in the menu bar alone: one of the two icons is always there.

import AppKit
import BoardCore

/// Stands for the board's own mark where a symbol is named; `boardMark` draws it.
let boardSymbol = "board"
let maxMenuRows = 8

/// The mark in the middle of the app's icon, for the menu bar: the device's screen as one solid
/// shape with the saw-edged disc of the Dot. app cut out of it. The proportions are those of
/// scripts/make_app_icon.py, where the screen is 560 by 380.
func boardMark(width: CGFloat) -> NSImage {
    let unit = width / 560
    let image = NSImage(size: NSSize(width: width, height: (380 * unit).rounded(.up)), flipped: false) { bounds in
        let screen = NSRect(x: 0, y: (bounds.height - 380 * unit) / 2, width: width, height: 380 * unit)
        let shape = NSBezierPath(roundedRect: screen, xRadius: 84 * unit, yRadius: 84 * unit)
        let teeth = 12
        // At this size the teeth are cut a little deeper than on the icon, or they close up into a plain circle.
        for i in 0..<(teeth * 2) {
            let radius = 122 * unit * (i % 2 == 0 ? 1 : 0.8)
            let angle = (7 + CGFloat(i) * 180 / CGFloat(teeth)) * .pi / 180
            let point = NSPoint(x: screen.midX + radius * cos(angle), y: screen.midY + radius * sin(angle))
            if i == 0 { shape.move(to: point) } else { shape.line(to: point) }
        }
        shape.close()
        shape.windingRule = .evenOdd
        NSColor.black.setFill()
        shape.fill()
        return true
    }
    image.isTemplate = true
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: Engine!
    private var console: Console!
    private var hooks: HookSocket!
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var model: BoardModel!
    private var window: SettingsWindow!
    private var saidFarewell = false
    private var menuBarIcon: NSKeyValueObservation?
    /// The setting, kept by macOS with the app's other preferences: leave the Dock when the window closes.
    private static let leavesDock = "leavesDockWhenClosed"
    private static let showWindow = Notification.Name("com.quote0.agent-board.show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let reason = Install.misplaced() {
            alert("还不能从这里打开", reason)
            exit(0)
        }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "-")
        where other != NSRunningApplication.current {
            if other.bundleURL == Bundle.main.bundleURL {
                // already running: opening it again asks for its window
                DistributedNotificationCenter.default().postNotificationName(AppDelegate.showWindow, object: nil, deliverImmediately: true)
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
        model = BoardModel(engine: engine, console: console)
        model.uninstall = { [weak self] in self?.uninstall() }
        window = SettingsWindow(model: model)
        window.onClose = { [weak self] in self?.settleDock() }
        engine.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.draw()
                self?.model.refresh()
            }
        }
        engine.start()
        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.showWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        // The menu bar icon is optional now that the app is in the Dock. macOS remembers whether it is shown.
        statusItem.autosaveName = "board"
        statusItem.behavior = .removalAllowed
        // The app has to be somewhere: when the menu bar icon goes, from the menu or dragged out of the bar, the Dock icon stays.
        menuBarIcon = statusItem.observe(\.isVisible, options: [.initial]) { [weak self] item, _ in
            if !item.isVisible { UserDefaults.standard.set(false, forKey: AppDelegate.leavesDock) }
            self?.settleDock()
        }
        NSApp.mainMenu = mainMenu()
        // Opened by hand rather than at login: show the window, as opening an app should.
        let snapshot = Paths.isDevelopment && environment["AGENT_BOARD_SNAPSHOT"] != nil
        if snapshot {
            window.show(Page(rawValue: environment["AGENT_BOARD_PAGE"] ?? "") ?? .overview)
        } else if !Install.startedByLaunchd && !Paths.isDevelopment {
            openSettings()
        }
        draw()
    }

    /// A click on the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting from the menu, the Dock or at logout all pass through here. The screen keeps
    /// its last frame once nothing updates it, so it is told the board is off first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if saidFarewell { return .terminateNow }
        saidFarewell = true
        statusItem.button?.appearsDisabled = true
        DispatchQueue.global().async { [self] in
            engine.sayFarewell()
            hooks.stop()
            Log.info("stopped")
            Log.flush()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// What a Mac app has along the top of the screen. Copy and paste live here: without
    /// them an API key could not be pasted into the window.
    private func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let holder = NSMenuItem()
            holder.submenu = NSMenu(title: title)
            items.forEach { holder.submenu?.addItem($0) }
            return holder
        }
        let bar = NSMenu()
        bar.addItem(menu("Agent 状态牌", [
            item("设置…", #selector(openSettings), ",", target: self), .separator(),
            item("刷新屏幕", #selector(refreshScreen), "r", target: self),
            item("暂停", #selector(togglePause), target: self), .separator(),
            item("在菜单栏显示图标", #selector(toggleMenuBarIcon), target: self),
            item("关闭窗口后保留程序坞图标", #selector(toggleDockIcon), target: self),
            item("卸载…", Paths.isDevelopment ? nil : #selector(uninstall), target: self), .separator(),
            item("隐藏 Agent 状态牌", #selector(NSApplication.hide(_:)), "h"), .separator(),
            item("退出 Agent 状态牌", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        bar.addItem(menu("编辑", [
            item("撤销", Selector(("undo:")), "z"), item("重做", Selector(("redo:")), "Z"), .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"), item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"), item("全选", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = menu("窗口", [item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"), item("关闭", #selector(NSWindow.performClose(_:)), "w")])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu
        return bar
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
    /// when there is something to say.
    private func statusIcon(badge: String?) -> NSImage {
        let base = boardMark(width: 20)
        guard let badge = badge, let mark = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .black)) else { return base }
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
        image.accessibilityDescription = "Agent 状态牌"
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
        button.image = statusIcon(badge: badge)
        button.imagePosition = .imageLeading
        // How many conversations are waiting for the user: the thing the board exists to say.
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.toolTip = "Agent 状态牌：\(line)"
        // The same count on the Dock icon, when it is there.
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
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

        add(now.needsSetup ? "连接设备…" : "打开设置…", #selector(openSettings))
        if !now.needsSetup {
            add("刷新屏幕", #selector(refreshScreen))
            add(now.paused ? "恢复" : "暂停", #selector(togglePause))
        }
        menu.addItem(.separator())
        add("隐藏菜单栏图标", #selector(toggleMenuBarIcon))
        add("关闭窗口后保留程序坞图标", #selector(toggleDockIcon))
        menu.items.last?.state = UserDefaults.standard.bool(forKey: AppDelegate.leavesDock) ? .off : .on
        if !Paths.isDevelopment { add("卸载…", #selector(uninstall)) }
        add("退出", #selector(quit), key: "q")
    }

    /// A right click on the Dock icon: how the board is doing, and the two things done most often.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let now = snapshot()
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != nil
            menu.addItem(item)
        }
        add(status(now).line, nil)
        if !now.needsSetup {
            add("刷新屏幕", #selector(refreshScreen))
            add(now.paused ? "恢复" : "暂停", #selector(togglePause))
        }
        return menu
    }

    /// A row without an action is a caption: it shows greyed and cannot be chosen.
    private func add(_ title: String, _ action: Selector? = nil, key: String = "", symbol: String? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        if let symbol = symbol { item.image = symbol == boardSymbol ? boardMark(width: 17) : NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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
        let needsSetup = engine.locked { !engine.dryRun && !engine.settings.ready }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }  // a window on screen has its app in the Dock
        window.show(needsSetup ? .setup : nil)
    }

    /// Put the app in the Dock or take it out, as the setting and the window have it.
    private func settleDock() {
        guard ProcessInfo.processInfo.environment["AGENT_BOARD_SNAPSHOT"] == nil else { return }
        let leaves = UserDefaults.standard.bool(forKey: AppDelegate.leavesDock) && !window.isOpen
        let wanted: NSApplication.ActivationPolicy = leaves ? .accessory : .regular
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    @objc private func refreshScreen() {
        engine.forceRefresh()
    }

    @objc private func togglePause() {
        let paused = engine.settings.paused
        _ = try? engine.applyConfig(["paused": .bool(!paused)])
    }

    @objc private func toggleMenuBarIcon() {
        statusItem.isVisible.toggle()
    }

    @objc private func toggleDockIcon() {
        let leaves = !UserDefaults.standard.bool(forKey: AppDelegate.leavesDock)
        if leaves { statusItem.isVisible = true }  // out of the Dock, the menu bar is the way back in
        UserDefaults.standard.set(leaves, forKey: AppDelegate.leavesDock)
        settleDock()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func uninstall() {
        let text = "会断开 Claude Code 和 Codex、取消开机自启，并把设备的循环间隔恢复原样。设置和日志会保留。"
        guard alert("卸载 Agent 状态牌？", text, buttons: ["卸载", "取消"]) == 0 else { return }
        statusItem.button?.appearsDisabled = true
        saidFarewell = true
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

/// The menus along the top of the screen ask before they open what each row should say.
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let (paused, needsSetup) = engine.locked { (engine.settings.paused, !engine.dryRun && !engine.settings.ready) }
        switch item.action {
        case #selector(togglePause):
            item.title = paused ? "恢复" : "暂停"
            return !needsSetup
        case #selector(refreshScreen): return !needsSetup
        case #selector(toggleMenuBarIcon): item.state = statusItem.isVisible ? .on : .off
        case #selector(toggleDockIcon): item.state = UserDefaults.standard.bool(forKey: AppDelegate.leavesDock) ? .off : .on
        default: break
        }
        return true
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
// In the Dock like any app. A development copy taking a picture of its own page stays out of it, and so
// does an app set to leave the Dock, until its window opens.
let outOfDock = ProcessInfo.processInfo.environment["AGENT_BOARD_SNAPSHOT"] != nil || UserDefaults.standard.bool(forKey: "leavesDockWhenClosed")
NSApplication.shared.setActivationPolicy(outOfDock ? .accessory : .regular)
NSApplication.shared.run()
