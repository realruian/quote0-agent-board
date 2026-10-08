import XCTest
@testable import BoardCore

/// Stands in for MindReset's service: one key, two devices.
private final class FakeDot {
    var sent: [(path: String, body: JSON)] = []
    var interval: JSON = ["powerMs": 300_000]
    var status: JSON = ["status": ["current": "电源活跃", "battery": "已连接电源"]]

    func transport(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path.replacingOccurrences(of: "/api/authV2/open/", with: "")
        let body = (try? JSON(parsing: request.httpBody ?? Data("{}".utf8))) ?? .null
        func reply(_ value: JSON, _ status: Int = 200) -> (Int, Data) { (status, Data(value.compact.utf8)) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer dot_app_good" else {
            return reply(["message": "This API key is invalid. Check the key and try again."], 400)
        }
        if request.httpMethod == "POST" { sent.append((path, body)) }
        if path == "devices" { return reply([["id": "D0", "model": "quote_0"], ["id": "D1", "model": "quote_0"]]) }
        if path.hasSuffix("/settings"), request.httpMethod == "GET" {
            return reply(["alias": path.contains("D0") ? "书桌" : .null, "interval": interval, "timezone": "Asia/Shanghai"])
        }
        if path.hasSuffix("/settings") {
            if var merged = interval.object, let change = body["interval"]?.object {
                for (key, value) in change.pairs { merged[key] = value }
                interval = .object(merged)
            }
            return reply(["message": "ok"])
        }
        if path.hasSuffix("/status") { return reply(status) }
        if path.hasSuffix("/loop/list") { return reply([["type": "IMAGE_API"]]) }
        if path.hasSuffix("/image") { return reply(["message": "图片 API 内容已切换。"]) }
        return reply(["message": "unknown"], 404)
    }
}

final class ConsoleTests: BoardTestCase {
    private var engine: Engine!
    private var console: Console!
    private var dot: FakeDot!

    override func setUp() {
        super.setUp()
        engine = Engine(dryRun: true)
        console = Console(engine: engine)
        XCTAssertTrue(console.start(port: 0))
        dot = FakeDot()
        DotAPI.transport = dot.transport
    }

    override func tearDown() {
        console.stop()
        super.tearDown()
    }

    private func request(_ method: String, _ path: String, _ body: JSON? = nil, token: Bool = true, host: String? = nil,
                         origin: String? = nil) -> (status: Int, type: String, body: Data) {
        var headers = ["host": host ?? "127.0.0.1:\(console.port)"]
        if token { headers["x-board-token"] = console.token }
        if body != nil { headers["origin"] = origin ?? console.page }
        let response = console.respond(to: Console.Request(method: method, path: path, headers: headers, body: Data((body?.compact ?? "").utf8)))
        return (response.status, response.contentType, response.body)
    }

    private func json(_ method: String, _ path: String, _ body: JSON? = nil) throws -> JSON {
        let response = request(method, path, body)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        return try JSON(parsing: response.body)
    }

    private func connect() {
        try! "dot_app_good\n".write(to: engine.settings.apiKeyPath, atomically: true, encoding: .utf8)
        try! engine.useDevice("D1")
    }

    func testPageCarriesTheTokenAndNeverTheKey() {
        connect()
        let page = request("GET", "/", token: false)
        XCTAssertEqual(page.status, 200)
        let text = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(text.contains(console.token))
        XCTAssertFalse(text.contains("dot_app_good"))
        for path in ["/api/overview", "/api/settings", "/api/setup", "/api/device", "/api/about"] {
            XCTAssertFalse(String(decoding: request("GET", path).body, as: UTF8.self).contains("dot_app_good"), path)
        }
    }

    func testAPINeedsTokenHostAndOrigin() {
        XCTAssertEqual(request("GET", "/api/overview", token: false).status, 403)
        XCTAssertEqual(request("GET", "/api/overview", host: "evil.example").status, 403)
        XCTAssertEqual(request("GET", "/", token: false, host: "evil.example:\(console.port)").status, 403)
        XCTAssertEqual(request("POST", "/api/settings", ["max_rows": 3], origin: "http://evil.example").status, 403)
        XCTAssertEqual(request("POST", "/api/settings", ["max_rows": 3], token: false).status, 403)
        XCTAssertEqual(request("GET", "/static/../Config.swift", token: false).status, 404)
        XCTAssertEqual(request("GET", "/static/app.js", token: false).type, "text/javascript; charset=utf-8")
        XCTAssertEqual(request("GET", "/api/frame.png", token: false).type, "image/png")
        XCTAssertEqual(request("POST", "/api/nope", [:]).status, 404)
        XCTAssertEqual(request("GET", "/api/overview", host: "localhost:\(console.port)").status, 200)
    }

    func testServesOverTheSocket() throws {
        var call = URLRequest(url: URL(string: "\(console.page)/api/overview")!)
        call.setValue(console.token, forHTTPHeaderField: "X-Board-Token")
        let done = expectation(description: "answered")
        var answer: JSON?
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: call) { data, _, _ in
            answer = data.flatMap { try? JSON(parsing: $0) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(answer?["dry_run"], true)
    }

    func testSettingsAreCheckedSavedAndApplied() throws {
        XCTAssertEqual(try json("POST", "/api/settings", ["max_rows": 2, "aliases": ["alpha": "甲"]])["config"]?["max_rows"], 2)
        XCTAssertEqual(engine.settings.maxRows, 2)
        XCTAssertEqual(ConfigStore.load().aliases, ["alpha": "甲"])
        let bad = request("POST", "/api/settings", ["max_rows": 9])
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(try JSON(parsing: bad.body)["error"], "最多显示行数需要是 1 到 4 之间的整数")
        XCTAssertEqual(request("POST", "/api/settings", ["device_id": "x"]).status, 400)
        XCTAssertEqual(request("POST", "/api/preview", ["config": ["font": "arkpixel"], "sample": "wait"]).type, "image/png")
        XCTAssertEqual(request("POST", "/api/preview", ["sample": "nope"]).status, 400)
    }

    func testOverviewListsSessions() throws {
        engine.onEvent("claude", "UserPromptSubmit", ["session_id": "s", "cwd": "/p/alpha", "prompt": "修复订单导出的时区问题"])
        let overview = try json("GET", "/api/overview")
        XCTAssertEqual(overview["sessions"]?.array?.count, 1)
        let session = overview["sessions"]!.array![0]
        XCTAssertEqual([session["project"], session["title"], session["state"]], ["alpha", "修复订单导出的时区问题", "running"])
        XCTAssertEqual(overview["view_kind"], "list")
        XCTAssertEqual(try json("GET", "/api/settings")["known_projects"], ["alpha"])
    }

    func testPausingHoldsTheScreenOnANotice() throws {
        engine.onEvent("claude", "UserPromptSubmit", ["session_id": "p", "cwd": "/p/paused"])
        XCTAssertEqual(try json("GET", "/api/overview")["paused"], false)
        _ = try json("POST", "/api/settings", ["paused": true])
        XCTAssertEqual(try json("GET", "/api/overview")["paused"], true)
        XCTAssertEqual([engine.currentView().kind.rawValue, engine.currentView().line], ["quiet", "已暂停"])
        _ = try json("POST", "/api/settings", ["paused": false])
        XCTAssertEqual(engine.currentView().kind, .list)
        XCTAssertEqual(request("POST", "/api/settings", ["paused": "yes"]).status, 400)
    }

    func testSetupSavesAKeyAndTakesADevice() throws {
        let keyFile = engine.settings.apiKeyPath
        XCTAssertEqual(keyFile.deletingLastPathComponent().path, home.path)  // never the real one in the user's home
        XCTAssertEqual(try json("GET", "/api/setup"), ["ready": false, "key": ["present": false, "looks_valid": false], "device_id": "", "devices": []])
        for bad in ["nope", "dot_app_bad", "dot_app with spaces", 7] as [JSON] {
            XCTAssertEqual(request("POST", "/api/setup", ["key": bad]).status, 400, bad.compact)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))

        let found = try json("POST", "/api/setup", ["key": " dot_app_good\n"])
        XCTAssertEqual([found["ready"], found["key"]?["looks_valid"]], [false, true])
        XCTAssertEqual(found["devices"], [["id": "D0", "model": "quote_0", "alias": "书桌"], ["id": "D1", "model": "quote_0", "alias": ""]])
        XCTAssertEqual(try String(contentsOf: keyFile, encoding: .utf8), "dot_app_good\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(String(decoding: request("GET", "/api/setup").body, as: UTF8.self).contains("dot_app_good"))  // it goes in and never comes back

        XCTAssertEqual(request("POST", "/api/setup", ["device_id": "D9"]).status, 400)
        let chosen = try json("POST", "/api/setup", ["device_id": "D1"])
        XCTAssertEqual([chosen["ready"], chosen["device_id"]], [true, "D1"])
        XCTAssertEqual([engine.settings.deviceID, ConfigStore.load().deviceID], ["D1", "D1"])
        XCTAssertEqual(dot.sent.map(\.path), ["device/D1/settings"])  // the board is kept up on the new device
        XCTAssertEqual(dot.sent[0].body, ["interval": ["powerMs": 43_200_000]])
        XCTAssertEqual(request("POST", "/api/setup", [:]).status, 400)

        // choosing another device gives the first its loop interval back
        _ = try json("POST", "/api/setup", ["device_id": "D0"])
        XCTAssertEqual(dot.sent.map(\.path), ["device/D1/settings", "device/D1/settings", "device/D0/settings"])
        XCTAssertEqual(dot.sent[1].body, ["interval": ["powerMs": 300_000]])
    }

    func testKeepingTheBoardUpSetsTheDeviceAndTheSettingTogether() throws {
        connect()
        _ = try json("POST", "/api/device", ["keep": true])
        XCTAssertTrue(engine.settings.keepOnScreen)
        _ = try json("POST", "/api/device", ["keep": true])  // already held: nothing to send
        _ = try json("POST", "/api/device", ["keep": false])
        XCTAssertFalse(engine.settings.keepOnScreen)
        XCTAssertEqual(request("POST", "/api/device", ["keep": "yes"]).status, 400)
        XCTAssertEqual(dot.sent.map(\.body), [["interval": ["powerMs": 43_200_000]], ["interval": ["powerMs": 300_000]]])
    }

    func testDeviceSettingsAreChecked() throws {
        connect()
        let device = try json("POST", "/api/device", ["battery_minutes": 30, "alias": " 桌面 "])
        XCTAssertEqual([device["ok"], device["image_slot"], device["asleep"]], [true, true, false])
        XCTAssertEqual(dot.sent[0].body, ["alias": "桌面", "interval": ["batteryMs": 1_800_000]])
        for bad in [["battery_minutes": 0], ["battery_minutes": 721], ["battery_minutes": true], ["sleep": ["start": "07:00", "end": "07:00"]], [:]] as [JSON] {
            XCTAssertEqual(request("POST", "/api/device", bad).status, 400, bad.compact)
        }
        XCTAssertEqual(dot.sent.count, 1)
    }

    func testBeforeADeviceIsConnectedThePagesSaySo() throws {
        let live = Engine(dryRun: false)
        let page = Console(engine: live)
        XCTAssertEqual(page.overview()["needs_setup"], true)
        XCTAssertEqual(page.device()["needs_setup"], true)
        XCTAssertEqual(page.runChecks()["results"]?.array?.first { $0["name"] == "连接 MindReset 服务" }?["ok"], false)
    }

    // -- the device asleep, or showing something else --

    func testMissedFrameIsSentAgainOnceTheDeviceWakes() {
        connect()
        let live = Engine(dryRun: false)
        _ = try? live.applyConfig(["keep_on_screen": false])
        live.lastSig = "sig"
        live.locked { live.setLastPush(Engine.LastPush(at: 1, ok: true, kind: "list", message: "休眠", delivered: false)) }
        dot.status = ["status": ["current": "休眠中"]]
        live.checkScreen()
        XCTAssertEqual(live.lastSig, "sig")  // still asleep: nothing to do
        dot.status = ["status": ["current": "电源活跃"]]
        live.checkScreen()
        XCTAssertEqual(live.lastSig, "")  // awake: the frame goes out again
    }

    func testBoardIsPutBackWhenOtherContentIsOnScreen() {
        connect()
        let live = Engine(dryRun: false)
        live.lastSig = "sig"
        live.locked { live.setLastPush(Engine.LastPush(at: 1, ok: true, kind: "list", message: "ok", delivered: true)) }
        dot.status = ["renderInfo": ["current": ["image": ["https://x/image_api/1.png"]]]]
        live.checkScreen()
        XCTAssertEqual(live.lastSig, "sig")
        dot.status = ["renderInfo": ["current": ["image": ["https://x/quote/1.png"]]]]
        live.checkScreen()
        XCTAssertEqual(live.lastSig, "")
        XCTAssertTrue(DotAPI.delivered("设备 D0 图片 API 内容已切换。"))
        XCTAssertFalse(DotAPI.delivered("设备 D0 当前休眠或离线，文本 API 内容已更新，将在下次内容切换时显示。"))
    }

    func testQuittingLeavesAFarewellOnTheScreen() {
        engine.sayFarewell(timeout: 0.2)
        XCTAssertEqual([engine.currentView().kind.rawValue, engine.currentView().line], ["quiet", "已退出"])
    }
}
