// Minimal client for the MindReset Dot open API (https://dot.mindreset.tech/docs/service/open).

import Foundation

public struct DotError: Error, CustomStringConvertible {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var description: String { "HTTP \(status): \(message)" }
}

/// What to show the user for something that went wrong while talking to a server.
public func describe(_ error: Error) -> String {
    (error as? DotError)?.description ?? (error as? ConfigError)?.message ?? error.localizedDescription
}

public enum DotAPI {
    /// Sends a request and returns the status and the body. Tests put their own in.
    public static var transport: (URLRequest) throws -> (Int, Data) = { request in
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(URLError(.unknown))
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                result = .failure(error)
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private static let session = URLSession(configuration: .ephemeral)

    static func request(_ settings: Settings, _ method: String, _ path: String, body: JSON? = nil, key: String? = nil) throws -> JSON {
        guard let url = URL(string: "\(settings.apiBase)/api/authV2/open/\(path)") else { throw DotError(status: 0, message: "地址不对") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.compact.utf8) }
        request.setValue("Bearer \(try key ?? settings.apiKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (status, data) = try transport(request)
        let parsed = try? JSON(parsing: data)
        guard (200..<300).contains(status) else {
            let raw = String(decoding: data, as: UTF8.self)
            throw DotError(status: status, message: parsed?["message"]?.string ?? String(raw.prefix(200)))
        }
        return parsed ?? JSON.object(JSONObject())
    }

    private static func device(_ settings: Settings, _ method: String, _ path: String, body: JSON? = nil) throws -> JSON {
        try request(settings, method, "device/\(settings.deviceID)/\(path)", body: body)
    }

    /// The devices an API key can reach. `key` tries one that is not stored yet.
    public static func devices(_ settings: Settings, key: String? = nil) throws -> [JSON] {
        try request(settings, "GET", "devices", key: key).array ?? []
    }

    /// Show a 296x152 PNG now, in the loop list's Image API slot.
    public static func pushImage(_ settings: Settings, _ png: Data, blackBorder: Bool = false) throws -> String {
        let result = try device(settings, "POST", "image", body: [
            "taskType": "loop", "refreshNow": true, "image": .string(png.base64EncodedString()),
            "border": blackBorder ? 1 : 0, "ditherType": "NONE", "taskAlias": "Agent 状态牌",
        ])
        return result["message"]?.string ?? ""
    }

    public static func getSettings(_ settings: Settings) throws -> JSON { try device(settings, "GET", "settings") }

    /// Fields left out of `body` keep their current value on the device.
    @discardableResult
    public static func updateSettings(_ settings: Settings, _ body: JSON) throws -> JSON {
        try device(settings, "POST", "settings", body: body)
    }

    public static func getStatus(_ settings: Settings) throws -> JSON { try device(settings, "GET", "status") }

    public static func setIntervals(_ settings: Settings, powerMs: Int? = nil, batteryMs: Int? = nil) throws {
        var interval = JSONObject()
        if let powerMs = powerMs { interval["powerMs"] = JSON(powerMs) }
        if let batteryMs = batteryMs { interval["batteryMs"] = JSON(batteryMs) }
        try updateSettings(settings, ["interval": .object(interval)])
    }

    public static func loopList(_ settings: Settings) throws -> [JSON] { try device(settings, "GET", "loop/list").array ?? [] }

    /// Whether the reply to a push says the frame is on the screen. A sleeping or
    /// offline device has the frame kept for it and shows it when it next wakes.
    public static func delivered(_ message: String) -> Bool { !message.contains("休眠") && !message.contains("离线") }

    /// Whether a status says the device is sleeping to save battery.
    public static func asleep(_ status: JSON) -> Bool { (status["status"]?["current"]?.string ?? "").contains("休眠") }

    /// Whether the frame a status reports comes from the Image API slot the board
    /// writes to. nil when the status does not say what is on screen.
    public static func showingImageSlot(_ status: JSON) -> Bool? {
        guard let images = status["renderInfo"]?["current"]?["image"]?.array, !images.isEmpty else { return nil }
        return images.contains { ($0.string ?? "").contains("image_api") }
    }
}
