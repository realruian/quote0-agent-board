// The log the settings page shows: one line per event, kept to a few hundred kilobytes.

import Foundation

public enum Log {
    private static let queue = DispatchQueue(label: "agent-board.log")
    private static let maxBytes = 512_000
    private static let backups = 2
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return formatter
    }()

    public static func info(_ message: String) { write("INFO", message) }
    public static func warning(_ message: String) { write("WARNING", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        queue.async {
            if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data(line.utf8)) }
            let url = Paths.log
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size + line.utf8.count > maxBytes {
                for index in stride(from: backups, through: 1, by: -1) {
                    let older = URL(fileURLWithPath: "\(url.path).\(index)")
                    try? manager.removeItem(at: older)
                    try? manager.moveItem(at: index == 1 ? url : URL(fileURLWithPath: "\(url.path).\(index - 1)"), to: older)
                }
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Wait for lines already handed over to reach the file.
    public static func flush() { queue.sync {} }
}

/// The last `bytes` of a file as lines; these files are appended to for the life of a conversation.
func tailLines(_ path: String, bytes: Int) throws -> [String] {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).map(String.init)
}
