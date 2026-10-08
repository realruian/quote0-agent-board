// What a first launch sets up, and what uninstalling takes away again: the hook
// script and the agents' hooks, opening at login, and nothing else. The app keeps
// everything it writes under ~/.quote0-agent-board.

import BoardCore
import Foundation

enum Install {
    static let label = "com.quote0.agent-board.menubar"  // also the bundle identifier
    static let legacyDaemonLabel = "com.quote0.agent-board"  // the Python version's background process

    static var agents: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents") }
    static var loginItem: URL { agents.appendingPathComponent("\(label).plist") }
    static var domain: String { "gui/\(getuid())" }

    /// Whether launchd started this process, at login or after a crash, rather than the user opening it.
    static var startedByLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    @discardableResult
    static func launchctl(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Why the app cannot run from where it is, or nil when it can. A copy opened
    /// straight from the disk image or the Downloads folder runs from a read-only
    /// place that changes on every launch, and opening at login needs a place that stays.
    static func misplaced() -> String? {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return nil }  // a development build run from the build folder
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "请先把「Agent 状态牌」拖进「应用程序」文件夹，再从那里打开。"
        }
        return nil
    }

    /// Bring this Mac to the state the app needs. Safe to run on every launch: each step
    /// only changes what is not already as it should be.
    static func ensure() {
        let manager = FileManager.default
        let first = !manager.fileExists(atPath: Paths.config.path)
        for folder in ["run", "logs", "backups", "bin"] {
            try? manager.createDirectory(at: Paths.home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.home.path)

        // The Python version ran the board as its own background process. Only one of the two can have the socket.
        let legacy = agents.appendingPathComponent("\(legacyDaemonLabel).plist")
        if manager.fileExists(atPath: legacy.path) {
            launchctl("bootout", "\(domain)/\(legacyDaemonLabel)")
            for _ in 0..<50 where launchctl("print", "\(domain)/\(legacyDaemonLabel)") == 0 { Thread.sleep(forTimeInterval: 0.1) }
            try? manager.removeItem(at: legacy)
            Log.info("took over from the Python background process")
        }

        let script = Resources.directory.appendingPathComponent("agent-board-hook")
        if let wanted = try? Data(contentsOf: script), wanted != (try? Data(contentsOf: Paths.hook)) {
            try? ConfigStore.write(wanted, to: Paths.hook, mode: 0o755)
        }

        // A first launch connects both agents. Later launches only bring the hooks that are
        // there up to date: an agent the user disconnected stays disconnected.
        for agent in Hooks.agents where first || Hooks.status(agent).installed > 0 {
            do {
                let result = try Hooks.setEnabled(agent, true)
                if result != "already up to date" { Log.info("\(agent) hooks: \(result)") }
            } catch {
                Log.warning("could not set up \(agent) hooks: \(describe(error))")
            }
        }

        if let executable = Bundle.main.executablePath, Bundle.main.bundlePath.hasSuffix(".app") {
            let job: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],  // back after a crash, but quitting from the menu sticks
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
                "AssociatedBundleIdentifiers": [label],
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
               data != (try? Data(contentsOf: loginItem)) {
                try? manager.createDirectory(at: agents, withIntermediateDirectories: true)
                try? data.write(to: loginItem, options: .atomic)
                Log.info("will open at login from \(executable)")
            }
        }
    }

    /// Undo `ensure`. Settings, logs and backups stay, so installing again picks up where this left off.
    static func remove(console: Console) {
        for agent in Hooks.agents {
            let result = (try? Hooks.setEnabled(agent, false)) ?? "failed"
            Log.info("\(agent) hooks removed: \(result)")
        }
        console.restoreDeviceInterval()
        try? FileManager.default.removeItem(at: loginItem)
        try? FileManager.default.removeItem(at: Paths.hook)
        Log.info("uninstalled")
        Log.flush()
    }

    /// Start the app again. launchd does it for a copy it started; another is opened by hand.
    static func relaunch() -> Never {
        Log.flush()
        if startedByLaunchd {
            launchctl("kickstart", "-k", "\(domain)/\(label)")
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? process.run()
        }
        exit(0)
    }
}
