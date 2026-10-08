// When the user stopped a turn with Esc.
//
// Neither agent sends a hook event for it, so the board would go on saying the
// conversation runs. Both write it into the session record, though:
// - Claude Code adds a user message that reads "[Request interrupted by user]",
//   or "[Request interrupted by user for tool use]" when a tool was turned down.
// - Codex adds a `turn_aborted` event.

import Foundation

public enum Interrupted {
    // The record is the last thing written until the next prompt, so it is near the end.
    private static let tailBytes = 262_144
    private static let claudeText = "[Request interrupted by user"

    /// When the latest interruption in a session record happened, or 0 when the part
    /// in reach has none. A conversation that went on afterwards started its turn later.
    public static func at(source: String, transcript: String) -> Double {
        guard transcript.hasSuffix(".jsonl"), let lines = try? tailLines(transcript, bytes: tailBytes) else { return 0 }
        let mark = source == "codex" ? "\"turn_aborted\"" : claudeText
        for line in lines.reversed() where line.contains(mark) {
            // What a tool printed can hold the same words; only the record's own fields count.
            guard let record = try? JSON(parsing: line), source == "codex" ? codex(record) : claude(record) else { continue }
            let at = UsageReader.iso(record["timestamp"])
            if at > 0 { return at }
        }
        return 0
    }

    private static func claude(_ record: JSON) -> Bool {
        guard record["type"]?.string == "user", record["isSidechain"]?.truthy != true,
              let first = record["message"]?["content"]?.array?.first else { return false }
        return first["type"]?.string == "text" && (first["text"]?.string ?? "").hasPrefix(claudeText)
    }

    private static func codex(_ record: JSON) -> Bool {
        record["type"]?.string == "event_msg" && record["payload"]?["type"]?.string == "turn_aborted"
    }
}
