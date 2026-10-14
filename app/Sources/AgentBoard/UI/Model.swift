// What the window shows, kept up to date from the board, and what it can ask the
// board to do. Anything that talks to the device runs off the main thread.

import AppKit
import BoardCore
import SwiftUI

/// The board's settings; SwiftUI has a `Settings` of its own.
typealias BoardSettings = BoardCore.Settings

enum Page: String, CaseIterable, Identifiable {
    case overview, display, alerts, conversations, usage, refresh, device, diagnostics, about, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .display: return "画面"
        case .alerts: return "提醒"
        case .conversations: return "对话"
        case .usage: return "用量"
        case .refresh: return "刷新"
        case .device: return "设备"
        case .diagnostics: return "诊断"
        case .about: return "关于"
        case .setup: return "连接设备"
        }
    }

    /// What the page is for, in a line under its name.
    var summary: String {
        switch self {
        case .overview: return "屏幕上现在是什么，各个 Agent 在做什么"
        case .display: return "屏幕长什么样：字体、名称、行数"
        case .alerts: return "哪些情况占用整块屏幕来提醒你"
        case .conversations: return "显示哪些 Agent、哪些项目的对话，显示多久"
        case .usage: return "Claude 和 Codex 还剩多少额度，要不要显示在屏幕上"
        case .refresh: return "屏幕什么时候更新，什么时候不更新"
        case .device: return "正在使用的 Quote/0：状态、供电和休眠"
        case .diagnostics: return "从钩子到屏幕逐项检查，查看日志"
        case .about: return "版本、图标、文件位置和卸载"
        case .setup: return "三步把状态牌连到你的 Quote/0"
        }
    }

    /// Drawn in outline and in one colour, like the screen the board is for.
    var icon: Icon {
        switch self {
        case .overview: return .dashboardSquare01
        case .display: return .listView
        case .alerts: return .notification01
        case .conversations: return .bubbleChat
        case .usage: return .dashboardSpeed01
        case .refresh: return .refresh
        case .device, .setup: return .tabletConnectedWifi
        case .diagnostics: return .pulse01
        case .about: return .informationCircle
        }
    }
}

/// The board at one moment, for the overview.
struct BoardStatus {
    var sessions: [Session] = []
    var lastPush: Engine.LastPush?
    var usage: Usage?
    var screen = Engine.ScreenState.current
    var quiet = false
    var paused = false
    var needsSetup = false
    var dryRun = false
}

struct Notice: Equatable {
    var text: String
    var isError = false
}

final class BoardModel: ObservableObject {
    let engine: Engine
    let console: Console
    var uninstall: () -> Void = {}
    /// Where the app shows itself. The app holds these, not the board; it keeps the two flags up to date.
    var showMenuBarIcon: (Bool) -> Void = { _ in }
    var keepDockIcon: (Bool) -> Void = { _ in }
    @Published var menuBarIcon = true
    @Published var keepsDockIcon = true

    @Published var page: Page? = .overview
    @Published var settings: BoardSettings
    @Published var status = BoardStatus()
    @Published var frame: NSImage?
    @Published var device: JSON?  // nil until the device has answered
    @Published var setup: JSON?
    @Published var integrations: JSON?
    @Published var checks: [JSON]?
    @Published var checking = false
    @Published var log: [String] = []
    @Published var notice: Notice?
    @Published var busy = false  // something that reaches the device is under way

    private var frameAt: Double?
    private var noticeTimer: Timer?

    init(engine: Engine, console: Console) {
        self.engine = engine
        self.console = console
        settings = engine.settings
        refresh()
    }

    /// Cheap, and safe to call often: everything here is already in memory.
    func refresh() {
        let (settings, status): (BoardSettings, BoardStatus) = engine.locked {
            let settings = engine.settings
            return (settings, BoardStatus(sessions: engine.board.visible(), lastPush: engine.lastPush, usage: engine.usage,
                                          screen: engine.screenState(), quiet: engine.currentView().kind == .quiet && !settings.paused, paused: settings.paused,
                                          needsSetup: !engine.dryRun && !settings.ready, dryRun: engine.dryRun))
        }
        self.settings = settings
        self.status = status
        if frame == nil || status.lastPush?.at != frameAt {
            frameAt = status.lastPush?.at
            frame = NSImage(data: engine.framePNG())
        }
    }

    func say(_ text: String, isError: Bool = false) {
        notice = Notice(text: text, isError: isError)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: isError ? 4.5 : 1.8, repeats: false) { [weak self] _ in self?.notice = nil }
    }

    /// Run `work` off the main thread, then `done` on it. What goes wrong is told to the user.
    private func background<T>(_ work: @escaping () throws -> T, done: @escaping (T) -> Void = { _ in }) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let value): done(value)
                case .failure(let error): self.say((error as? Problem)?.message ?? describe(error), isError: true)
                }
                self.refresh()
            }
        }
    }

    // MARK: settings the board holds

    /// Change settings. They are saved and take effect at once.
    func apply(_ patch: JSON, quietly: Bool = false) {
        do {
            _ = try console.saveSettings(patch)
            refresh()
            if !quietly { say(screenLine(saved: true)) }
        } catch {
            say((error as? Problem)?.message ?? describe(error), isError: true)
        }
        refresh()
    }

    func flag(_ key: String, _ value: KeyPath<BoardSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: value] }, set: { self.apply([key: .bool($0)]) })
    }

    /// A frame drawn with the saved settings, changed by `config` where given.
    func preview(sample: String, config: JSON? = nil, done: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let body: JSON = config.map { ["sample": .string(sample), "config": $0] } ?? ["sample": .string(sample)]
            let image = (try? self.console.preview(body)).flatMap(NSImage.init(data:))
            DispatchQueue.main.async { done(image) }
        }
    }

    func refreshScreen() {
        engine.forceRefresh()
        say(status.lastPush?.delivered == false ? "已发出，\(engine.awayReason)，醒来后显示" : "正在刷新屏幕")
    }

    /// What the screen is doing, in a few words; after a change, also that it was saved.
    func screenLine(saved: Bool = false) -> String {
        let prefix = saved ? "已保存，" : ""
        if status.needsSetup { return saved ? "已保存" : "还没有连接设备" }
        if status.dryRun { return saved ? "已保存" : "空跑模式，不发到屏幕" }
        switch status.screen {
        case .current: return saved ? "已保存" : "屏幕已是最新"
        case .failed: return prefix + "刷新失败，稍后自动重试"
        case .waitingForDevice: return prefix + "\(engine.awayReason)，醒来后显示"
        case .sending(let at):
            let wait = Int((at - Date().timeIntervalSince1970).rounded(.up))
            if status.lastPush?.delivered == false { return prefix + "\(engine.awayReason)，醒来后显示" }
            return prefix + (wait <= 3 ? "屏幕马上更新" : "屏幕 \(wait) 秒后更新")
        }
    }

    func sendTestFrame() {
        engine.showTestFrame()
        say("测试画面已发出，15 秒后自动恢复")
    }

    // MARK: what the device holds

    func loadDevice() {
        background({ self.console.device() }) { self.device = $0 }
    }

    func saveDevice(_ patch: JSON, done: String) {
        background({ try self.console.saveDevice(patch) }) {
            self.device = $0
            self.say(done)
        }
    }

    func loadSetup() {
        background({ self.console.setup() }) { self.setup = $0 }
    }

    func saveSetup(_ patch: JSON, done: String) {
        background({ try self.console.saveSetup(patch) }) {
            self.setup = $0
            self.device = nil
            self.say(done)
        }
    }

    // MARK: agents

    func loadIntegrations() {
        integrations = console.integrations()
    }

    func connect(_ agent: String, _ name: String, _ enabled: Bool) {
        do {
            integrations = try console.saveIntegration(["agent": .string(agent), "enabled": .bool(enabled)])
            say(enabled ? "\(name) 已连接" : "\(name) 已断开")
        } catch {
            say((error as? Problem)?.message ?? describe(error), isError: true)
            loadIntegrations()
        }
    }

    // MARK: diagnostics

    func runChecks() {
        checking = true
        background({ self.console.runChecks()["results"]?.array ?? [] }) {
            self.checks = $0
            self.checking = false
        }
    }

    func loadLog() {
        log = (console.logTail()["lines"]?.array ?? []).compactMap(\.string)
    }
}
