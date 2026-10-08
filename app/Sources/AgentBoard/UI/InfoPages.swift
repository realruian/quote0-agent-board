// Diagnostics and About.

import AppKit
import BoardCore
import SwiftUI

struct DiagnosticsPage: View {
    @ObservedObject var model: BoardModel
    @State private var confirmingRestart = false

    var body: some View {
        Form {
            Section {
                if let checks = model.checks {
                    ForEach(checks.indices, id: \.self) { index in
                        let check = checks[index]
                        LabeledContent {
                            Text(check["detail"]?.string ?? "")
                        } label: {
                            StatusLine(health: check["ok"]?.bool == true ? .good : check["ok"]?.bool == false ? .bad : .attention,
                                       text: check["name"]?.string ?? "")
                        }
                    }
                } else {
                    Text(model.checking ? "检查中…" : "点“开始自检”，从钩子到屏幕逐项检查。").foregroundStyle(.secondary)
                }
                Button(model.checking ? "检查中…" : "开始自检", action: model.runChecks).glassButton().disabled(model.checking)
            }

            Section("日志") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? "日志是空的。" : model.log.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8).id("end")
                    }
                    .frame(height: 260)
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
        .formStyle(.grouped)
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
        Form {
            Section {
                LabeledContent("版本", value: about["version"]?.string ?? "")
                LabeledContent("设备序列号", value: (about["device_id"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "还没有连接")
                LabeledContent("系统", value: about["runtime"]?.string ?? "")
            }
            Section("文件位置") {
                location("设置", about["config"]?.string, Paths.config)
                location("日志", about["log"]?.string, Paths.log)
                location("配置文件备份", about["backups"]?.string, Paths.backups)
            }
            Section {
                Button("卸载…", role: .destructive, action: model.uninstall)
            } header: {
                Text("卸载")
            } footer: {
                Footnote("会断开 Claude Code 和 Codex、取消开机自启，并把设备的循环间隔恢复原样。设置和日志会保留。之后把 App 拖进废纸篓即可。")
            }
            Section("参考") {
                Link("MindReset 开放 API 文档", destination: URL(string: "https://dot.mindreset.tech/docs/service/open")!)
                Link("灵感来源：Vibe Island", destination: URL(string: "https://vibeisland.app/zh/")!)
                Link("源代码", destination: URL(string: "https://github.com/realruian/quote0-agent-board")!)
            }
        }
        .formStyle(.grouped)
    }

    private func location(_ title: String, _ path: String?, _ url: URL) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path ?? "").textSelection(.enabled)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("在访达中显示")
            }
        }
    }
}
