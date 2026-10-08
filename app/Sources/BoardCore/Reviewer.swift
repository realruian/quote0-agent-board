// Who answers a Codex permission request: the user, or Codex's own reviewer.
//
// Codex sends PermissionRequest either way. With "auto review" on, a reviewing model
// answers within seconds and the user is never asked, so the board must not say the
// conversation waits for them. The hook payload does not say which it is; the session
// record does, in the `turn_context` Codex writes at the start of every turn.

import Foundation

public enum Reviewer {
    // Inside tool output the quotes are escaped, so this matches a record's own field only.
    private static let field = Data("\"approvals_reviewer\":\"".utf8)
    private static let chunk: UInt64 = 1 << 20
    /// A turn's record can run to many megabytes. Past this the answer is "the user".
    static var reach: UInt64 = 64 << 20

    /// True when the latest turn in a Codex session record has Codex review its own requests.
    public static func codexReviewsItself(transcript: String) -> Bool {
        guard transcript.hasSuffix(".jsonl"), let handle = FileHandle(forReadingAtPath: transcript) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var end = size
        while end > 0, size - end < reach {
            let start = end > chunk ? end - chunk : 0
            // Read a little past the chunk, so a field lying across two chunks is seen whole.
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(end - start) + 64) else { return false }
            if let found = data.range(of: field, options: .backwards) {
                return data[found.upperBound...].starts(with: Data("auto_review\"".utf8))
            }
            end = start
        }
        return false
    }
}
