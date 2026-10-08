// Diagnostics and About.

import AppKit
import BoardCore
import SwiftUI

struct DiagnosticsPage: View {
    @ObservedObject var model: BoardModel
    @State private var confirmingRestart = false

    var body: some View {
        PageView(page: .diagnostics) {
            Card("自检") {
                if let checks = model.checks {
                    ForEach(checks.indices, id: \.self) { index in
                        let check = checks[index]
                        Row(check["name"]?.string ?? "", health: check["ok"]?.bool == true ? .good : check["ok"]?.bool == false ? .bad : .attention,
                            value: check["detail"]?.string ?? "")
                    }
                }
                Row(model.checks == nil ? "还没有检查过" : "再检查一次", model.checks == nil ? "从钩子到屏幕逐项检查" : nil) {
                    Button(model.checking ? "检查中…" : "开始自检", action: model.runChecks).disabled(model.checking)
                }
            }

            Card("日志") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? "日志是空的。" : model.log.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).id("end")
                    }
                    .frame(height: 250)
                    .onChange(of: model.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
                HStack {
                    Button("刷新日志", action: model.loadLog)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Paths.log]) }
                    Spacer()
                    Button("重新启动…", role: .destructive) { confirmingRestart = true }
                }
            }
        }
        .onAppear(perform: model.loadLog)
        .confirmationDialog("重新启动 Agent 状态牌？", isPresented: $confirmingRestart) {
            Button("重新启动") { model.console.restart() }
        } message: {
            Text("几秒钟后恢复，期间状态牌不更新。")
        }
    }
}

struct AboutPage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        let about = model.console.about()
        PageView(page: .about) {
            Card {
                Row("版本", value: about["version"]?.string ?? "")
                Row("设备序列号", value: (about["device_id"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "还没有连接")
                Row("系统", value: about["runtime"]?.string ?? "")
            }
            Card("图标") {
                Row("在菜单栏显示图标", "状态牌是否正常、有几个对话在等你，看图标就知道",
                    isOn: Binding(get: { model.menuBarIcon }, set: { model.showMenuBarIcon($0) }))
                Row("关闭窗口后保留程序坞图标", "关掉这一项，窗口一关 App 就离开程序坞",
                    isOn: Binding(get: { model.keepsDockIcon }, set: { model.keepDockIcon($0) }))
            } footer: {
                Text("两个图标可以都不留：状态牌照常在后台工作，再打开一次 App 就能回到这个窗口。")
            }
            Card("文件位置") {
                location("设置", about["config"]?.string, Paths.config)
                location("日志", about["log"]?.string, Paths.log)
                location("配置文件备份", about["backups"]?.string, Paths.backups)
            }
            Card("参考") {
                link("MindReset 开放 API 文档", "https://dot.mindreset.tech/docs/service/open")
                link("灵感来源：Vibe Island", "https://vibeisland.app/zh/")
                link("源代码", "https://github.com/realruian/quote0-agent-board")
            }
            Card("卸载") {
                Row("卸载 Agent 状态牌", "之后把 App 拖进废纸篓即可") {
                    Button("卸载…", role: .destructive, action: model.uninstall)
                }
            } footer: {
                Text("会断开 Claude Code 和 Codex、取消开机自启，并把设备的循环间隔恢复原样。设置和日志会保留。")
            }
        }
    }

    private func link(_ title: String, _ address: String) -> some View {
        Row(title) {
            Link(destination: URL(string: address)!) { IconView(.arrowUpRight01) }.foregroundStyle(.secondary)
                .accessibilityLabel("打开\(title)")
        }
    }

    private func location(_ title: String, _ path: String?, _ url: URL) -> some View {
        Row(title) {
            HStack(spacing: 8) {
                ValueText(path ?? "")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { IconView(.folder01) }
                    .buttonStyle(.borderless).help("在访达中显示").accessibilityLabel("在访达中显示")
            }
        }
    }
}
