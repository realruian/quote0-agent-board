// Where the hook script delivers events: a socket in the board's own directory.
// One message is `<source> <event> <nbytes>\n` followed by nbytes of JSON.

import Foundation

private let token = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,32}$")
private let field = try! NSRegularExpression(
    pattern: "\"(session_id|conversation_id|transcript_path|cwd|tool_name|agent_id|notification_type)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
private let prompt = try! NSRegularExpression(pattern: "\"prompt\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\(?:[\"\\\\/bfnrt]|u[0-9a-fA-F]{4})){0,300})")

/// Decode hook JSON. The hook forwards only the head of large payloads, so a
/// cut-off document falls back to picking out the top-level fields we need.
public func parsePayload(_ raw: Data) -> JSON {
    let text = String(decoding: raw, as: UTF8.self)
    if let whole = try? JSON(parsing: text) { return whole.object != nil ? whole : .object(JSONObject()) }
    func unescaped(_ body: String) -> String? { (try? JSON(parsing: "\"\(body)\""))?.string }
    var fields = JSONObject()
    for match in field.matches(in: text, range: text.whole) {
        guard let name = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text),
              fields[String(text[name])] == nil else { continue }
        fields[String(text[name])] = .string(unescaped(String(text[value])) ?? String(text[value]))
    }
    // usually the field that got cut: keep its beginning
    if let match = prompt.firstMatch(in: text, range: text.whole), let value = Range(match.range(at: 1), in: text),
       let start = unescaped(String(text[value])) {
        fields["prompt"] = .string(start)
    }
    return .object(fields)
}

public final class HookSocket {
    static let maxPayload = 65536
    private let handler: (String, String, JSON) -> Void
    private var listener: Int32 = -1

    public init(handler: @escaping (String, String, JSON) -> Void) {
        self.handler = handler
    }

    public func start(at url: URL = Paths.socket) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        guard listener >= 0, path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileWriteInvalidFileName) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 64) == 0 else { throw CocoaError(.fileWriteUnknown) }
        chmod(url.path, 0o600)
        Log.info("listening on \(url.path)")
        let thread = Thread { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return  // closed
                }
                DispatchQueue.global().async { self.serve(connection) }
            }
        }
        thread.name = "hooks"
        thread.start()
    }

    public func stop(at url: URL = Paths.socket) {
        if listener >= 0 { close(listener) }
        unlink(url.path)
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        func more() -> Bool {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count > 0 { received.append(contentsOf: buffer[0..<count]) }
            return count > 0
        }
        while received.firstIndex(of: 0x0A) == nil && received.count < 256 { if !more() { break } }
        if received.isEmpty { return }  // a liveness probe: connected and hung up
        guard let newline = received.firstIndex(of: 0x0A) else { return Log.warning("ignored hook message: no header") }
        let header = String(decoding: received[..<newline], as: UTF8.self).split(separator: " ").map(String.init)
        guard header.count == 3, let size = Int(header[2]), (0...HookSocket.maxPayload).contains(size),
              token.firstMatch(in: header[0], range: header[0].whole) != nil, token.firstMatch(in: header[1], range: header[1].whole) != nil else {
            return Log.warning("ignored hook message: malformed header")
        }
        var body = received[(newline + 1)...]
        while body.count < size {
            let before = received.count
            if !more() { return Log.warning("ignored hook message: cut short") }
            body.append(received[before...])
        }
        handler(header[0], header[1], parsePayload(Data(body.prefix(size))))
    }
}
