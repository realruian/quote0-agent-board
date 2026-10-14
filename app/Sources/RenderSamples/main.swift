// Draws the README's example frames from made-up data, with the renderer the app uses,
// so the pictures match the screen dot for dot. scripts/render_samples.py runs it.
//
//     swift run --package-path app RenderSamples <folder> <unix time>

import BoardCore
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let now = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: RenderSamples <folder> <unix time>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])
let hour = 3600.0, day = 86400.0
let usage: Usage = [
    "claude": AgentUsage(windows: [fiveHour: QuotaLeft(left: 36, resetsAt: now + 4.3 * hour), sevenDay: QuotaLeft(left: 73, resetsAt: now + 2 * day)],
                         observedAt: now),
    "codex": AgentUsage(windows: [sevenDay: QuotaLeft(left: 95, resetsAt: now + 5 * day)], observedAt: now),
]
// The waiting example has waited a few minutes, so its time reads as it would on a desk.
for (kind, waited) in [("list", 0.0), ("wait", 5 * 60.0), ("idle", 0.0)] {
    let view = buildView(sampleBoard(kind, now: now - waited), now: now, usage: usage, power: samplePower)
    do {
        try render(view).png.write(to: folder.appendingPathComponent("\(kind).png"))
    } catch {
        FileHandle.standardError.write(Data("\(kind): \(error)\n".utf8))
        exit(1)
    }
}
