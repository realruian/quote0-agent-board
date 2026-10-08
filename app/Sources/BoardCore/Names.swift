// The name a conversation carries in its own app (the one shown in the sidebar).
//
// Both agents keep it in plain local files:
// - Claude Code appends `custom-title` (or `ai-title`) records to the session transcript.
// - Codex lists `thread_name` per session in ~/.codex/session_index.jsonl.

import Foundation

public enum Names {
    public static var codexIndex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl").path
    private static let tailBytes = 262_144
    private static let maxChars = 60

    private static func clean(_ name: JSON?) -> String {
        guard let name = name?.string else { return "" }
        return String(name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxChars))
    }

    /// Latest title record near the end of a Claude Code transcript, or "".
    public static func claude(transcript: String) -> String {
        guard transcript.hasSuffix(".jsonl"), let lines = try? tailLines(transcript, bytes: tailBytes) else { return "" }
        for line in lines.reversed() where line.contains("\"custom-title\"") || line.contains("\"ai-title\"") {
            guard let record = try? JSON(parsing: line), let type = record["type"]?.string,
                  type == "custom-title" || type == "ai-title" else { continue }
            let custom = clean(record["customTitle"])
            let name = custom.isEmpty ? clean(record["aiTitle"]) : custom
            if !name.isEmpty { return name }
        }
        return ""
    }

    /// Latest thread name Codex recorded for this session, or "".
    public static func codex(sessionID: String) -> String {
        guard !sessionID.isEmpty, let lines = try? tailLines(codexIndex, bytes: tailBytes) else { return "" }
        for line in lines.reversed() where line.contains(sessionID) {
            guard let record = try? JSON(parsing: line), record["id"]?.string == sessionID else { continue }
            return clean(record["thread_name"])
        }
        return ""
    }

    public static func lookup(source: String, sessionID: String, transcript: String) -> String {
        source == "codex" ? codex(sessionID: sessionID) : claude(transcript: transcript)
    }
}
