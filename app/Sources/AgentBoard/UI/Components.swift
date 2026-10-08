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
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(7)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: maxWidth)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityLabel("墨水屏画面")
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
            Circle().fill(health.color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
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

/// Banners as the first group of a page's form. They are rows of the form itself:
/// anything stacked above the form, or inset into its safe area, makes the page taller
/// than the window and pushes the top of it under the title bar.
struct BannerRows: View {
    let items: [BannerItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if let title = item.actionTitle { Button(title, action: item.action) }
                    }
                }
            }
        }
    }
}

/// The note under a group of settings.
struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's name with a line under it that says what the setting does.
struct RowLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail = detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", value: $draft, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
                    .onSubmit(commit)
                Stepper("", value: $draft, in: range).labelsHidden()
                Text(unit).foregroundStyle(.secondary)
            }
        } label: {
            RowLabel(title, detail)
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
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
    }
}

/// The short message that confirms a change, or says why it was not made.
struct NoticeView: View {
    let notice: Notice

    var body: some View {
        Label(notice.text, systemImage: notice.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
            .symbolRenderingMode(.multicolor)
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
