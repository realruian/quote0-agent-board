import Foundation
import XCTest
@testable import BoardCore

let alpha: JSON = ["session_id": "a", "cwd": "/Users/me/Dev/alpha"]
let beta: JSON = ["session_id": "b", "cwd": "/Users/me/Dev/beta"]

extension JSON {
    /// The same payload with more fields.
    func with(_ extra: JSONObject) -> JSON {
        var object = self.object ?? JSONObject()
        for (key, value) in extra.pairs { object[key] = value }
        return .object(object)
    }
}

/// Tests draw with the fonts in the repository and write only under a folder of their own.
class BoardTestCase: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    var home: URL!

    override func setUp() {
        super.setUp()
        Resources.directory = BoardTestCase.repository.appendingPathComponent("agent_board")
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        Paths.homeOverride = home
        // Nothing a test does may reach the real key, the real agents' hooks, or the network.
        _ = write("{\n  \"api_key_file\": \"\(home.path)/dot_api_key\"\n}\n", "config.json")
        Hooks.files = ["claude": home.appendingPathComponent("agents/claude-settings.json"), "codex": home.appendingPathComponent("agents/codex-hooks.json")]
        DotAPI.transport = { _ in throw URLError(.notConnectedToInternet) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    func write(_ text: String, _ name: String) -> URL {
        let url = home.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

func states(_ board: Board, _ now: Double) -> [String] { board.visible(now).map { "\($0.project) \($0.state.rawValue)" } }
