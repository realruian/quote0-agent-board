// Pieces the pages share.

import AppKit
import BoardCore
import SwiftUI

extension View {
    /// Liquid Glass where the system has it, the older frosted material where it does not.
    @ViewBuilder
    func glass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// The system's glass button on macOS 26 and later, its bordered button before.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// One of the window's icons, in the colour of the text around it.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 16

    private static var drawn: [Icon: NSImage] = [:]

    init(_ icon: Icon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(nsImage: image).renderingMode(.template).resizable().frame(width: size, height: size).accessibilityHidden(true)
    }

    private var image: NSImage {
        if let image = IconView.drawn[icon] { return image }
        let image = NSImage(data: Data(icon.svg.utf8)) ?? NSImage()
        image.isTemplate = true
        IconView.drawn[icon] = image
        return image
    }
}

/// The frame as the e-ink screen shows it: every dot kept sharp, in a dark bezel.
struct ScreenView: View {
    let image: NSImage?
    var maxWidth: CGFloat = 460

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).interpolation(.none).resizable().aspectRatio(296.0 / 152.0, contentMode: .fit)
            } else {
                Rectangle().fill(.white).aspectRatio(296.0 / 152.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .padding(7)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))  // keeps its edge on a dark page
        .frame(maxWidth: maxWidth)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityLabel("墨水屏画面")
    }
}

/// How much of something is left, as a short bar and the figure. It turns orange when little is.
struct Meter: View {
    let label: String
    let percent: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(label).foregroundStyle(.secondary)
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 52, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent < 15 ? Color.orange : Color.primary.opacity(0.75)).frame(width: 52 * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            Text("\(percent)%").monospacedDigit().frame(minWidth: 32, alignment: .trailing)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)剩 \(percent)%")
    }
}

/// A state in a word, with its colour kept to a dot.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12))
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Tone.line))
    }
}

enum Health {
    case good, attention, bad, unknown

    var color: Color {
        switch self {
        case .good: return .green
        case .attention: return .orange
        case .bad: return .red
        case .unknown: return .secondary.opacity(0.5)
        }
    }
}

struct StatusLine: View {
    let health: Health
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Dot(health: health).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Something the user should know before anything else on the page, with at most one thing to do about it.
struct BannerItem: Identifiable {
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var id: String { text }
}

/// Banners, above a page's first group.
struct Banners: View {
    let items: [BannerItem]

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        IconView(.alert02).foregroundStyle(.orange).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if let title = item.actionTitle { Button(title, action: item.action).controlSize(.small) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.orange.opacity(0.07), in: shape)
                    .overlay(shape.strokeBorder(Color.orange.opacity(0.22)))
                }
            }
        }
    }
}

/// A whole number in a range, typed or stepped, saved when it changes.
struct NumberRow: View {
    let title: String
    var detail: String?
    let value: Int
    let range: ClosedRange<Int>
    let unit: String
    let save: (Int) -> Void
    @State private var draft = 0

    var body: some View {
        Row(title, detail) {
            HStack(spacing: 6) {
                TextField(title, value: $draft, format: .number).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 56).onSubmit(commit)
                Stepper(title, value: $draft, in: range).labelsHidden()
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, new in draft = new }
        .onChange(of: draft) { _, new in if range.contains(new), new != value { save(new) } }
    }

    private func commit() {
        draft = min(max(draft, range.lowerBound), range.upperBound)
    }
}

/// A time of day kept as "HH:MM", the way the board and the device both store it.
struct ClockRow: View {
    let title: String
    let value: String
    let save: (String) -> Void

    private var date: Binding<Date> {
        Binding(get: {
            let parts = value.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(hour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0)) ?? Date()
        }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            let text = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            if text != value { save(text) }
        })
    }

    var body: some View {
        Row(title) { DatePicker(title, selection: date, displayedComponents: .hourAndMinute).labelsHidden().fixedSize() }
    }
}

/// The short message that confirms a change, or says why it was not made.
struct NoticeView: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 7) {
            IconView(notice.isError ? .cancelCircle : .checkmarkCircle02).foregroundStyle(notice.isError ? .red : .green)
            Text(notice.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glass(cornerRadius: 20)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

func clock(_ timestamp: Double) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: timestamp))
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

func ago(_ timestamp: Double) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince1970 - timestamp))
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    return "\(seconds / 86400) 天前"
}

let agentName = ["claude": "Claude", "codex": "Codex"]
let waitLabel = ["permission": "等你批准", "question": "等你回答", "plan": "等你看计划"]
