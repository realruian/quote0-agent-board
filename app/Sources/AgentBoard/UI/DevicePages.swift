// The pages about the two ends of the chain: the agents the board listens to, and the device it draws on.

import BoardCore
import SwiftUI

struct AgentsPage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        PageView(page: .agents) {
            if let data = model.integrations {
                Banners(items: data["hook_installed"]?.bool == true ? [] : [BannerItem(text: "没有找到钩子脚本，重新打开一次 App 可以装回来。")])
                agent("claude", "Claude Code", data["claude"], note: nil)
                agent("codex", "Codex", data["codex"], note: "连接后，Codex 下次启动会要求你确认信任新钩子，确认后才生效。")
                Text("开关会修改对应 Agent 的全局配置文件，修改前会备份，不改动其他工具的配置。只对之后新开的对话生效。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 2)
            }
        }
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
        return Card {
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
}

struct DevicePage: View {
    @ObservedObject var model: BoardModel
    @State private var alias = ""

    var body: some View {
        PageView(page: .device) {
            Banners(items: banners)
            if let device = model.device {
                if device["needs_setup"]?.bool == true {
                    Button("连接设备…") { model.page = .setup }.glassButton(prominent: true)
                } else if device["ok"]?.bool != true {
                    Card {
                        Row("设备序列号", value: device["device_id"]?.string ?? "")
                        Row("API 密钥", value: device["key"]?["looks_valid"]?.bool == true ? "格式正确"
                            : device["key"]?["present"]?.bool == true ? "内容不像 Dot 密钥" : "没有找到密钥文件")
                    }
                    Button("更换密钥或设备…") { model.page = .setup }
                } else {
                    connected(device)
                }
            } else {
                Text("正在读取设备信息…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .disabled(model.busy)
        .onAppear {
            alias = model.device?["alias"]?.string ?? ""
            model.loadDevice()
        }
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
        Card("名称") {
            Row("设备名称", "显示在 Dot. App 里") {
                HStack {
                    TextField("设备名称", text: $alias, prompt: Text("未命名")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("保存") { model.saveDevice(["alias": .string(alias)], done: "已保存") }
                }
            }
        }
        Card("状态") {
            Row("当前状态", health: asleep ? .attention : .good, value: status?["current"]?.string ?? "未知")
            Row("供电", value: status?["battery"]?.string ?? "未知")
            Row("Wi-Fi 信号", value: status?["wifi"]?.string ?? "未知")
            Row("上次刷新", value: (device["last_render"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
        }
        Card("信息") {
            Row("固件版本", value: status?["version"]?.string ?? "未知")
            Row("时区", value: (device["timezone"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
            Row("设备序列号", value: device["device_id"]?.string ?? "")
            Row("API 密钥", value: device["key"]?["looks_valid"]?.bool == true ? "有效" : "格式不对")
            Row("更换密钥或设备", "刷新间隔和休眠时段在「刷新」里") {
                Button("更换…") { model.page = .setup }
            }
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
        PageView(page: .setup) {
            if let state = model.setup {
                let hasKey = state["key"]?["present"]?.bool == true && state["error"] == nil
                Banners(items: (state["error"]?.string).map { [BannerItem(text: "用保存的密钥连不上 MindReset 服务：\($0)。可以重新填一次密钥。")] } ?? [])
                Card("第 1 步 · API 密钥") {
                    if hasKey && !changingKey {
                        Row("API 密钥", "已保存，能访问 \(state["devices"]?.array?.count ?? 0) 台设备") {
                            Button("更换") { changingKey = true }
                        }
                    } else {
                        Row("API 密钥", "在 Dot. App 的「更多」→「API 密钥」里创建并复制，粘贴到这里") {
                            HStack {
                                SecureField("API 密钥", text: $key, prompt: Text("dot_app_…")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                                    .onSubmit(saveKey)
                                Button("保存", action: saveKey).glassButton(prominent: true)
                            }
                        }
                    }
                } footer: {
                    HStack(spacing: 4) {
                        Text("密钥只保存在这台电脑上，只发给 MindReset 的服务。")
                        if !(hasKey && !changingKey) { Link("官方说明", destination: URL(string: "https://dot.mindreset.tech/docs/service/open/get_api")!) }
                    }
                }

                if hasKey {
                    Card("第 2 步 · 设备") {
                        let devices = state["devices"]?.array ?? []
                        if devices.isEmpty {
                            Row("这个密钥下还没有设备", "先在 Dot. App 里绑定一台 Quote/0，再回到这里") {
                                Button("重新读取", action: model.loadSetup)
                            }
                        }
                        ForEach(devices.indices, id: \.self) { index in
                            let item = devices[index]
                            let id = item["id"]?.string ?? "", alias = item["alias"]?.string ?? ""
                            let kind = models[item["model"]?.string ?? ""] ?? item["model"]?.string ?? "设备"
                            Row(alias.isEmpty ? kind : alias, (alias.isEmpty ? "" : "\(kind) · ") + "序列号 \(id)") {
                                if id == state["device_id"]?.string {
                                    HStack(spacing: 5) {
                                        IconView(.tick02)
                                        Text("正在使用")
                                    }
                                    .foregroundStyle(.secondary)
                                } else {
                                    Button("使用这台") { model.saveSetup(["device_id": .string(id)], done: "设备已连接") }
                                }
                            }
                        }
                    }
                }

                if state["ready"]?.bool == true {
                    Card("第 3 步 · 屏幕") {
                        if let device = model.device {
                            if device["ok"]?.bool != true {
                                Row("连不上设备", device["error"]?.string, health: .bad) {
                                    Button("重新检查", action: model.loadDevice)
                                }
                            } else {
                                let slot = device["image_slot"]?.bool == true
                                let battery = device["status"]?["battery"]?.string ?? ""
                                let powered = battery.contains("已连接电源")
                                Row("图像 API", slot ? "已在设备的循环列表里，状态牌显示在这一项"
                                    : "循环列表里还没有。打开 Dot. App 的内容工坊，把「图像 API」加进这台设备的循环列表，再点重新检查", health: slot ? .good : .bad) {
                                    if slot { Button("发送测试画面", action: model.sendTestFrame) } else { Button("重新检查", action: model.loadDevice) }
                                }
                                Row("供电", powered ? "已接电源，有变化就刷新" : "\(battery.isEmpty ? "未知" : battery)。用电池时设备会休眠，隔一段时间才刷新一次，建议一直插着电",
                                    health: powered ? .good : .attention) {}
                            }
                        } else {
                            Text("正在检查设备…").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("哪些 Agent 的状态显示在屏幕上，在「Agent」里。")
                    }
                    Button("完成") { model.page = .overview }.glassButton(prominent: true)
                }
            } else {
                Text("正在读取…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
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
