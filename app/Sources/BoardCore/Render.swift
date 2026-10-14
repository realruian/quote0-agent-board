// Turn a view into a 296x152 black-and-white frame for the Quote/0.
//
// The panel has no greys. Shapes are written dot by dot; text is drawn by Core Text
// one glyph at a time, each on a whole pixel, and a dot is inked when the glyph
// covers enough of it.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

public let frameWidth = 296
public let frameHeight = 152

// One grid for every screen: the same side margin, a top bar, then rows on a fixed pitch.
private let margin = 8
private let gap = 8  // between columns
private let barY = 12
private let ruleY = 24
private let rowY = 42
private let rowPitch = 31
// One size per role, so rows never differ from each other.
private let small = 12
private let nameSize = 16
private let waitNameSize = 20
private let titleSize = 36

/// How much of a dot a glyph has to cover for the dot to be inked. Lower is bolder.
var inkCoverage = 0.42

// MARK: - fonts

/// One face in a font file; the names pick it out of a collection.
struct Face: Hashable {
    let path: String
    let family: String
    let style: String
}

public enum Fonts {
    static var arkPixel: String { Resources.directory.appendingPathComponent("fonts/ark-pixel-12px-proportional-zh_hans.otf").path }
    static var zhengGe: String { Resources.directory.appendingPathComponent("fonts/ZhengGeDianHei-16.ttf").path }
    static var chill: String { Resources.directory.appendingPathComponent("fonts/ChillBitmap_16px.ttf").path }
    static let hiraginoPath = "/System/Library/Fonts/Hiragino Sans GB.ttc"

    /// Newer macOS keeps PingFang in a downloadable-asset folder whose name changes
    /// between releases; older ones ship it with the other system fonts.
    static let pingFangPath: String = {
        let root = "/System/Library/AssetsV2"
        let manager = FileManager.default
        var found: [String] = []
        for group in (try? manager.contentsOfDirectory(atPath: root)) ?? [] where group.hasPrefix("com_apple_MobileAsset_Font") {
            for asset in (try? manager.contentsOfDirectory(atPath: "\(root)/\(group)")) ?? [] {
                let path = "\(root)/\(group)/\(asset)/AssetData/PingFang.ttc"
                if manager.fileExists(atPath: path) { found.append(path) }
            }
        }
        if let newest = found.sorted().last { return newest }
        let legacy = "/System/Library/Fonts/PingFang.ttc"
        return manager.fileExists(atPath: legacy) ? legacy : ""
    }()

    static var userFonts: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts").path }

    /// family -> (label, regular face, bold face), in the order the settings page lists them.
    static var families: [(key: String, label: String, regular: Face, bold: Face)] {
        [
            ("pingfang", "苹方", Face(path: pingFangPath, family: "PingFang SC", style: "Regular"),
             Face(path: pingFangPath, family: "PingFang SC", style: "Semibold")),
            ("misans", "MiSans", Face(path: "\(userFonts)/MiSans-Regular.otf", family: "MiSans", style: "Regular"),
             Face(path: "\(userFonts)/MiSans-Demibold.otf", family: "MiSans", style: "Demibold")),
            ("hiragino", "冬青黑体", Face(path: hiraginoPath, family: "Hiragino Sans GB", style: "W3"),
             Face(path: hiraginoPath, family: "Hiragino Sans GB", style: "W6")),
            ("arkpixel", "方舟像素", Face(path: arkPixel, family: "Ark Pixel 12px Prop zh-Hans", style: "Regular"),
             Face(path: arkPixel, family: "Ark Pixel 12px Prop zh-Hans", style: "Regular")),
            ("zhengge", "正格点黑", zhengGeFace, zhengGeFace),
            ("chill", "寒蝉点阵体", chillFace, chillFace),
        ]
    }

    private static var arkPixelFace: Face { Face(path: arkPixel, family: "Ark Pixel 12px Prop zh-Hans", style: "Regular") }
    private static var zhengGeFace: Face { Face(path: zhengGe, family: "ZhengGeDianHei 16", style: "Regular") }
    private static var chillFace: Face { Face(path: chill, family: "寒蝉点阵体", style: "16px") }

    // Pixel fonts are drawn dot by dot for one size and are only sharp at whole multiples
    // of it. A role keeps to a multiple when one is close to its size; otherwise it is drawn
    // at its own size, with uneven strokes, rather than visibly smaller than other fonts.
    // The two drawn for 16 dots take the small text from the one drawn for 12, so every
    // role has a size it is sharp at.
    static var pixelFaces: [String: [(unit: Int, face: Face)]] {
        ["arkpixel": [(12, arkPixelFace)], "zhengge": [(12, arkPixelFace), (16, zhengGeFace)], "chill": [(12, arkPixelFace), (16, chillFace)]]
    }
    static let pixelSnap = 0.85  // how far below a role's size a multiple may fall and still be used

    // Used when the chosen family is not installed, so a frame can always be drawn:
    // two system fonts, then the font that ships with the app.
    static var fallbacks: [Face] {
        [Face(path: hiraginoPath, family: "Hiragino Sans GB", style: "W3"),
         Face(path: "/System/Library/Fonts/STHeiti Medium.ttc", family: "Heiti SC", style: "Medium"),
         Face(path: arkPixel, family: "Ark Pixel 12px Prop zh-Hans", style: "Regular")]
    }

    // Drawn in place of single characters the chosen font has no glyph for. The pixel font
    // drawn for 12 dots lacks about one common Chinese character in twenty. A pixel font
    // looks first to the one with the most characters, at the sizes that one is sharp at.
    static func substitutes(_ family: String, size: Int) -> [Face] {
        (pixelFaces[family] != nil && size % 16 == 0 ? [chillFace] : []) + [fallbacks[0], fallbacks[1], families[0].regular]
    }

    public static func available() -> [(key: String, label: String)] {
        families.filter { FileManager.default.fileExists(atPath: $0.regular.path) }.map { ($0.key, $0.label) }
    }

    private static var descriptors: [Face: CTFontDescriptor] = [:]
    private static var sized: [String: CTFont] = [:]

    private static func descriptor(_ face: Face) -> CTFontDescriptor? {
        if let known = descriptors[face] { return known }
        guard !face.path.isEmpty, FileManager.default.fileExists(atPath: face.path),
              let all = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: face.path) as CFURL) as? [CTFontDescriptor],
              !all.isEmpty else { return nil }
        func attribute(_ descriptor: CTFontDescriptor, _ name: CFString) -> String {
            CTFontDescriptorCopyAttribute(descriptor, name) as? String ?? ""
        }
        let match = all.first {
            attribute($0, kCTFontFamilyNameAttribute) == face.family && attribute($0, kCTFontStyleNameAttribute) == face.style
        } ?? all[0]
        descriptors[face] = match
        return match
    }

    static func font(_ face: Face, size: Int) -> CTFont? {
        let key = "\(face.path)|\(face.family)|\(face.style)|\(size)"
        if let known = sized[key] { return known }
        guard let descriptor = descriptor(face) else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
        sized[key] = font
        return font
    }

    /// The face for a role in the chosen family, or the first fallback that is installed.
    static func load(_ family: String, size: Int, bold: Bool) -> CTFont {
        var size = size
        var drawn: Face?
        if let faces = pixelFaces[family] {
            // The face whose multiple comes nearest the role's size; of two as near, the one enlarged less.
            let sharp = faces.map { (face: $0.face, size: max(1, Int((Double(size) / Double($0.unit)).rounded())) * $0.unit, unit: $0.unit) }
                .filter { Double($0.size) >= Double(size) * pixelSnap }
                .min { (abs($0.size - size), $0.size / $0.unit) < (abs($1.size - size), $1.size / $1.unit) }
            drawn = sharp?.face
            if let sharp = sharp { size = sharp.size }
        }
        let chosen = families.first { $0.key == family } ?? families[2]
        for face in [drawn ?? (bold ? chosen.bold : chosen.regular)] + fallbacks {
            if let font = font(face, size: size) { return font }
        }
        return CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)  // every Mac has it; Chinese will not show
    }
}

// MARK: - marks

// 14x14 marks, dot by dot for a screen with no greys: Claude's spark and the OpenAI
// knot (the icon the Codex app shows in the Dock). Other agents get their initial.
private let iconSize = 14
private let tagSize = 18
private let icons: [String: [String]] = [
    "Claude": [
        "...##...#.....",
        "...##..##.....",
        "....##.##.##..",
        ".##..#.#.##...",
        "..#########...",
        "....######..##",
        "##...#########",
        ".###########..",
        "....######.###",
        "..##.######...",
        "..#.##.#####..",
        "....#.##.#....",
        "...#..#...#...",
        "......#.......",
    ],
    "Codex": [
        "....####......",
        "...##..#####..",
        "..##..##...##.",
        ".##..#..##..#.",
        "#.#.#####.###.",
        "#.#..####..##.",
        "#.##.#..###..#",
        "#..###..#.##.#",
        ".##..####..#.#",
        ".###.#####.#.#",
        ".#..##..#..##.",
        ".##...##..##..",
        "..#####..##...",
        "......####....",
    ],
]

/// The tag's square with its corners taken off: which dots of an 18x18 box belong to it, and which to its edge.
private func inTag(_ x: Int, _ y: Int) -> (inside: Bool, edge: Bool) {
    let dx = min(x, tagSize - 1 - x), dy = min(y, tagSize - 1 - y)
    let inside = dx + dy >= 2
    let edge = inside && (dx == 0 || dy == 0 || dx + dy == 2)
    return (inside, edge)
}

// MARK: - canvas

private final class Canvas {
    let context: CGContext
    let pixels: UnsafeMutablePointer<UInt8>
    let stride: Int
    let paper: UInt8
    let ink: UInt8
    let family: String
    private var reversed: [(x0: Int, y0: Int, x1: Int, y1: Int)] = []  // boxes of text in reverse

    init(family: String, inverted: Bool) {
        context = CGContext(data: nil, width: frameWidth, height: frameHeight, bitsPerComponent: 8, bytesPerRow: frameWidth,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        stride = context.bytesPerRow
        paper = inverted ? 0 : 255
        ink = inverted ? 255 : 0
        self.family = family
        for i in 0..<(stride * frameHeight) { pixels[i] = paper }
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setShouldSubpixelQuantizeFonts(false)
    }

    func font(_ size: Int, bold: Bool = false) -> CTFont { Fonts.load(family, size: size, bold: bold) }

    func dot(_ x: Int, _ y: Int, _ value: UInt8) {
        if x >= 0, x < frameWidth, y >= 0, y < frameHeight { pixels[y * stride + x] = value }
    }

    /// A filled box; both corners are part of it.
    func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8? = nil) {
        for y in y0...y1 { for x in x0...x1 { dot(x, y, value ?? ink) } }
    }

    func outline(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        fill(x0, y0, x1, y0)
        fill(x0, y1, x1, y1)
        fill(x0, y0, x0, y1)
        fill(x1, y0, x1, y1)
    }

    // -- text --

    private struct Glyph {
        let font: CTFont
        let glyph: CGGlyph
        let advance: Int
    }

    private func glyphs(_ text: String, _ font: CTFont) -> [Glyph] {
        let size = Int(CTFontGetSize(font).rounded())
        var out: [Glyph] = []
        for character in text {
            let units = Array(String(character).utf16)
            var found = [CGGlyph](repeating: 0, count: units.count)
            var face = font
            if !CTFontGetGlyphsForCharacters(font, units, &found, units.count) && !character.isWhitespace {
                // The chosen font has no drawing for this character: take it from the first substitute that has.
                for candidate in Fonts.substitutes(family, size: size) {
                    guard let other = Fonts.font(candidate, size: size) else { continue }
                    var theirs = [CGGlyph](repeating: 0, count: units.count)
                    if CTFontGetGlyphsForCharacters(other, units, &theirs, units.count) {
                        face = other
                        found = theirs
                        break
                    }
                }
            }
            let drawn = found.filter { $0 != 0 }
            for glyph in drawn.isEmpty ? [0] : drawn {
                var one = glyph
                // Whole-pixel steps, so every glyph starts on a dot and letters keep an even rhythm.
                let advance = CTFontGetAdvancesForGlyphs(face, .horizontal, &one, nil, 1)
                out.append(Glyph(font: face, glyph: glyph, advance: Int(advance.rounded())))
            }
        }
        return out
    }

    func length(_ text: String, _ font: CTFont) -> Int {
        glyphs(text, font).reduce(0) { $0 + $1.advance }
    }

    enum Anchor { case left, middle, right }

    /// One line of text. `y` is where its vertical middle goes: half way between the
    /// font's ascent and descent, so different sizes on one row line up.
    func text(_ x: Int, _ y: Int, _ text: String, _ font: CTFont, _ anchor: Anchor = .left, value: UInt8? = nil) {
        let run = glyphs(text, font)
        let width = run.reduce(0) { $0 + $1.advance }
        var pen = x
        switch anchor {
        case .left: break
        case .middle: pen -= Int((Double(width) / 2).rounded())
        case .right: pen -= width
        }
        let ascent = Int(ceil(CTFontGetAscent(font))), descent = Int(ceil(CTFontGetDescent(font)))
        let baseline = y + Int(floor(Double(ascent - descent) / 2 + 0.5))
        context.setFillColor(gray: CGFloat(value ?? ink) / 255, alpha: 1)
        for item in run {
            var glyph = item.glyph
            var at = CGPoint(x: CGFloat(pen), y: CGFloat(frameHeight - baseline))
            CTFontDrawGlyphs(item.font, &glyph, &at, 1, context)
            pen += item.advance
        }
    }

    /// As much of `text` as fills one line, and the rest. A Latin word is not cut in two
    /// when there is a space to break at instead.
    func split(_ text: String, _ font: CTFont, _ maxWidth: Int) -> (String, String) {
        var first = ""
        for character in text {
            if length(first + String(character), font) > maxWidth { break }
            first.append(character)
        }
        var rest = String(text.dropFirst(first.count))
        if let next = rest.first, let last = first.last, next.isASCII && next.isLetter && last.isASCII && last.isLetter,
           let space = first.lastIndex(of: " "), first.distance(from: first.startIndex, to: space) > first.count / 2 {
            rest = String(first[first.index(after: space)...]) + rest
            first = String(first[..<space])
        }
        return (first, rest.trimmingCharacters(in: .whitespaces))
    }

    func fit(_ text: String, _ font: CTFont, _ maxWidth: Int) -> String {
        if length(text, font) <= maxWidth { return text }
        var text = text
        while !text.isEmpty && length(text + "…", font) > maxWidth { text.removeLast() }
        return text + "…"
    }

    // -- marks --

    /// The agent's mark with its top-left corner at (x, y).
    func mark(_ x: Int, _ y: Int, _ agent: String, _ value: UInt8) {
        guard let rows = icons[agent] else {
            initial(x, y, agent, value)
            return
        }
        for (dy, row) in rows.enumerated() {
            for (dx, cell) in row.enumerated() where cell == "#" { dot(x + dx, y + dy, value) }
        }
    }

    private func initial(_ x: Int, _ y: Int, _ agent: String, _ value: UInt8) {
        context.saveGState()
        defer { context.restoreGState() }
        let font = self.font(small, bold: true)
        let letter = String(agent.prefix(1))
        let width = length(letter, font)
        let ascent = Int(ceil(CTFontGetAscent(font))), descent = Int(ceil(CTFontGetDescent(font)))
        let baseline = y + iconSize / 2 + Int(floor(Double(ascent - descent) / 2 + 0.5))
        context.setFillColor(gray: CGFloat(value) / 255, alpha: 1)
        var pen = x + iconSize / 2 - width / 2
        for item in glyphs(letter, font) {
            var glyph = item.glyph
            var at = CGPoint(x: CGFloat(pen), y: CGFloat(frameHeight - baseline))
            CTFontDrawGlyphs(item.font, &glyph, &at, 1, context)
            pen += item.advance
        }
    }

    /// The agent's mark in a small square centred on y: solid while the conversation
    /// is at work, outlined once it has finished. Returns the square's right edge.
    func tag(_ x: Int, _ y: Int, _ agent: String, solid: Bool) -> Int {
        let half = tagSize / 2, inset = (tagSize - iconSize) / 2
        for dy in 0..<tagSize {
            for dx in 0..<tagSize {
                let (inside, edge) = inTag(dx, dy)
                if inside { dot(x + dx, y - half + dy, solid || edge ? ink : paper) }
            }
        }
        mark(x + inset, y - half + inset, agent, solid ? paper : ink)
        return x + tagSize
    }

    // -- result --

    /// Settle every dot on black or white. Text was drawn with soft edges; a dot is
    /// inked when enough of it was covered.
    /// Inside a box of reversed text it is the text that is drawn thin, so there a dot
    /// is left as paper when enough of it was.
    func settle() {
        let cut = inkCoverage * 255
        for i in 0..<(stride * frameHeight) {
            let covered = ink == 0 ? 255 - Double(pixels[i]) : Double(pixels[i])
            let x = i % stride, y = i / stride
            if reversed.contains(where: { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 }) {
                pixels[i] = 255 - covered > cut ? paper : ink
            } else {
                pixels[i] = covered > cut ? ink : paper
            }
        }
    }

    func reverse(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        fill(x0, y0, x1, y1)
        reversed.append((x0, y0, x1, y1))
    }
}

// MARK: - frames

/// A rendered frame: one byte per dot, 0 for black and 255 for white, row by row from the top.
public struct Frame: Equatable {
    public let pixels: [UInt8]

    public var png: Data {
        var copy = pixels
        let image = copy.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: frameWidth, height: frameHeight, bitsPerComponent: 8, bytesPerRow: frameWidth,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        let data = NSMutableData()
        guard let image = image, let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// For tests: how wide a string comes out, and how it is cut to fit.
func textWidth(_ text: String, family: String, size: Int, bold: Bool) -> Int {
    let canvas = Canvas(family: family, inverted: false)
    return canvas.length(text, canvas.font(size, bold: bold))
}

func fittedSplit(_ text: String, family: String = "pingfang", size: Int = 16, bold: Bool = true, width: Int) -> [String] {
    let canvas = Canvas(family: family, inverted: false)
    let (first, rest) = canvas.split(text, canvas.font(size, bold: bold), width)
    return [first, rest]
}

func fitted(_ text: String, family: String, size: Int, bold: Bool, width: Int) -> String {
    let canvas = Canvas(family: family, inverted: false)
    return canvas.fit(text, canvas.font(size, bold: bold), width)
}

private let renderLock = NSLock()  // the pusher and the settings page draw from different threads, and share the font cache

public func render(_ view: FrameView) -> Frame {
    renderLock.lock()
    defer { renderLock.unlock() }
    let canvas = Canvas(family: view.font.isEmpty ? Settings().font : view.font, inverted: view.kind == .wait)
    draw(view, on: canvas)
    canvas.settle()
    return Frame(pixels: Array(UnsafeBufferPointer(start: canvas.pixels, count: frameWidth * frameHeight)))
}

/// The top bar's name on the left and a word on the right, which ends at `end`.
private func header(_ c: Canvas, _ right: String, end: Int = frameWidth - margin) {
    c.text(margin, barY, "AGENTS", c.font(small, bold: true))
    if !right.isEmpty { c.text(end, barY, right, c.font(small), .right) }
}

private let bolt = ["...##", "..##.", ".##..", "#####", "..##.", ".##..", "##..."]

/// The device's charge in the top right corner: the figure, then a battery filled to it, with
/// a bolt in front while on power. In reverse when it wants charging. Returns where the rest
/// of the bar has to end.
private func powerMark(_ c: Canvas, _ power: DevicePower) -> Int {
    let font = c.font(small)
    let figure = power.percent.map { "\($0)%" } ?? ""
    let body = 14, nub = 2, height = 8
    let pad = power.low ? alarmPad : 0
    let figureWidth = figure.isEmpty ? 0 : c.length(figure, font) + 3
    let boltWidth = power.plugged ? bolt[0].count + 3 : 0
    let right = frameWidth - margin
    let left = right - (boltWidth + figureWidth + body + nub + 2 * pad) + 1
    if power.low { c.reverse(left, barY - 7, right, barY + 6) }
    let value = power.low ? c.paper : c.ink
    var x = left + pad
    if power.plugged {
        for (dy, row) in bolt.enumerated() {
            for (dx, cell) in row.enumerated() where cell == "#" { c.dot(x + dx, barY - 3 + dy, value) }
        }
        x += boltWidth
    }
    if !figure.isEmpty {
        c.text(x, barY, figure, font, value: value)
        x += figureWidth
    }
    let top = barY - height / 2, bottom = top + height - 1
    c.fill(x, top, x + body - 1, top, value)
    c.fill(x, bottom, x + body - 1, bottom, value)
    c.fill(x, top, x, bottom, value)
    c.fill(x + body - 1, top, x + body - 1, bottom, value)
    c.fill(x + body, top + 2, x + body + nub - 1, bottom - 2, value)
    let level = power.percent ?? (power.plugged ? 100 : 0)
    let filled = Int((Double(body - 4) * Double(level) / 100).rounded())
    if filled > 0 { c.fill(x + 2, top + 2, x + 1 + filled, bottom - 2, value) }
    return left - gap
}

/// Text in reverse, on a black box that reaches `pad` dots past it on either side.
private func alarm(_ c: Canvas, _ x: Int, _ y: Int, _ text: String, _ font: CTFont, to right: Int? = nil) {
    let width = c.length(text, font)
    c.reverse(x, y - 7, right ?? x + width + 2 * alarmPad - 1, y + 6)
    c.text(x + alarmPad, y, text, font, value: c.paper)
}

private let alarmPad = 2

/// Top bar while agents are working: per agent its mark, then what is left of each
/// window and when that window resets, e.g. `5h 36% 14:30  7d 73% 周六`. A window
/// that will run out before it resets says when instead, in reverse: `5h 36% 13:20用完`.
private func quotaHeader(_ c: Canvas, _ quota: [QuotaEntry], end: Int = frameWidth - margin) {
    let font = c.font(small)

    // resets: 2 = every window shows its reset, 1 = only the first of each agent, 0 = none
    func texts(_ resets: Int) -> [[(text: String, alarm: Bool)]] {
        quota.map { entry in
            let parts = entry.rows.enumerated().map { index, row in
                row.runsOut.isEmpty
                    ? ([row.short, "\(row.left)%", index < resets ? row.reset : ""].filter { !$0.isEmpty }.joined(separator: " "), false)
                    : ("\(row.short) \(row.left)% \(row.runsOut)用完", true)
            }
            return parts.isEmpty ? [("—", false)] : parts
        }
    }
    let spacer = c.length("  ", font)
    func width(_ parts: [(text: String, alarm: Bool)]) -> Int {
        parts.reduce(0) { $0 + c.length($1.text, font) + ($1.alarm ? 2 * alarmPad : 0) } + spacer * (parts.count - 1)
    }
    func draw(_ parts: [(text: String, alarm: Bool)], from x: Int) {
        var x = x
        for part in parts {
            if part.alarm { alarm(c, x, barY, part.text, font) } else { c.text(x, barY, part.text, font) }
            x += width([part]) + spacer
        }
    }

    let fits = { (agents: [[(text: String, alarm: Bool)]]) in agents.reduce(0) { $0 + iconSize + 4 + width($1) } + gap <= end - margin }
    let parts = [2, 1, 0].map(texts).first(where: fits) ?? texts(0)
    let top = barY - iconSize / 2
    c.mark(margin, top, quota[0].agent, c.ink)
    draw(parts[0], from: margin + iconSize + 4)
    let rightX = end - width(parts[1])
    draw(parts[1], from: rightX)
    c.mark(rightX - 4 - iconSize, top, quota[1].agent, c.ink)
}

/// The first window that will run out before it resets, said in full for the idle screen.
private func runsOutLine(_ quota: [QuotaEntry]) -> String? {
    for entry in quota {
        for row in entry.rows where !row.runsOut.isEmpty {
            return "\(entry.agent) \(row.window)额度约 \(row.runsOut) 用完" + (row.reset.isEmpty ? "" : "，\(row.reset) 才重置")
        }
    }
    return nil
}

/// Idle screen: one bar per quota window, showing what is left and when it resets.
private func quotaPanel(_ c: Canvas, _ quota: [QuotaEntry]) {
    let labelX = margin + iconSize + gap, barX = 76, barWidth = 84
    var y = 40
    for entry in quota {
        c.mark(margin, y - iconSize / 2, entry.agent, c.ink)
        if entry.rows.isEmpty {
            c.text(labelX, y, "暂无数据", c.font(small))
            y += 22
        }
        for row in entry.rows {
            c.text(labelX, y, row.window, c.font(small))
            c.outline(barX, y - 5, barX + barWidth, y + 5)
            let filled = Int((Double(barWidth - 4) * Double(row.left) / 100).rounded())
            if filled > 0 { c.fill(barX + 2, y - 3, barX + 2 + filled, y + 3) }
            c.text(barX + barWidth + gap, y, "\(row.left)%", c.font(small, bold: true))
            if !row.reset.isEmpty { c.text(frameWidth - margin, y, "\(row.reset) 重置", c.font(small), .right) }
            y += 22
        }
    }
}

private func draw(_ view: FrameView, on c: Canvas) {
    switch view.kind {
    case .wait:
        header(c, view.since, end: view.power.map { powerMark(c, $0) } ?? frameWidth - margin)
        c.text(margin, 52, view.title, c.font(titleSize, bold: true))
        // The conversation's name in large type when it fits on a line; otherwise in row type
        // on two, which the space between the title and the foot has room for.
        let large = c.font(waitNameSize, bold: true), width = frameWidth - margin - (margin + tagSize + gap)
        if c.length(view.task, large) <= width {
            let nameX = c.tag(margin, 98, view.agent, solid: true) + gap
            c.text(nameX, 98, view.task, large)
        } else {
            let font = c.font(nameSize, bold: true)
            let (first, rest) = c.split(view.task, font, width)
            let top = rest.isEmpty ? 98 : 92  // one line of row type sits where the large one would
            let nameX = c.tag(margin, top, view.agent, solid: true) + gap
            c.text(nameX, top, first, font)
            if !rest.isEmpty { c.text(nameX, top + 21, c.fit(rest, font, width), font) }
        }
        let footer = [view.detail, view.footer].filter { !$0.isEmpty }.joined(separator: " · ")
        c.text(margin, 136, c.fit(footer, c.font(small), frameWidth - 2 * margin), c.font(small))
        return
    case .test:
        c.outline(0, 0, frameWidth - 1, frameHeight - 1)
        for (x, y) in [(4, 4), (frameWidth - 16, 4), (4, frameHeight - 16), (frameWidth - 16, frameHeight - 16)] {
            c.fill(x, y, x + 11, y + 11)
        }
        c.text(frameWidth / 2, 66, "测试画面", c.font(28, bold: true), .middle)
        c.text(frameWidth / 2, 100, view.note, c.font(13), .middle)
        return
    case .list, .idle, .quiet:
        break
    }

    let quota = view.quota ?? []
    let end = view.power.map { powerMark(c, $0) } ?? frameWidth - margin
    if view.kind == .list, !quota.isEmpty {
        quotaHeader(c, quota, end: end)
    } else {
        header(c, view.kind == .idle ? "空闲" : view.summary, end: end)
    }
    // Conversations that did not fit are counted at the end of the rule.
    var ruleEnd = frameWidth - margin
    if view.kind == .list, view.more > 0 {
        let more = "+\(view.more)"
        c.text(frameWidth - margin, ruleY, more, c.font(small, bold: true), .right)
        ruleEnd -= c.length(more, c.font(small, bold: true)) + 4
    }
    c.fill(margin, ruleY, ruleEnd, ruleY)

    if view.kind == .idle, !quota.isEmpty {
        quotaPanel(c, quota)
        // running out before the reset matters more than what was done last
        if let warning = runsOutLine(quota) {
            alarm(c, margin, 139, c.fit(warning, c.font(small), frameWidth - 2 * margin - 2 * alarmPad), c.font(small), to: frameWidth - margin)
        } else if !view.last.isEmpty {
            c.text(margin, 139, c.fit(view.last, c.font(small), frameWidth - 2 * margin), c.font(small))
        }
        return
    }

    if view.kind != .list {
        c.text(frameWidth / 2, 78, view.line, c.font(18, bold: true), .middle)
        if !view.last.isEmpty { c.text(frameWidth / 2, 108, c.fit(view.last, c.font(12), frameWidth - 24), c.font(12), .middle) }
        return
    }

    // One line per conversation, in three columns that hold their place from row to row:
    // the agent's tag, the conversation's name, and how long it has run on the right.
    let smallFont = c.font(small), nameFont = c.font(nameSize, bold: true)
    let nameX = margin + tagSize + gap
    let whenWidth = ["<5m", "59m", "等你", "出错"].map { c.length($0, smallFont) }.max() ?? 0
    let nameWidth = frameWidth - margin - whenWidth - gap - nameX
    var y = rowY
    for row in view.rows {
        _ = c.tag(margin, y, row.agent, solid: row.state == .running || row.state == .waiting)
        c.text(nameX, y, c.fit(row.title, nameFont, nameWidth), nameFont)
        c.text(frameWidth - margin, y, row.when, smallFont, .right)
        y += rowPitch
    }
}
