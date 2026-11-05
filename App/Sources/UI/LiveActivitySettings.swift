// 设置 → 通知 下的「灵动岛推送」：选哪台机器负责推送、看插件状态、配置 APNs 密钥。
// 插件 live-activity 只要装在一台机器上，它合并自己和已关联机器的会话；iPhone 只把令牌交给这一台。
// macOS 上没有灵动岛，这里只用来给机器配置密钥（在 Mac 上选 .p8 文件更方便）。

import PaseoKit
import SwiftUI
import UniformTypeIdentifiers

struct LiveActivityPushSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("liveActivity.pusher") private var pusherChoice = ""
    @State private var status: JSONValue?
    @State private var error: String?
    @State private var configuring = false

    private static let pluginId = "live-activity"
    private var hostsWithPlugin: [HostStore] { model.hosts.filter { $0.state == .connected && $0.isPluginRunning(Self.pluginId) } }
    /// 和 LiveActivityController.pusher 同一规则。
    private var pusher: HostStore? { hostsWithPlugin.first { $0.id == pusherChoice } ?? hostsWithPlugin.first }

    var body: some View {
        Section {
            if hostsWithPlugin.isEmpty {
                Text("要在一台机器上装「灵动岛推送」插件（设置 → 机器 → 插件 → 配套插件）。只有一台电脑就装在那台上。")
                    .foregroundStyle(Theme.muted)
            } else {
                if hostsWithPlugin.count > 1 {
                    Picker("推送机器", selection: $pusherChoice) {
                        Text("自动（\(hostsWithPlugin.first?.label ?? "")）").tag("")
                        ForEach(hostsWithPlugin) { Text($0.label).tag($0.id) }
                    }
                    .onChange(of: pusherChoice) {
                        status = nil
                        #if os(iOS)
                        LiveActivityController.shared.sync()
                        #endif
                    }
                } else if let pusher {
                    LabeledContent("推送机器", value: pusher.label)
                }
                if let keys = status?["keys"], keys != .null {
                    // 推送环境由安装方式决定：Xcode 直装走 Sandbox，TestFlight / Ad Hoc / App Store 走 Production。
                    LabeledContent("Sandbox 密钥（Xcode 直装）", value: keyLabel(keys["development"]))
                    LabeledContent("Production 密钥（TestFlight）", value: keyLabel(keys["production"]))
                } else {
                    LabeledContent("APNs 密钥", value: keyLabel)
                }
                if let last = status?["lastPush"], last != .null {
                    LabeledContent("上次推送", value: lastPushLabel(last))
                }
                Button("配置 APNs 密钥…") { configuring = true }
            }
            if let error { Text(error).foregroundStyle(Theme.destructive) }
        } header: {
            Text("灵动岛推送")
        } footer: {
            Text("App 不在前台时，由推送机器经 Apple 推送更新灵动岛和锁屏，它会把已关联机器上的会话一起算进来。密钥在 Apple 开发者后台 → Keys 创建（勾选 Apple Push Notifications service，Key Restriction 选 Topic Specific → \(Bundle.main.bundleIdentifier ?? "")），Sandbox 和 Production 各建一个，只保存在那台机器上。")
        }
        .task(id: pusher?.id) { await loadStatus() }
        .sheet(isPresented: $configuring) {
            if let pusher {
                APNsKeySheet(host: pusher, perEnvironment: status?["keys"].map { $0 != .null } ?? false) { Task { await loadStatus() } }
            }
        }
    }

    private func keyLabel(_ key: JSONValue?) -> String {
        guard let key, key != .null else { return "未配置" }
        return "Key ID " + (key["keyId"]?.stringValue ?? "?")
    }

    private var keyLabel: String {
        guard let status else { return "读取中…" }
        guard status["configured"]?.boolValue == true else { return "未配置" }
        return "已配置（Key ID " + (status["keyId"]?.stringValue ?? "?") + "）"
    }

    private func lastPushLabel(_ last: JSONValue) -> String {
        let at = last["at"]?.doubleValue.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
        let when = at.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        if last["ok"]?.boolValue == true { return when + " 成功" }
        return when + " 失败：" + (last["reason"]?.stringValue ?? last["status"]?.doubleValue.map { "HTTP \(Int($0))" } ?? "未知原因")
    }

    private func loadStatus() async {
        guard let pusher else { status = nil; return }
        do {
            status = try await pusher.invokePlugin(Self.pluginId, "activity.status", [:], timeout: .seconds(15))
            error = nil
        } catch {
            self.error = "读不到插件状态：\(error)"
        }
    }
}

/// 填 Team ID、Key ID，选 .p8 文件，交给插件验证并保存。
private struct APNsKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    /// 插件支持按环境分别存密钥（旧版插件只存一把，两个环境共用）。
    let perEnvironment: Bool
    let onSaved: () -> Void
    // App 用这个团队签名，推送密钥也必须是这个团队的。
    @State private var teamId = Bundle.main.object(forInfoDictionaryKey: "PaseoTeamID") as? String ?? ""
    @State private var keyId = ""
    /// 默认这台设备当前用的环境（Mac 上没有，默认 Sandbox）。
    @State private var environment: String = {
        #if os(iOS)
        LiveActivityController.apsEnvironment
        #else
        "development"
        #endif
    }()
    @State private var p8: String?
    @State private var fileName: String?
    @State private var picking = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Team ID", text: $teamId).autocorrectionDisabled()
                    TextField("Key ID", text: $keyId).autocorrectionDisabled()
                    Button(fileName.map { "已选：\($0)" } ?? "选择 .p8 文件…") { picking = true }
                    if perEnvironment {
                        Picker("用于", selection: $environment) {
                            Text("Sandbox（Xcode 直装）").tag("development")
                            Text("Production（TestFlight 等）").tag("production")
                            Text("两个都用").tag("both")
                        }
                    }
                } footer: {
                    Text("密钥会发到「\(host.label)」上的插件，由它试签一次确认能用再保存；这台设备不留副本。")
                }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .formStyle(.grouped)
            .navigationTitle("APNs 密钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving || p8 == nil || teamId.trimmingCharacters(in: .whitespaces).isEmpty
                                  || keyId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PRIVATE KEY") else {
                error = "这个文件不像 .p8 密钥"
                return
            }
            p8 = text
            fileName = url.lastPathComponent
            error = nil
            // 文件名一般是 AuthKey_<Key ID>.p8，顺手填上。
            if keyId.isEmpty, let m = url.deletingPathExtension().lastPathComponent.split(separator: "_").last, m.count == 10 {
                keyId = String(m)
            }
        }
    }

    private func save() async {
        guard let p8 else { return }
        saving = true
        defer { saving = false }
        do {
            var input: JSONValue = ["teamId": .string(teamId.trimmingCharacters(in: .whitespaces)),
                                    "keyId": .string(keyId.trimmingCharacters(in: .whitespaces)),
                                    "p8": .string(p8)]
            // 「两个都用」不传 environment（插件把这把用于两个环境）；旧版插件也不传。
            if perEnvironment, environment != "both", case .object(var o) = input {
                o["environment"] = .string(environment)
                input = .object(o)
            }
            _ = try await host.invokePlugin("live-activity", "activity.configure", input, timeout: .seconds(20))
            onSaved()
            dismiss()
        } catch {
            self.error = "保存失败：\(error)"
        }
    }
}
