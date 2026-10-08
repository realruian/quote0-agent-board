// The heart of the board: receives hook events, keeps the board state, pushes frames.
//
// Everything it holds is guarded by one lock. Three threads do the waiting: the
// pusher sends a frame when one is due, the ticker looks at quota and at the device
// now and then, and the namer picks up conversation names.

import Foundation

public final class Engine {
    public struct LastPush: Codable, Equatable {
        public var at: Double
        public var ok: Bool
        public var kind: String
        public var message: String
        public var delivered: Bool?  // nil when the push failed: there is nothing to deliver

        var json: JSON {
            var object: JSONObject = ["at": JSON(at), "ok": .bool(ok), "kind": .string(kind), "message": .string(message)]
            if let delivered = delivered { object["delivered"] = .bool(delivered) }
            return .object(object)
        }
    }

    private struct StateFile: Codable {
        var board: Board.Saved?
        var lastSig: String?
        var lastPush: LastPush?
        var framed: [String]?

        enum CodingKeys: String, CodingKey {
            case board
            case lastSig = "last_sig"
            case lastPush = "last_push"
            case framed
        }

        init(board: Board.Saved, lastSig: String, lastPush: LastPush?, framed: [String]) {
            self.board = board
            self.lastSig = lastSig
            self.lastPush = lastPush
            self.framed = framed
        }

        init(from decoder: Decoder) throws {
            // Each part on its own: one that cannot be read does not cost the others.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            board = try? container.decode(Board.Saved.self, forKey: .board)
            lastSig = try? container.decode(String.self, forKey: .lastSig)
            lastPush = try? container.decode(LastPush.self, forKey: .lastPush)
            framed = try? container.decode([String].self, forKey: .framed)
        }
    }

    static let coalesceSeconds = 2.0
    static let urgentSeconds = 0.4
    static let retrySeconds = [15.0, 60, 300]
    static let testFrameSeconds = 15.0
    static let farewellSeconds = 30.0
    static let nameEvents: Set<String> = ["SessionStart", "UserPromptSubmit", "Stop"]

    private let lock = NSRecursiveLock()
    public private(set) var settings: Settings
    public let dryRun: Bool
    public let board = Board()
    public let startedAt = Date().timeIntervalSince1970
    var lastSig = ""
    var lastPushAt = 0.0
    public private(set) var lastPush: LastPush?
    /// The conversations named on the frame last sent, by key.
    public private(set) var framed: [String] = []
    var testUntil = 0.0
    var farewellUntil = 0.0
    public private(set) var usage: Usage?
    private var seenEvents: Set<String> = []
    private var namesReadAt = 0.0

    private let wake = NSCondition()  // for the three flags below
    private var dirty = false
    private var urgent = false
    private var namesDue = false

    /// Called, on no particular thread, when something the menu bar shows may have changed.
    public var onChange: (() -> Void)?

    public init(settings: Settings = ConfigStore.load(), dryRun: Bool = false) {
        self.settings = settings
        self.dryRun = dryRun
        applyTimeouts()
        load()
    }

    /// For tests, which stand in for the pusher.
    func setLastPush(_ push: LastPush) { lastPush = push }

    public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func applyTimeouts() {
        board.doneTTL = Double(settings.doneTTLMinutes) * 60
        board.staleRunning = Double(settings.staleRunningMinutes) * 60
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.state), let state = try? JSONDecoder().decode(StateFile.self, from: data) else { return }
        if let saved = state.board { board.load(saved) }
        lastSig = state.lastSig ?? ""
        lastPush = state.lastPush
        framed = state.framed ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(StateFile(board: board.saved, lastSig: lastSig, lastPush: lastPush, framed: framed)) else { return }
        try? ConfigStore.write(data, to: Paths.state)
    }

    // MARK: flags

    private func raise(dirty: Bool = false, urgent: Bool = false, names: Bool = false) {
        wake.lock()
        if dirty { self.dirty = true }
        if urgent { self.urgent = true }
        if names { namesDue = true }
        wake.broadcast()
        wake.unlock()
    }

    // MARK: events

    private func waitingKeys() -> Set<String> { Set(board.visible().filter { $0.state == .waiting }.map(\.key)) }

    public func onEvent(_ source: String, _ event: String, _ payload: JSON) {
        let changed: Bool = locked {
            if seenEvents.insert("\(source) \(event)").inserted {
                // Field names only, never values: shows what each agent's hooks actually send.
                Log.info("first \(source) \(event) since start; payload fields: \((payload.object?.keys ?? []).sorted().joined(separator: ", "))")
            }
            let wasWaiting = waitingKeys()
            let changed = board.apply(source, event, payload)
            Log.info("\(source) \(event)\(changed ? " (board changed)" : "")")
            let unnamed = board.visible().contains { $0.name.isEmpty }
            if Engine.nameEvents.contains(event) || (unnamed && now() - namesReadAt > 10) { raise(names: true) }
            guard changed else { return false }
            raise(dirty: true, urgent: !waitingKeys().subtracting(wasWaiting).isEmpty)
            save()
            return true
        }
        if changed { onChange?() }
    }

    // MARK: what the settings page and the menu bar can ask for

    public static func inQuietHours(_ settings: Settings, now: Double = Date().timeIntervalSince1970) -> Bool {
        let quiet = settings.quietHours
        guard quiet.enabled else { return false }
        let clock = hhmm(now)
        return quiet.start < quiet.end ? (quiet.start <= clock && clock < quiet.end) : (clock >= quiet.start || clock < quiet.end)
    }

    public func currentView(now: Double = Date().timeIntervalSince1970) -> FrameView {
        locked {
            if now < testUntil {
                var view = FrameView(kind: .test, font: settings.font)
                let sent = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: testUntil - Engine.testFrameSeconds))
                view.note = String(format: "%02d:%02d:%02d 发送", sent.hour ?? 0, sent.minute ?? 0, sent.second ?? 0)
                return view
            }
            if now < farewellUntil { return .notice("已退出", "打开 Agent 状态牌恢复", font: settings.font) }
            if settings.paused { return .notice("已暂停", "在菜单栏里恢复", font: settings.font) }
            if Engine.inQuietHours(settings, now: now) { return .notice("夜间免打扰", "\(settings.quietHours.end) 恢复", font: settings.font) }
            return buildView(board, now: now, settings: settings, usage: usage)
        }
    }

    @discardableResult
    public func applyConfig(_ patch: JSON) throws -> Settings {
        let clean = try ConfigStore.validate(patch)
        return try locked {
            try ConfigStore.save(clean)
            settings = ConfigStore.load()
            applyTimeouts()
            // paused is asked for by hand: do not make it wait its turn
            raise(dirty: true, urgent: clean["paused"] != nil)
            Log.info("settings changed: \(clean.keys.sorted().joined(separator: ", "))")
            defer { onChange?() }
            return settings
        }
    }

    public func useDevice(_ deviceID: String) throws {
        try locked {
            try ConfigStore.save(["device_id": .string(deviceID)])
            settings = ConfigStore.load()
            Log.info("device chosen in setup")
        }
        forceRefresh()
    }

    /// Settings changed on disk by something other than this process's own pages.
    public func reloadSettings() {
        locked {
            settings = ConfigStore.load()
            applyTimeouts()
        }
    }

    public func forceRefresh() {
        locked { lastSig = "" }
        raise(dirty: true, urgent: true)
    }

    public func showTestFrame() {
        locked { testUntil = now() + Engine.testFrameSeconds }
        raise(dirty: true, urgent: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + Engine.testFrameSeconds + 0.5) { [weak self] in self?.forceRefresh() }
    }

    /// The app is about to quit. The screen keeps its last frame once nothing updates
    /// it, so that frame should say the board is off. Returns once it has been sent,
    /// has failed, or `timeout` has passed.
    public func sayFarewell(timeout: Double = 8) {
        let before = locked { () -> Double? in
            farewellUntil = now() + Engine.farewellSeconds
            return lastPush?.at
        }
        raise(dirty: true, urgent: true)
        let deadline = Date().addingTimeInterval(timeout)
        while locked({ lastPush?.at }) == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    }

    /// The frame last sent, or what would be sent now when nothing has been yet.
    public func framePNG() -> Data {
        (try? Data(contentsOf: Paths.frame)) ?? render(currentView()).png
    }

    // MARK: pushing

    /// Let a burst of events land. Ordinary changes also keep their distance from the
    /// previous refresh; a new "needs you" cuts the wait short.
    private func settle() {
        let gap = locked { lastPushAt + Double(settings.minPushIntervalSeconds) } - now()
        wake.lock()
        if !urgent {
            let deadline = Date().addingTimeInterval(max(Engine.coalesceSeconds, gap))
            while !urgent {
                if !wake.wait(until: deadline) {
                    wake.unlock()
                    return
                }
            }
        }
        wake.unlock()
        Thread.sleep(forTimeInterval: Engine.urgentSeconds)
    }

    private func push(_ view: FrameView) throws -> String {
        let png = render(view).png
        try? ConfigStore.write(png, to: Paths.frame)
        let settings: Settings = locked {
            framed = view.named
            return self.settings
        }
        if dryRun {
            Log.info("dry run: rendered \(view.kind.rawValue) frame, not sent")
            return "空跑模式，没有发送"
        }
        if !settings.ready { return "还没有连接设备，没有发送" }
        let message = try DotAPI.pushImage(settings, png, blackBorder: view.kind == .wait)
        Log.info("pushed \(view.kind.rawValue) frame (\(png.count) bytes): \(message)")
        return message
    }

    private func pusher() {
        var failures = 0
        while true {
            wake.lock()
            while !dirty { wake.wait() }
            wake.unlock()
            settle()
            wake.lock()
            dirty = false
            urgent = false
            wake.unlock()
            let (view, same): (FrameView, Bool) = locked {
                board.prune()
                let view = currentView()
                return (view, view.signature == lastSig)
            }
            if same { continue }
            do {
                let message = try push(view)
                failures = 0
                locked {
                    lastSig = view.signature
                    lastPushAt = now()
                    lastPush = LastPush(at: lastPushAt, ok: true, kind: view.kind.rawValue, message: message, delivered: DotAPI.delivered(message))
                    save()
                }
                onChange?()
            } catch {
                let delay = Engine.retrySeconds[min(failures, Engine.retrySeconds.count - 1)]
                failures += 1
                Log.warning("push failed (\(describe(error))); retrying in \(Int(delay))s")
                locked { lastPush = LastPush(at: now(), ok: false, kind: view.kind.rawValue, message: describe(error), delivered: nil) }
                onChange?()
                // Wait before trying again, unless something urgent turns up meanwhile.
                wake.lock()
                let deadline = Date().addingTimeInterval(delay)
                while !urgent { if !wake.wait(until: deadline) { break } }
                dirty = true
                wake.unlock()
            }
        }
    }

    // MARK: names

    /// Pick up each conversation's name from the agent's own records.
    func refreshNames() {
        let wanted = locked { board.sessions.values.map { ($0.key, $0.source, $0.id, $0.transcript) } }
        let found = wanted.map { ($0.0, Names.lookup(source: $0.1, sessionID: $0.2, transcript: $0.3)) }
        let changed: Bool = locked {
            namesReadAt = now()
            var changed = false
            for (key, name) in found where !name.isEmpty && board.sessions[key] != nil && board.sessions[key]?.name != name {
                board.sessions[key]?.name = name  // no record in reach: keep the name we have
                changed = true
            }
            if changed { save() }
            return changed
        }
        if changed {
            raise(dirty: true)
            onChange?()
        }
    }

    /// Names appear a little after a conversation starts and can be edited later, so
    /// look after the events that tend to precede one, and now and then.
    private func namer() {
        while true {
            wake.lock()
            let deadline = Date().addingTimeInterval(30)
            while !namesDue { if !wake.wait(until: deadline) { break } }
            namesDue = false
            wake.unlock()
            Thread.sleep(forTimeInterval: 1)  // give the agent a moment to write its record
            refreshNames()
        }
    }

    // MARK: the ticker

    func readUsage() {
        let reading = UsageReader.snapshot()
        locked { usage = reading }
    }

    /// Put the board back if the device has moved on to other loop content, and send
    /// the current frame once a device that slept through one is awake again.
    func checkScreen() {
        let (settings, missed, due): (Settings, Bool, Bool) = locked {
            let missed = lastPush?.delivered == false
            let due = !dryRun && self.settings.ready && !lastSig.isEmpty && (missed || self.settings.keepOnScreen)
                && now() - lastPushAt >= 20  // else a frame of ours is still on its way
            return (self.settings, missed, due)
        }
        guard due else { return }
        let status: JSON
        do {
            status = try DotAPI.getStatus(settings)
        } catch {
            Log.warning("could not check what the device is showing: \(describe(error))")
            return
        }
        if missed {
            if !DotAPI.asleep(status) {
                Log.info("the device is awake again; sending the frame it missed")
                forceRefresh()
            }
        } else if DotAPI.showingImageSlot(status) == false {  // nil means the device did not say; leave it alone
            Log.info("the device is showing other content; putting the board back")
            forceRefresh()
        }
    }

    /// Sessions age off the board and quota moves without any event; re-check periodically.
    private func ticker() {
        var beat = 0
        while true {
            if beat > 0 { readUsage() }  // the first reading is taken before the threads start
            if beat % 2 == 1 { checkScreen() }
            beat += 1
            raise(dirty: true)
            onChange?()
            Thread.sleep(forTimeInterval: 30)
        }
    }

    public func start() {
        if !settings.ready && !dryRun {
            Log.info("no device yet: waiting for one to be connected in the settings page")
        }
        raise(names: true)
        let starter = Thread { [self] in
            readUsage()  // before the first frame, so it does not go out without quota; asking Claude can take seconds
            for (name, body) in [("pusher", pusher), ("ticker", ticker), ("namer", namer)] {
                let thread = Thread(block: body)
                thread.name = name
                thread.start()
            }
        }
        starter.name = "start"
        starter.start()
    }
}
