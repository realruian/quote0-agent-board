// The pages that hold settings: how the screen looks, which alerts take it over, which
// conversations it lists, whether it shows quota, and when it refreshes.
// Pages that change the picture keep a preview of it pinned above their settings.

import BoardCore
import SwiftUI

struct DisplayPage: View {
    @ObservedObject var model: BoardModel

    private var settings: BoardSettings { model.settings }

    var body: some View {
        PageView(page: .display) {
            ScreenPreview(model: model, samples: [("list", "运行中"), ("wait", "等你批准"), ("idle", "空闲"), ("live", "实际状态")])
        } content: {
            Card("文字") {
                Row("字体", "屏幕只有黑白两色，不同字体的笔画粗细会有差别") {
                    Picker("字体", selection: Binding(get: { settings.font }, set: { model.apply(["font": .string($0)]) })) {
                        ForEach(Fonts.available(), id: \.key) { Text($0.label).tag($0.key) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row("显示对话名称", "和 Claude、Codex 侧边栏里的名称一致；新对话先用你发的第一句话。关掉后只显示项目文件夹名",
                    isOn: model.flag("show_titles", \.showTitles))
            }

            Card("布局") {
                NumberRow(title: "最多行数", detail: "对话更多时，优先显示等你处理的和最近有动静的，其余在横线右端计数", value: settings.maxRows,
                          range: 1...4, unit: "行") {
                    model.apply(["max_rows": JSON($0)])
                }
                Row("空闲时显示上次完成的对话", isOn: model.flag("idle_show_last", \.idleShowLast))
            } footer: {
                Text("画面会经过 MindReset 的服务器发到设备。额度的显示在「用量」里，显示哪些对话在「对话」里。")
            }
        }
    }
}

struct AlertsPage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        PageView(page: .alerts) {
            ScreenPreview(model: model, samples: [("wait", "等你批准"), ("live", "实际状态")])
        } content: {
            Card("整屏提醒") {
                takeover("permission", "等你批准时", "Agent 要执行需要授权的操作")
                takeover("question", "等你回答时", "Agent 向你提问")
                takeover("plan", "等你看计划时", "Agent 写好计划等你确认")
            } footer: {
                Text("整屏反色显示，并立即刷新。关闭的情况只在列表里显示成一行。")
            }

            Card("提醒画面") {
                Row("显示要批准的工具", "例如 Bash、Edit，写在画面底部", isOn: model.flag("show_detail", \.showDetail))
            } footer: {
                Button("想让屏幕在夜间停止刷新，在「刷新」里打开夜间免打扰") { model.page = .refresh }.buttonStyle(.link)
            }
        }
    }

    private func takeover(_ kind: String, _ title: String, _ detail: String) -> some View {
        Row(title, detail, isOn: Binding(get: { model.settings.takeover[kind] ?? true }, set: { model.apply(["takeover": [kind: .bool($0)]]) }))
    }
}

/// Which conversations reach the screen: the agents the board listens to, how long a
/// conversation stays, and which projects are renamed or left off.
struct ConversationsPage: View {
    @ObservedObject var model: BoardModel
    @State private var newProject = ""
    @State private var known: [String] = []

    private var settings: BoardSettings { model.settings }

    var body: some View {
        PageView(page: .conversations) {
            if let data = model.integrations {
                Banners(items: data["hook_installed"]?.bool == true ? [] : [BannerItem(text: "没有找到钩子脚本，重新打开一次 App 可以装回来。")])
                agent("claude", "Claude Code", data["claude"], note: nil)
                agent("codex", "Codex", data["codex"],
                      note: "连接后，Codex 下次启动会要求你确认信任新钩子，确认后才生效。开关会修改对应 Agent 的全局配置文件，修改前会备份，不改动其他工具的配置，只对之后新开的对话生效。")
            }

            Card("显示多久") {
                NumberRow(title: "完成后保留", detail: "对话结束后在屏幕上停留的时间", value: settings.doneTTLMinutes, range: 1...720, unit: "分钟") {
                    model.apply(["done_ttl_minutes": JSON($0)])
                }
                NumberRow(title: "无响应后移除", detail: "被中断的对话不会自己结束，超过这个时间自动移除", value: settings.staleRunningMinutes,
                          range: 5...1440, unit: "分钟") { model.apply(["stale_running_minutes": JSON($0)]) }
            }

            Card("项目别名和隐藏") {
                ForEach(projects, id: \.self) { project($0) }
                Row("添加项目", "项目名是对话所在文件夹的名字") {
                    HStack {
                        TextField("项目", text: $newProject, prompt: Text("文件夹名")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 170)
                            .onSubmit(addProject)
                        Button("添加", action: addProject)
                    }
                }
            } footer: {
                Text("别名会替换屏幕上的项目名。隐藏的项目不显示在屏幕上，也不触发整屏提醒。")
            }
        }
        .onAppear {
            model.loadIntegrations()
            known = model.console.settings()["known_projects"]?.array?.compactMap(\.string) ?? []
        }
    }

    private func agent(_ id: String, _ name: String, _ state: JSON?, note: String?) -> some View {
        let exists = state?["exists"]?.bool == true
        let installed = state?["installed"]?.int ?? 0, expected = state?["expected"]?.int ?? 0
        let on = installed > 0, full = installed == expected
        let status: String = {
            if !exists { return "没有找到它的配置文件，可能没装" }
            if let error = state?["error"]?.string { return error }
            if full { return "已连接" }
            return on ? "连接不完整（\(installed)/\(expected)），关掉再打开可以修复" : "未连接"
        }()
        return Card(id == "claude" ? "接入的 Agent" : nil) {
            Row(name, status, health: !exists ? .unknown : full ? .good : on ? .attention : .unknown,
                isOn: Binding(get: { on }, set: { model.connect(id, name, $0) }))
                .disabled(!exists)
            Row("配置文件", value: state?["path"]?.string ?? "")
            if let others = state?["vibe_island"]?.int, others > 0 {
                Row("Vibe Island", value: "检测到它的 \(others) 个钩子，互不影响")
            }
        } footer: {
            if let note = note { Text(note) }
        }
    }

    private var projects: [String] {
        Array(Set(known + settings.aliases.keys + settings.hiddenProjects)).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    private func addProject() {
        let name = newProject.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return model.say("先填项目的文件夹名", isError: true) }
        if !known.contains(name) { known.append(name) }
        newProject = ""
    }

    private func project(_ name: String) -> some View {
        Row(name) {
            HStack(spacing: 10) {
                AliasField(alias: settings.aliases[name] ?? "") { alias in
                    var all = JSONObject()
                    for (key, value) in settings.aliases where key != name { all[key] = .string(value) }
                    if !alias.isEmpty { all[name] = .string(alias) }
                    model.apply(["aliases": .object(all)])
                }
                Toggle("隐藏", isOn: Binding(get: { settings.hiddenProjects.contains(name) }, set: { hide in
                    model.apply(["hidden_projects": JSON(hide ? settings.hiddenProjects + [name] : settings.hiddenProjects.filter { $0 != name })])
                }))
                .toggleStyle(.switch).controlSize(.small).foregroundStyle(.secondary)
            }
        }
    }
}

/// Quota: whether the screen shows it, and what the agents report.
struct UsagePage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        PageView(page: .usage) {
            Card("屏幕上") {
                UsageChoice(model: model)
            }

            if model.settings.showUsage {
                Card("现在的读数") {
                    quota("Claude", model.status.usage?["claude"], needs: "需要在终端里运行 claude auth login 登录 Claude Code")
                    quota("Codex", model.status.usage?["codex"], needs: "Codex 回复一次后就有")
                } footer: {
                    Text("额度会在重置前用完时，屏幕上那一项反色，显示大约几点用完。按最近的用量推算：5 小时额度看最近 1 小时，每周额度看最近 1 天。")
                }
            }

            Card("数据从哪来") {
                Row("Claude", "每 5 分钟问一次本机的 claude 命令行，它用自己的登录向 Anthropic 查询；只信 20 分钟内的读数") { EmptyView() }
                Row("Codex", "读 Codex 写在本机的对话记录，过了重置时间视为已恢复") { EmptyView() }
            } footer: {
                Text("本 App 不登录任何账号，也不读取登录凭证。不显示额度时，这些都不做。")
            }
        }
    }

    private func quota(_ name: String, _ reading: AgentUsage?, needs: String) -> some View {
        let meters = [(fiveHour, "5 小时"), (sevenDay, "本周")].compactMap { kind, label in
            reading?.windows[kind].map { (label, $0.left) }
        }
        let observed = reading?.observedAt ?? 0
        let detail = meters.isEmpty
            ? (observed != 0 ? "上次读数已过期（\(ago(observed))），等下一次读取" : "还没有数据：\(needs)")
            : "\(ago(observed))更新"
        return Row(name, detail, health: meters.isEmpty ? .attention : nil) {
            HStack(spacing: 18) {
                ForEach(meters, id: \.0) { Meter(label: $0.0, percent: $0.1) }
            }
        }
    }
}

/// The screen with and without quota, side by side: picking one is the setting.
private struct UsageChoice: View {
    @ObservedObject var model: BoardModel
    @State private var sample = "list"
    @State private var frames: [Bool: NSImage] = [:]

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                option(true, "显示额度", sample == "idle" ? "空闲时显示各家额度条和重置时间" : "顶栏显示各家剩余额度和重置时间")
                option(false, "不显示额度", sample == "idle" ? "空闲时只显示上次完成的对话" : "顶栏显示各状态的对话数")
            }
            Picker("示例", selection: $sample) {
                Text("运行中").tag("list")
                Text("空闲").tag("idle")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .onAppear(perform: render)
        .onChange(of: sample) { _, _ in render() }
        .onChange(of: model.settings) { _, _ in render() }
    }

    private func option(_ on: Bool, _ title: String, _ detail: String) -> some View {
        let chosen = model.settings.showUsage == on
        return Button { if !chosen { model.apply(["show_usage": .bool(on)]) } } label: {
            VStack(spacing: 8) {
                ScreenView(image: frames[on], maxWidth: 240)
                HStack(spacing: 5) {
                    if chosen { IconView(.tick02, size: 14).foregroundStyle(Color.accentColor) }
                    Text(title).font(.system(size: 13, weight: .medium))
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(chosen ? Color.accentColor : Tone.line, lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func render() {
        for on in [true, false] {
            model.preview(sample: sample, config: ["show_usage": .bool(on)]) { frames[on] = $0 }
        }
    }
}

/// An alias is saved when the field is left or Return is pressed, not on every key.
private struct AliasField: View {
    let alias: String
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("别名", text: $draft, prompt: Text("别名")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150).focused($focused)
            .onAppear { draft = alias }
            .onChange(of: alias) { _, new in draft = new }
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        let clean = draft.trimmingCharacters(in: .whitespaces)
        if clean != alias { save(clean) }
    }
}

/// When the screen changes: how often at most, whether other loop content may replace the board, and the quiet hours.
struct RefreshPage: View {
    @ObservedObject var model: BoardModel

    private var device: JSON? { model.device }
    private var ready: Bool { device?["ok"]?.bool == true }

    var body: some View {
        PageView(page: .refresh) {
            Banners(items: banners)

            Card("屏幕更新") {
                NumberRow(title: "插电时的最小间隔", detail: "有变化就刷新，两次之间至少隔这么久。整屏提醒不受限制",
                          value: model.settings.minPushIntervalSeconds, range: 3...600, unit: "秒") {
                    model.apply(["min_push_interval_seconds": JSON($0)])
                }
                if ready {
                    Row("始终显示状态牌", "设备循环列表里的其他内容不会替换状态牌",
                        isOn: Binding(get: { device?["keep"]?.bool ?? false }, set: { model.saveDevice(["keep": .bool($0)], done: $0 ? "已开启" : "已关闭") }))
                }
            } footer: {
                Button("用电池时多久刷新一次、设备定时休眠，在「设备」里") { model.page = .device }.buttonStyle(.link)
            }

            Card("夜间免打扰") {
                Row("夜间免打扰", "时段内屏幕显示“夜间免打扰”，停止刷新",
                    isOn: Binding(get: { model.settings.quietHours.enabled }, set: { model.apply(["quiet_hours": ["enabled": .bool($0)]]) }))
                ClockRow(title: "开始时间", value: model.settings.quietHours.start) { model.apply(["quiet_hours": ["start": .string($0)]]) }
                ClockRow(title: "结束时间", value: model.settings.quietHours.end) { model.apply(["quiet_hours": ["end": .string($0)]]) }
            }
        }
        .disabled(model.busy)
        .onAppear { model.loadDevice() }
    }

    private var banners: [BannerItem] {
        guard let device = device, !ready, device["needs_setup"]?.bool != true else { return [] }
        return [BannerItem(text: "连不上设备：\(device["error"]?.string ?? "")。“始终显示状态牌”暂时改不了。", actionTitle: "重试", action: model.loadDevice)]
    }
}
