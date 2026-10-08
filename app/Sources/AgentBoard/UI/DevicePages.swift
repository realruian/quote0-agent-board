// The pages about the two ends of the chain: the agents the board listens to, and the device it draws on.

import BoardCore
import SwiftUI

struct AgentsPage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        Form {
            if let data = model.integrations {
                BannerRows(items: data["hook_installed"]?.bool == true ? [] : [BannerItem(text: "没有找到钩子脚本，重新打开一次 App 可以装回来。")])
                agent("claude", "Claude Code", data["claude"], note: nil)
                agent("codex", "Codex", data["codex"], note: "连接后，Codex 下次启动会要求你确认信任新钩子，确认后才生效。")
                Section {
                } footer: {
                    Footnote("开关会修改对应 Agent 的全局配置文件，修改前会备份，不改动其他工具的配置。只对之后新开的对话生效。")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.loadIntegrations)
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
        return Section {
            Toggle(isOn: Binding(get: { on }, set: { model.connect(id, name, $0) })) {
                HStack(spacing: 8) {
                    Circle().fill((!exists ? Health.unknown : full ? .good : on ? .attention : .unknown).color).frame(width: 8, height: 8)
                    RowLabel(name, status)
                }
            }
            .disabled(!exists)
            LabeledContent("配置文件", value: state?["path"]?.string ?? "")
            if let others = state?["vibe_island"]?.int, others > 0 {
                LabeledContent("Vibe Island", value: "检测到它的 \(others) 个钩子，互不影响")
            }
        } footer: {
            if let note = note { Footnote(note) }
        }
    }
}

struct DevicePage: View {
    @ObservedObject var model: BoardModel
    @State private var alias = ""

    var body: some View {
        Form {
            BannerRows(items: banners)
            if let device = model.device {
                if device["needs_setup"]?.bool == true {
                    Section { Button("连接设备…") { model.page = .setup } }
                } else if device["ok"]?.bool != true {
                    Section {
                        LabeledContent("设备序列号", value: device["device_id"]?.string ?? "")
                        LabeledContent("API 密钥", value: device["key"]?["looks_valid"]?.bool == true ? "格式正确"
                            : device["key"]?["present"]?.bool == true ? "内容不像 Dot 密钥" : "没有找到密钥文件")
                        Button("更换密钥或设备…") { model.page = .setup }
                    }
                } else {
                    connected(device)
                }
            } else {
                Section { Text("正在读取设备信息…").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .onAppear { model.loadDevice() }
        .onChange(of: model.device?["alias"]?.string) { _, new in alias = new ?? "" }
    }

    private var banners: [BannerItem] {
        guard let device = model.device else { return [] }
        if device["needs_setup"]?.bool == true { return [BannerItem(text: "还没有连接设备。", actionTitle: "连接设备") { model.page = .setup }] }
        if device["ok"]?.bool != true {
            return [BannerItem(text: "连不上设备：\(device["error"]?.string ?? "")", actionTitle: "重试", action: model.loadDevice)]
        }
        var items: [BannerItem] = []
        if device["image_slot"]?.bool != true {
            items.append(BannerItem(text: "设备的循环列表里没有“图像 API”，状态牌显示不出来。请在 Dot. App 的内容工坊里添加。"))
        }
        if device["asleep"]?.bool == true {
            items.append(BannerItem(text: "设备休眠中，每 \(device["battery_minutes"]?.int ?? 0) 分钟醒来刷新一次。接上电源后有变化就刷新。",
                                    actionTitle: "更改刷新间隔") { model.page = .refresh })
        }
        return items
    }

    @ViewBuilder
    private func connected(_ device: JSON) -> some View {
        let status = device["status"]
        let asleep = device["asleep"]?.bool == true
        Section {
            LabeledContent("当前状态") { StatusLine(health: asleep ? .attention : .good, text: status?["current"]?.string ?? "未知") }
            LabeledContent("供电", value: status?["battery"]?.string ?? "未知")
            LabeledContent("Wi-Fi 信号", value: status?["wifi"]?.string ?? "未知")
            LabeledContent("上次刷新", value: (device["last_render"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
            LabeledContent("固件版本", value: status?["version"]?.string ?? "未知")
            LabeledContent("时区", value: (device["timezone"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
            LabeledContent("设备序列号", value: device["device_id"]?.string ?? "")
            LabeledContent("API 密钥", value: device["key"]?["looks_valid"]?.bool == true ? "有效" : "格式不对")
        }
        Section("名称") {
            LabeledContent {
                HStack {
                    TextField("设备名称", text: $alias, prompt: Text("未命名")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("保存") { model.saveDevice(["alias": .string(alias)], done: "已保存") }
                }
            } label: {
                RowLabel("设备名称", "显示在 Dot. App 里")
            }
        }
        Section {
            Button("更换密钥或设备…") { model.page = .setup }
        } footer: {
            Footnote("刷新间隔和休眠时段在「刷新」里。")
        }
    }
}

/// Connecting a device: the key, then the device it is for, then whether that device can show the board.
struct SetupPage: View {
    @ObservedObject var model: BoardModel
    @State private var key = ""
    @State private var changingKey = false

    private let models = ["quote_0": "Quote/0"]

    var body: some View {
        Form {
            if let state = model.setup {
                let hasKey = state["key"]?["present"]?.bool == true && state["error"] == nil
                BannerRows(items: (state["error"]?.string).map { [BannerItem(text: "用保存的密钥连不上 MindReset 服务：\($0)。可以重新填一次密钥。")] } ?? [])
                Section {
                    if hasKey && !changingKey {
                        LabeledContent {
                            Button("更换") { changingKey = true }
                        } label: {
                            RowLabel("API 密钥", "已保存，能访问 \(state["devices"]?.array?.count ?? 0) 台设备")
                        }
                    } else {
                        LabeledContent {
                            HStack {
                                SecureField("API 密钥", text: $key, prompt: Text("dot_app_…")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 240)
                                    .onSubmit(saveKey)
                                Button("保存", action: saveKey).glassButton(prominent: true)
                            }
                        } label: {
                            RowLabel("API 密钥", "在 Dot. App 的「更多」→「API 密钥」里创建并复制，粘贴到这里")
                        }
                        Link("官方说明", destination: URL(string: "https://dot.mindreset.tech/docs/service/open/get_api")!)
                    }
                } header: {
                    Text("第 1 步 · API 密钥")
                } footer: {
                    Footnote("密钥只保存在这台电脑上，只发给 MindReset 的服务。")
                }

                if hasKey {
                    Section("第 2 步 · 设备") {
                        let devices = state["devices"]?.array ?? []
                        if devices.isEmpty {
                            Text("这个密钥下还没有设备。先在 Dot. App 里绑定一台 Quote/0，再回到这里。").foregroundStyle(.secondary)
                            Button("重新读取", action: model.loadSetup)
                        }
                        ForEach(devices.indices, id: \.self) { index in
                            let item = devices[index]
                            let id = item["id"]?.string ?? "", alias = item["alias"]?.string ?? ""
                            let kind = models[item["model"]?.string ?? ""] ?? item["model"]?.string ?? "设备"
                            LabeledContent {
                                if id == state["device_id"]?.string {
                                    Label("正在使用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button("使用这台") { model.saveSetup(["device_id": .string(id)], done: "设备已连接") }
                                }
                            } label: {
                                RowLabel(alias.isEmpty ? kind : alias, (alias.isEmpty ? "" : "\(kind) · ") + "序列号 \(id)")
                            }
                        }
                    }
                }

                if state["ready"]?.bool == true {
                    Section("第 3 步 · 屏幕") {
                        if let device = model.device {
                            if device["ok"]?.bool != true {
                                LabeledContent {
                                    Button("重新检查", action: model.loadDevice)
                                } label: {
                                    HStack { Circle().fill(Health.bad.color).frame(width: 8, height: 8); RowLabel("连不上设备", device["error"]?.string) }
                                }
                            } else {
                                let slot = device["image_slot"]?.bool == true
                                let battery = device["status"]?["battery"]?.string ?? ""
                                let powered = battery.contains("已连接电源")
                                LabeledContent {
                                    if slot { Button("发送测试画面", action: model.sendTestFrame) } else { Button("重新检查", action: model.loadDevice) }
                                } label: {
                                    HStack {
                                        Circle().fill((slot ? Health.good : .bad).color).frame(width: 8, height: 8)
                                        RowLabel("图像 API", slot ? "已在设备的循环列表里，状态牌显示在这一项"
                                            : "循环列表里还没有。打开 Dot. App 的内容工坊，把「图像 API」加进这台设备的循环列表，再点重新检查")
                                    }
                                }
                                HStack {
                                    Circle().fill((powered ? Health.good : .attention).color).frame(width: 8, height: 8)
                                    RowLabel("供电", powered ? "已接电源，有变化就刷新" : "\(battery.isEmpty ? "未知" : battery)。用电池时设备会休眠，隔一段时间才刷新一次，建议一直插着电")
                                }
                            }
                        } else {
                            Text("正在检查设备…").foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button("完成") { model.page = .overview }.glassButton(prominent: true)
                    } footer: {
                        Footnote("哪些 Agent 的状态显示在屏幕上，在「Agent」里。")
                    }
                }
            } else {
                Section { Text("正在读取…").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .onAppear {
            model.loadSetup()
            model.loadDevice()
        }
        .onChange(of: model.setup?["device_id"]?.string) { _, _ in model.loadDevice() }
    }

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return model.say("先把密钥粘贴进来", isError: true) }
        model.saveSetup(["key": .string(key)], done: "密钥已保存")
        key = ""
        changingKey = false
    }
}
