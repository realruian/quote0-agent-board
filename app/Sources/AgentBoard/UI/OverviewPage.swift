import BoardCore
import SwiftUI

struct OverviewPage: View {
    @ObservedObject var model: BoardModel

    private var push: Engine.LastPush? { model.status.lastPush }
    private var missed: Bool { push?.ok == true && push?.delivered == false }

    var body: some View {
        PageView(page: .overview) {
            Banners(items: banners)

            Card {
                HStack(alignment: .center, spacing: 24) {
                    ScreenView(image: model.frame, maxWidth: 300)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(lines.enumerated()), id: \.offset) {
                            StatusLine(health: $0.element.0, text: $0.element.1).font(.system(size: 15, weight: .medium))
                        }
                        if !caption.isEmpty {
                            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        deviceLine.font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if model.status.paused { Button("恢复") { model.apply(["paused": false], quietly: true) } }
                            Button("刷新屏幕", action: model.refreshScreen).disabled(model.status.needsSetup)
                            Button("发送测试画面", action: model.sendTestFrame).disabled(model.status.needsSetup)
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }

            Card("剩余额度") {
                quota("Claude", model.status.usage?["claude"], needs: "需要在终端里登录过 Claude Code")
                quota("Codex", model.status.usage?["codex"], needs: "Codex 回复一次后就有")
            }

            Card("当前对话") {
                if model.status.sessions.isEmpty {
                    Text("现在没有对话。在 Claude Code 或 Codex 里开始一个，就会出现在这里。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 14)
                }
                ForEach(model.status.sessions, id: \.key) { session($0) }
            }
        }
        .onAppear { model.loadDevice() }
    }

    private var banners: [BannerItem] {
        var items: [BannerItem] = []
        if model.status.dryRun { items.append(BannerItem(text: "空跑模式：画面只在本机生成，不会发到屏幕上。")) }
        if model.status.needsSetup {
            items.append(BannerItem(text: "还没有连接设备，画面发不到屏幕上。", actionTitle: "连接设备") { model.page = .setup })
        } else if missed {
            let since = (model.device?["last_render"]?.string).flatMap { $0.isEmpty ? nil : "，屏幕停在 \($0) 的画面" } ?? ""
            items.append(BannerItem(text: "设备休眠或离线，最新画面没有显示出来\(since)。接上电源后会自动补上；用电池时要等它下次醒来。",
                                    actionTitle: "更改刷新间隔") { model.page = .refresh })
        }
        return items
    }

    private var caption: String {
        guard let push = push else { return "" }
        return missed ? "最新画面在 \(clock(push.at)) 发出，\(ago(push.at))" : "屏幕上的画面在 \(clock(push.at)) 刷新，\(ago(push.at))"
    }

    /// One thing when all is well; the broken link named only when there is one.
    private var lines: [(Health, String)] {
        var out: [(Health, String)] = []
        if let push = push, !push.ok { out.append((.bad, "最近一次刷新失败：\(push.message)")) }
        if missed { out.append((.attention, "最新画面还没显示：设备休眠或离线")) }
        if model.status.paused { out.append((.attention, "已暂停，屏幕不再更新")) }
        if model.status.quiet { out.append((.attention, "夜间免打扰中，屏幕暂不刷新")) }
        if out.isEmpty, !model.status.dryRun, !model.status.needsSetup {
            out.append(push == nil ? (.unknown, "还没有刷新过屏幕") : (.good, "屏幕已是最新"))
        }
        return out
    }

    @ViewBuilder private var deviceLine: some View {
        if model.status.needsSetup {
            StatusLine(health: .attention, text: "还没有连接设备")
        } else if let device = model.device {
            let battery = device["status"]?["battery"]?.string ?? ""
            if device["ok"]?.bool != true {
                StatusLine(health: .bad, text: "连不上设备：\(device["error"]?.string ?? "未知原因")")
            } else if battery.contains("已连接电源") {
                StatusLine(health: .good, text: "设备已接电源，有变化就刷新")
            } else {
                let state = [device["status"]?["current"]?.string, battery].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                StatusLine(health: device["asleep"]?.bool == true ? .attention : .good,
                           text: "设备：\(state)，用电池时每 \(device["battery_minutes"]?.int ?? 0) 分钟刷新一次")
                Button("更改刷新间隔") { model.page = .refresh }.buttonStyle(.link)
            }
        } else {
            StatusLine(health: .unknown, text: "正在检查设备…")
        }
    }

    private func quota(_ name: String, _ reading: AgentUsage?, needs: String) -> some View {
        let meters = [(fiveHour, "5 小时"), (sevenDay, "本周")].compactMap { kind, label in
            reading?.windows[kind].map { (label, $0.left) }
        }
        let observed = reading?.observedAt ?? 0
        let detail = meters.isEmpty
            ? (observed != 0 ? "上次读数已过期（\(ago(observed))），等下一次读取" : "还没有数据，\(needs)")
            : "\(ago(observed))更新"
        return Row(name, detail, health: meters.isEmpty ? .unknown : nil) {
            HStack(spacing: 18) {
                ForEach(meters, id: \.0) { Meter(label: $0.0, percent: $0.1) }
            }
        }
    }

    private func session(_ s: Session) -> some View {
        let alias = model.settings.aliases[s.project] ?? ""
        let own = s.name.isEmpty ? s.title : s.name
        let finished = s.state == .done || s.state == .error
        let since = s.state == .waiting ? s.waitingSince : s.state == .running ? s.startedAt : s.finishedAt
        let details: [String?] = [
            agentName[s.source] ?? s.source, own.isEmpty ? nil : (alias.isEmpty ? s.project : alias), alias.isEmpty ? nil : "原名 \(s.project)",
            model.settings.hiddenProjects.contains(s.project) ? "已隐藏，不上屏" : nil, since > 0 ? "\(clock(since)) \(finished ? "结束" : "起")" : nil,
        ]
        let (label, color): (String, Color) = {
            switch s.state {
            case .waiting: return (waitLabel[s.waitKind] ?? "等你处理", .orange)
            case .running: return ("运行中", .blue)
            case .error: return ("出错", .red)
            default: return ("已完成", .green)
            }
        }()
        return Row(own.isEmpty ? (alias.isEmpty ? s.project : alias) : own, details.compactMap { $0 }.joined(separator: " · ")) {
            Pill(text: label, color: color)
        }
    }
}
