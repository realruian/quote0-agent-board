// The window's sizes of text and steps of space. Pages use these names, not numbers,
// so a role looks the same wherever it appears and changes in one place.

import SwiftUI

extension Font {
    /// A page's name.
    static let pageTitle = Font.system(size: 22, weight: .semibold)
    /// The one thing a page leads with, such as the overview's state. Body size, set apart by weight.
    static let emphasis = Font.system(size: 13, weight: .semibold)
    /// Saying more: under a row, under a group, beside a control.
    static let detail = Font.system(size: 12)
    /// A name over a group, and the state at the foot of the sidebar.
    static let label = Font.system(size: 12, weight: .medium)
    /// The least that is still read: a version, a heading in the sidebar, log lines.
    static let note = Font.system(size: 11)
    /// The log, where columns line up.
    static let log = Font.system(size: 11, design: .monospaced)
}

/// Steps of space, on a grid of four. `hairline` only binds a line to the one it belongs to.
enum Space {
    static let hairline: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// The widest a run of explanation goes: about 38 Chinese characters at the detail size,
/// short enough for the eye to find the next line.
let readingWidth: CGFloat = 460

/// Leading added between the lines of wrapped detail text, which sets it at about 1.5 times its size.
let detailLeading: CGFloat = 3

extension View {
    /// Explanatory text: the detail size, secondary, with room between its lines and a readable width.
    func explanation() -> some View {
        font(.detail).foregroundStyle(.secondary).lineSpacing(detailLeading)
            .frame(maxWidth: readingWidth, alignment: .leading)
    }
}
