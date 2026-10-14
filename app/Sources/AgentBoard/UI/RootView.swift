// The window: the pages listed down the side, the chosen one on a sheet of paper beside them.

import BoardCore
import Combine
import SwiftUI

struct RootView: View {
    @ObservedObject var model: BoardModel
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var page: Page { model.page ?? .overview }

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: 18, style: .continuous)  // as round as the window it lies in
        HStack(spacing: 0) {
            Sidebar(model: model).frame(width: 204)
            detail
                .id(page)  // each page starts at its top
                .background(Tone.paper)
                .overlay(alignment: .bottom) {
                    if let notice = model.notice { NoticeView(notice: notice) }
                }
                .animation(.spring(duration: 0.3), value: model.notice)
                .clipShape(paper)
                .overlay(paper.strokeBorder(Tone.line))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                .padding([.top, .trailing, .bottom], 8)
        }
        .background(Tone.desk)
        .ignoresSafeArea()
        .onReceive(tick) { _ in model.refresh() }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .overview: OverviewPage(model: model)
        case .display: DisplayPage(model: model)
        case .refresh: RefreshPage(model: model)
        case .alerts: AlertsPage(model: model)
        case .conversations: ConversationsPage(model: model)
        case .usage: UsagePage(model: model)
        case .device: DevicePage(model: model)
        case .diagnostics: DiagnosticsPage(model: model)
        case .about: AboutPage(model: model)
        case .setup: SetupPage(model: model)
        }
    }
}

/// The pages, and under them how the board is doing. The rows are drawn here rather than
/// by a system list: a list paints its selection differently while it holds the keyboard,
/// and the row blinked each time a page took the keyboard back from it.
private struct Sidebar: View {
    @ObservedObject var model: BoardModel
    private let pages: [Page] = [.overview, .display, .alerts, .conversations, .usage, .refresh, .device]
    private let advanced: [Page] = [.diagnostics, .about]

    /// Connecting a device is reached from the device page, so that is the row it belongs to.
    private var current: Page { model.page == .setup ? .device : model.page ?? .overview }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pages) { row($0) }
            Text("高级").font(.note.weight(.medium)).foregroundStyle(.tertiary)
                .padding(.leading, Space.m).padding(.top, Space.l).padding(.bottom, Space.xs)
            ForEach(advanced) { row($0) }
            Spacer(minLength: Space.m)
            ScreenStatus(model: model)
        }
        .padding(.horizontal, Space.s)
        .padding(.top, 52)  // clear of the window's three buttons
        .padding(.bottom, Space.l)
    }

    /// ⌘1, ⌘2 and so on go down the list.
    private func row(_ page: Page) -> some View {
        let number = (pages + advanced).firstIndex(of: page).map { $0 + 1 } ?? 0
        return SidebarRow(page: page, selected: page == current) { model.page = page }
            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
    }

}

/// At the foot of the sidebar, on every page: what the screen is doing, and the one thing to do about it.
private struct ScreenStatus: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        let status = model.status
        HStack(alignment: .center, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Dot(health: health).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                    // the state is read in full: two lines when it needs them, never cut
                    Text(headline).font(.label).monospacedDigit().foregroundStyle(.primary)
                        .lineLimit(2).lineSpacing(Space.hairline).fixedSize(horizontal: false, vertical: true).help(headline)
                }
                Text("v\(model.console.version)").font(.note).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.leading, 7 + Space.s)  // under the words, past the dot
            }
            Spacer(minLength: Space.xs)
            if status.paused {
                Button("恢复") { model.apply(["paused": false], quietly: true) }.controlSize(.small)
            } else if status.needsSetup {
                Button("连接") { model.page = .setup }.controlSize(.small)
            } else {
                Button(action: model.refreshScreen) { IconView(.refresh, size: 14) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("刷新屏幕（⌘R）").accessibilityLabel("刷新屏幕")
                    .disabled(status.dryRun)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var headline: String {
        if model.status.paused { return "已暂停，屏幕不更新" }
        if model.status.quiet { return "夜间免打扰中" }
        return model.screenLine()
    }

    private var health: Health {
        let status = model.status
        if status.needsSetup || status.paused || status.quiet { return .attention }
        switch status.screen {
        case .failed: return .bad
        case .waitingForDevice: return .attention
        case .sending: return status.lastPush?.delivered == false ? .attention : .good
        case .current: return .good
        }
    }
}

private struct SidebarRow: View {
    let page: Page
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Space.s) {
                IconView(page.icon).foregroundStyle(selected ? .primary : .secondary)
                Text(page.title).foregroundStyle(selected ? .primary : Color.primary.opacity(0.78))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.m)
            .frame(height: 30)
            .background(Color.primary.opacity(selected ? 0.075 : hovered ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Still())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A button that looks the same while it is pressed: the system's plain one dims its label for that moment.
private struct Still: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
