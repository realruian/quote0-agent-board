// The window: the pages listed down the side, the chosen one beside them.

import BoardCore
import Combine
import SwiftUI

struct RootView: View {
    @ObservedObject var model: BoardModel
    private let pages: [Page] = [.overview, .display, .refresh, .alerts, .agents, .device]
    private let advanced: [Page] = [.diagnostics, .about]
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                ForEach(pages) { row($0) }
                Section("高级") { ForEach(advanced) { row($0) } }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text("v\(model.console.version)").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }
        } detail: {
            detail
                .navigationTitle((model.page ?? .overview).title)
                .overlay(alignment: .bottom) {
                    if let notice = model.notice { NoticeView(notice: notice) }
                }
                .animation(.spring(duration: 0.3), value: model.notice)
        }
        .onReceive(tick) { _ in model.refresh() }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func row(_ page: Page) -> some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
        .tag(page)
    }

    @ViewBuilder private var detail: some View {
        switch model.page ?? .overview {
        case .overview: OverviewPage(model: model)
        case .display: DisplayPage(model: model)
        case .refresh: RefreshPage(model: model)
        case .alerts: AlertsPage(model: model)
        case .agents: AgentsPage(model: model)
        case .device: DevicePage(model: model)
        case .diagnostics: DiagnosticsPage(model: model)
        case .about: AboutPage(model: model)
        case .setup: SetupPage(model: model)
        }
    }
}
