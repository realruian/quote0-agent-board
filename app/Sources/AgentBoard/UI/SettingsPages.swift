// The pages that hold settings: what the screen shows, when it refreshes, which alerts take it over.

import BoardCore
import SwiftUI

struct DisplayPage: View {
    @ObservedObject var model: BoardModel
    @State private var sample = "list"
    @State private var preview: NSImage?
    @State private var newProject = ""
    @State private var known: [String] = []

    private var settings: BoardSettings { model.settings }

    var body: some View {
        PageView(page: .display) {
            Card {
                VStack(spacing: 12) {
                    ScreenView(image: preview, maxWidth: 380)
                    Picker("示例", selection: $sample) {
                        Text("运行中").tag("list")
                        Text("等你批准").tag("wait")
                        Text("空闲").tag("idle")
                        Text("实际状态").tag("live")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                    Text("预览，不会发到屏幕上").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Card("内容") {
                Row("字体", "屏幕只有黑白两色，不同字体的笔画粗细会有差别") {
                    Picker("字体", selection: Binding(get: { settings.font }, set: { model.apply(["font": .string($0)]) })) {
                        ForEach(Fonts.available(), id: \.key) { Text($0.label).tag($0.key) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row("显示对话名称", "和 Claude、Codex 侧边栏里的名称一致；新对话先用你发的第一句话", isOn: model.flag("show_titles", \.showTitles))
                Row("等批准时显示工具名", "例如 Bash、Edit", isOn: model.flag("show_detail", \.showDetail))
                Row("显示剩余额度", "有 Agent 在运行时显示在顶栏，空闲时显示完整的额度条", isOn: model.flag("show_usage", \.showUsage))
                NumberRow(title: "最多行数", detail: "对话更多时，优先显示等你处理的和最近有动静的", value: settings.maxRows, range: 1...4, unit: "行") {
                    model.apply(["max_rows": JSON($0)])
                }
                Row("空闲时显示上次完成的项目", isOn: model.flag("idle_show_last", \.idleShowLast))
            }

            Card("对话保留") {
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
                Text("别名会替换屏幕上的项目名。隐藏的项目不显示在屏幕上，也不触发整屏提醒。示例画面里的项目和额度是演示用的，选“实际状态”可以看到真实效果。画面会经过 MindReset 的服务器发到设备。")
            }
        }
        .onAppear {
            known = model.console.settings()["known_projects"]?.array?.compactMap(\.string) ?? []
            render()
        }
        .onChange(of: sample) { _, _ in render() }
        .onChange(of: model.settings) { _, _ in render() }
    }

    private var projects: [String] {
        Array(Set(known + settings.aliases.keys + settings.hiddenProjects)).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    private func render() {
        model.preview(sample: sample) { preview = $0 }
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

/// Everything that decides when the screen changes, whether the board or the device holds the setting.
struct RefreshPage: View {
    @ObservedObject var model: BoardModel
    private let wake = [1, 5, 10, 15, 30, 60, 180, 360, 720]

    private var device: JSON? { model.device }
    private var ready: Bool { device?["ok"]?.bool == true }

    var body: some View {
        PageView(page: .refresh) {
            Banners(items: banners)

            Card("刷新间隔") {
                NumberRow(title: "插电时的最小间隔", detail: "有变化就刷新，两次之间至少隔这么久。整屏提醒不受限制",
                          value: model.settings.minPushIntervalSeconds, range: 3...600, unit: "秒") {
                    model.apply(["min_push_interval_seconds": JSON($0)])
                }
                if ready {
                    let minutes = device?["battery_minutes"]?.int ?? 0
                    Row("用电池时的刷新间隔", "设备平时休眠，每隔这么久醒来刷新一次。间隔越短越耗电") {
                        Picker("用电池时的刷新间隔", selection: Binding(get: { minutes }, set: { model.saveDevice(["battery_minutes": JSON($0)], done: "已保存") })) {
                            ForEach((wake.contains(minutes) ? wake : (wake + [minutes]).sorted()), id: \.self) {
                                Text($0 < 60 ? "\($0) 分钟" : "\($0 / 60) 小时").tag($0)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Row("始终显示状态牌", "设备循环列表里的其他内容不会替换状态牌",
                        isOn: Binding(get: { device?["keep"]?.bool ?? false }, set: { model.saveDevice(["keep": .bool($0)], done: $0 ? "已开启" : "已关闭") }))
                }
            }

            Card("夜间") {
                Row("夜间免打扰", "时段内屏幕显示“夜间免打扰”，停止刷新",
                    isOn: Binding(get: { model.settings.quietHours.enabled }, set: { model.apply(["quiet_hours": ["enabled": .bool($0)]]) }))
                ClockRow(title: "开始时间", value: model.settings.quietHours.start) { model.apply(["quiet_hours": ["start": .string($0)]]) }
                ClockRow(title: "结束时间", value: model.settings.quietHours.end) { model.apply(["quiet_hours": ["end": .string($0)]]) }
            }

            if ready, let sleep = device?["sleep"] {
                Card("设备休眠") {
                    Row("定时休眠", "时段内设备整机休眠，循环列表里的其他内容也不刷新",
                        isOn: Binding(get: { sleep["enabled"]?.bool ?? false }, set: { saveSleep(sleep, "enabled", .bool($0)) }))
                    ClockRow(title: "开始时间", value: sleep["start"]?.string ?? "23:00") { saveSleep(sleep, "start", .string($0)) }
                    ClockRow(title: "结束时间", value: sleep["end"]?.string ?? "07:00") { saveSleep(sleep, "end", .string($0)) }
                } footer: {
                    Text("定时休眠按设备的时区（\(device?["timezone"]?.string ?? "未知")）计算。")
                }
            }

            if device == nil {
                Text("正在读取存在设备上的设置…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .disabled(model.busy)
        .onAppear { model.loadDevice() }
    }

    private var banners: [BannerItem] {
        guard let device = device, !ready, device["needs_setup"]?.bool != true else { return [] }
        return [BannerItem(text: "连不上设备：\(device["error"]?.string ?? "")。存在设备上的几项设置暂时改不了。", actionTitle: "重试", action: model.loadDevice)]
    }

    private func saveSleep(_ current: JSON, _ key: String, _ value: JSON) {
        var sleep = current.object ?? JSONObject()
        sleep[key] = value
        model.saveDevice(["sleep": .object(sleep)], done: "已保存")
    }
}

struct AlertsPage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        PageView(page: .alerts) {
            Card("整屏提醒") {
                takeover("permission", "等你批准时", "Agent 要执行需要授权的操作")
                takeover("question", "等你回答时", "Agent 向你提问")
                takeover("plan", "等你看计划时", "Agent 写好计划等你确认")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("整屏反色显示，并立即刷新。关闭的情况只在列表里显示成一行。")
                    Button("夜间免打扰可以让屏幕在夜间停止刷新，在「刷新」里") { model.page = .refresh }.buttonStyle(.link)
                }
            }
        }
    }

    private func takeover(_ kind: String, _ title: String, _ detail: String) -> some View {
        Row(title, detail, isOn: Binding(get: { model.settings.takeover[kind] ?? true }, set: { model.apply(["takeover": [kind: .bool($0)]]) }))
    }
}
