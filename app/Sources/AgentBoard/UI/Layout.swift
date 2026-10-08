// What every page is built from: the page itself, the groups on it, and the rows in a group.

import AppKit
import SwiftUI

/// The window's few colours of its own. Everything else is the system's.
enum Tone {
    /// The window, behind the sidebar.
    static let desk = Color(light: 0xF2F2F0, dark: 0x151515)
    /// The page that lies on it.
    static let paper = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    /// A hairline: the edge of a group, the rule between two rows.
    static let line = Color.primary.opacity(0.08)
    /// What sets a group apart from the page.
    static let wash = Color.primary.opacity(0.025)
}

extension Color {
    init(light: Int, dark: Int) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A page: its name and what it is for, then its groups, in a column that stays readable in a wide window.
struct PageView<Content: View>: View {
    let page: Page
    @ViewBuilder var content: Content

    /// How much of the page is under the window's bar: the bar is 52 high and the page starts 8 down.
    private static var bar: CGFloat { 44 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.system(size: 22, weight: .semibold))
                    Text(page.summary).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                content
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, PageView.bar)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
        // The window's bar lies over the top of the page and takes the clicks there, so what scrolls
        // under it fades out rather than staying in view where it cannot be pressed.
        .overlay(alignment: .top) {
            LinearGradient(stops: [.init(color: Tone.paper, location: 0.35), .init(color: Tone.paper.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: PageView.bar).allowsHitTesting(false)
        }
    }
}

/// A group of rows with a rule between each two, a name above it and a note below when it has them.
struct Card<Content: View, Footer: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            _VariadicView.Tree(Rows()) { content }
                .background(Tone.wash, in: shape)
                .overlay(shape.strokeBorder(Tone.line))
            footer.font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }
}

extension Card where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

/// Lays a group's rows out one under another. It is given the rows one by one, so it can rule between them.
private struct Rows: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id { Rectangle().fill(Tone.line).frame(height: 1).padding(.horizontal, 14) }
                child.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }
}

/// One setting or one fact: what it is on the left, with a line saying more when that helps; its control or value on the right.
struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    var health: Health?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, _ detail: String? = nil, health: Health? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.health = health
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let health = health { Dot(health: health).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail = detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension Row where Trailing == ValueText {
    /// A fact that is only read.
    init(_ title: String, _ detail: String? = nil, health: Health? = nil, value: String) {
        self.init(title, detail, health: health) { ValueText(value) }
    }
}

extension Row where Trailing == Switch {
    /// A setting that is on or off.
    init(_ title: String, _ detail: String? = nil, health: Health? = nil, isOn: Binding<Bool>) {
        self.init(title, detail, health: health) { Switch(title: title, isOn: isOn) }
    }
}

struct ValueText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Switch: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

struct Dot: View {
    let health: Health

    var body: some View {
        Circle().fill(health.color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}
