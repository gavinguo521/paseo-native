import PaseoKit
import SwiftUI

/// Notifications belong to their execution host, independent of the iPhone's
/// selected Live Activity host. The device key is never read back by the app.
struct BarkPushSection: View {
    @Environment(AppModel.self) private var model
    @State private var selectedHost = ""
    @Binding var configuringHost: HostStore?

    private var hosts: [HostStore] {
        model.hosts.filter { $0.state == .connected && $0.isPluginRunning("live-activity") }
    }
    private var host: HostStore? { hosts.first { $0.id == selectedHost } ?? hosts.first }

    var body: some View {
        Section {
            if hosts.count > 1 {
                Picker("通知所在主机", selection: $selectedHost) {
                    Text("选择…").tag("")
                    ForEach(hosts) { Text($0.label).tag($0.id) }
                }
            }
            if let host {
                LabeledContent("通知所在主机", value: host.label)
                Button("配置 Bark 推送…") { configuringHost = host }
            } else {
                Text("请连接会话或任务所在主机，并在该主机安装和启用最新的推送插件。")
                    .foregroundStyle(Theme.muted)
            }
        } header: {
            Text("Bark 通知")
        } footer: {
            Text("手机安装 Bark 后可接收会话完成和计划任务结果通知，无需配置 APNs 密钥。请在各执行主机分别配置。")
        }
    }
}

struct BarkConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    @State private var pushURL = ""
    @State private var status: JSONValue?
    @State private var busy = false
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?

    private var configured: Bool { status?["configured"]?.boolValue == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("通知所在主机", value: host.label)
                    if loading {
                        ProgressView()
                    } else {
                        LabeledContent("状态", value: configured ? String(localized: "已配置") : String(localized: "未配置"))
                    }
                    if let server = status?["serverURL"]?.stringValue {
                        LabeledContent("Bark 服务器", value: server)
                    }
                    SecureField("Bark 推送地址", text: $pushURL)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Button("保存推送地址") { Task { await save() } }
                        .disabled(status == nil || pushURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("从 Bark 首页复制推送地址并粘贴到这里，例如 https://api.day.app/设备密钥。地址只保存在执行主机上，保存后不再显示设备密钥。")
                }
                if configured {
                    Section {
                        Toggle("会话完成通知", isOn: Binding(
                            get: { status?["notifyOnFinish"]?.boolValue == true },
                            set: { enabled in Task { await setNotifyOnFinish(enabled) } }
                        ))
                        .disabled(status?["notifyOnFinish"]?.boolValue == nil)
                    } footer: {
                        Text("普通会话每次回复完成后推送到手机，点击可打开对应会话。Mac 正在使用时也会推送，Mac 系统通知照常保留。计划任务仍使用各任务的“通知任务结果”开关。")
                    }
                    Section {
                        Button("发送 Bark 测试通知") { Task { await test() } }
                        if let last = status?["lastPush"], last != .null {
                            Text(last["ok"]?.boolValue == true
                                 ? String(localized: "最近一次请求已被 Bark 接受")
                                 : String(localized: "最近一次请求失败，请检查地址和主机网络"))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Button("移除 Bark 配置", role: .destructive) { Task { await clear() } }
                    }
                }
                Section {
                    Text("已开启的通知会将会话标题与回复摘要，或任务名称与结果摘要发送到所填的 Bark 服务器。点击通知可打开 Paseo 的对应会话或任务记录。")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Text("请允许 Bark 的锁屏通知。测试收到后，在计划任务中开启“通知任务结果”并保存。")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                if let notice { Text(notice).foregroundStyle(Theme.accent) }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .disabled(busy || loading)
            .formStyle(.grouped)
            .navigationTitle("Bark 通知")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(busy)
                }
            }
            .task { await load() }
        }
        .macOnly { $0.frame(minWidth: 480, minHeight: 480) }
        .interactiveDismissDisabled(busy)
    }

    private func load() async {
        defer { loading = false }
        do {
            let value = try await host.invokePlugin("live-activity", "bark.status", [:], timeout: .seconds(15))
            guard value["configured"]?.boolValue != nil else { throw HostStore.ActionError.rejected("Bark") }
            status = value
        } catch {
            self.error = String(localized: "无法读取 Bark 设置，请确认主机已连接并安装最新推送插件。")
        }
    }

    private func save() async {
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            status = try await host.invokePlugin("live-activity", "bark.configure", [
                "pushURL": .string(pushURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ], timeout: .seconds(15))
            pushURL = ""
            notice = String(localized: "已保存，请发送测试通知并检查手机。")
        } catch {
            // A copied URL contains a device secret. Never echo an RPC error that
            // might include input validation details into UI or screenshots.
            self.error = String(localized: "保存失败，请检查主机连接，并粘贴 Bark 首页完整的 HTTPS 推送地址。")
        }
    }

    private func test() async {
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let result = try await host.invokePlugin("live-activity", "bark.test", [:], timeout: .seconds(20))
            if result["ok"]?.boolValue == true {
                notice = String(localized: "测试请求已被 Bark 接受，请检查手机锁屏通知。")
            } else {
                error = String(localized: "测试发送失败，请检查 Bark 地址和主机网络后重试。")
            }
            await load()
        } catch {
            self.error = String(localized: "测试发送失败，请检查 Bark 地址和主机网络后重试。")
        }
    }

    private func setNotifyOnFinish(_ enabled: Bool) async {
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            status = try await host.invokePlugin("live-activity", "bark.preferences", [
                "notifyOnFinish": .bool(enabled)
            ], timeout: .seconds(30))
        } catch {
            self.error = String(localized: "会话通知设置保存失败，请检查主机连接后重试。")
        }
    }

    private func clear() async {
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            status = try await host.invokePlugin("live-activity", "bark.clear", [:], timeout: .seconds(15))
            pushURL = ""
            notice = String(localized: "已移除 Bark 配置。")
        } catch {
            self.error = String(localized: "移除失败，请检查主机连接后重试。")
        }
    }
}
