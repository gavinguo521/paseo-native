// Daemon config (Settings → Host). Official: screens/settings/host-page.tsx and friends.
// Patch semantics: objects deep-merge, arrays/scalars replace — arrays are always sent whole.

import PaseoKit
import SwiftUI

struct DaemonSettingsView: View {
    let host: HostStore
    @State private var diagnostic: (String, String)?
    @State private var systemPrompt = ""
    @State private var resumePrompt = ""
    @State private var editingProfile: ProfileDraft?
    @State private var editingAgentProfile: AgentProfileDraft?
    @State private var confirmRestart = false
    @State private var confirmRelayOff = false
    @State private var error: String?

    private var config: JSONValue? { host.daemonConfig }

    var body: some View {
        Form {
            if config == nil { Text("读取 daemon 配置中…").foregroundStyle(Theme.muted) }
            if let error { Text(error).foregroundStyle(Theme.destructive) }

            Section("会话") {
                toggle(String(localized: "给会话注入 Paseo 工具（MCP）"), on: config?["mcp"]?["injectIntoAgents"]?.boolValue != false) { ["mcp": ["injectIntoAgents": .bool($0)]] }
                toggle(String(localized: "浏览器工具"), on: config?["browserTools"]?["enabled"]?.boolValue == true) { ["browserTools": ["enabled": .bool($0)]] }
                toggle(String(localized: "清理空闲的会话进程"), on: config?["idleRuntimeCleanup"]?.boolValue != false) { ["idleRuntimeCleanup": .bool($0)] }
                // 0.15: sessions interrupted by a daemon restart (update, crash, reboot) pick up where they stopped.
                if host.serverInfo?.hasFeature("resumeOnStartupSetting") == true {
                    toggle(String(localized: "daemon 重启后恢复被中断的会话"), on: config?["resumeOnStartup"]?.boolValue == true) { ["resumeOnStartup": .bool($0)] }
                    if config?["resumeOnStartup"]?.boolValue == true {
                        HStack {
                            TextField("恢复时发送", text: $resumePrompt, prompt: Text("Resume working."))
                            Button("保存") { patch(["resumePrompt": .string(resumePrompt)]) }
                                .disabled(resumePrompt == (config?["resumePrompt"]?.stringValue ?? ""))
                        }
                    }
                }
                // 0.15: host-wide switch for provider usage queries (the usage ring and page stop asking).
                if host.serverInfo?.hasFeature("usageSetting") == true {
                    toggle(String(localized: "查询 Provider 用量"), on: config?["usage"]?["enabled"]?.boolValue != false) { ["usage": ["enabled": .bool($0)]] }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("追加到每个会话的系统提示词")
                    TextEditor(text: $systemPrompt).font(.system(size: 12, design: .monospaced)).frame(minHeight: 70)
                        .scrollContentBackground(.hidden).padding(6).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Spacer()
                        Button("保存提示词") { patch(["appendSystemPrompt": .string(systemPrompt)]) }
                            .disabled(systemPrompt == (config?["appendSystemPrompt"]?.stringValue ?? ""))
                    }
                }
            }

            Section("工作区") {
                toggle(String(localized: "PR 合并后自动归档工作区"), on: config?["autoArchiveAfterMerge"]?.boolValue == true) { ["autoArchiveAfterMerge": .bool($0)] }
            }

            Section("Provider") {
                ForEach(providerIds, id: \.self) { id in
                    let enabled = config?["providers"]?[id]?["enabled"]?.boolValue ?? (snapshot(id)?["enabled"]?.boolValue ?? true)
                    Toggle(isOn: Binding(get: { enabled }, set: { v in patch(["providers": [id: ["enabled": .bool(v)]]]) })) {
                        HStack {
                            Text(snapshot(id)?["label"]?.stringValue ?? id)
                            if let st = snapshot(id)?["status"]?.stringValue, st != "available", st != "ready" {
                                Text(st).font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("诊断") { Task { diagnostic = (id, (try? await host.providerDiagnostic(id)) ?? String(localized: "诊断失败")) } }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
                Button("重新检测 Provider") { Task { await host.refreshProviders(cwd: nil) } }
            }

            Section("自动命名") {
                let entry = config?["metadataGeneration"]?["providers"]?.arrayValue?.first
                Picker("生成标题用的 provider", selection: Binding(
                    get: { entry?["provider"]?.stringValue ?? "" },
                    set: { p in patch(["metadataGeneration": ["providers": p.isEmpty ? [] : [["provider": .string(p)]]]]) })) {
                    Text("默认").tag("")
                    ForEach(providerIds, id: \.self) { Text(snapshot($0)?["label"]?.stringValue ?? $0).tag($0) }
                }
                if let p = entry?["provider"]?.stringValue {
                    Picker("模型", selection: Binding(
                        get: { entry?["model"]?.stringValue ?? "" },
                        set: { m in patch(["metadataGeneration": ["providers": [m.isEmpty ? ["provider": .string(p)] : ["provider": .string(p), "model": .string(m)]]]]) })) {
                        Text("默认").tag("")
                        ForEach(snapshot(p)?["models"]?.arrayValue ?? [], id: \.self) { Text($0["label"]?.stringValue ?? "").tag($0["id"]?.stringValue ?? "") }
                    }
                }
            }

            Section("终端") {
                toggle(String(localized: "终端里 agent CLI 的状态钩子"), on: config?["enableTerminalAgentHooks"]?.boolValue == true) { ["enableTerminalAgentHooks": .bool($0)] }
                ForEach(Array(host.terminalProfiles.enumerated()), id: \.offset) { i, p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p["name"]?.stringValue ?? "")
                            Text(([p["command"]?.stringValue ?? ""] + (p["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])).joined(separator: " "))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Button { move(i, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).disabled(i == 0).help("上移")
                            .accessibilityLabel("上移")
                        Button { move(i, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.plain)
                            .disabled(i == host.terminalProfiles.count - 1).help("下移")
                            .accessibilityLabel("下移")
                        Button { editingProfile = ProfileDraft(index: i, p) } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                            .accessibilityLabel("编辑")
                        Button { var list = host.terminalProfiles; list.remove(at: i); patch(["terminalProfiles": .array(list)]) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.plain)
                        .accessibilityLabel("删除")
                    }
                }
                Button("添加终端 profile…") { editingProfile = ProfileDraft(index: nil, nil) }
            }

            Section("会话预设（Agent profiles）") {
                let profiles = config?["agentProfiles"]?.arrayValue ?? []
                ForEach(Array(profiles.enumerated()), id: \.offset) { i, p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p["name"]?.stringValue ?? "")
                            Text([p["provider"]?.stringValue, p["model"]?.stringValue, p["modeId"]?.stringValue].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button { editingAgentProfile = AgentProfileDraft(index: i, p) } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                            .accessibilityLabel("编辑")
                        Button { var list = profiles; list.remove(at: i); patch(["agentProfiles": .array(list)]) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                            .accessibilityLabel("删除")
                    }
                }
                Button("添加预设…") { editingAgentProfile = AgentProfileDraft(index: nil, nil) }
            }

            Section("插件与中继") {
                toggle(String(localized: "启用插件"), on: config?["pluginsEnabled"]?.boolValue == true) { ["pluginsEnabled": .bool($0)] }
                if host.serverInfo?.hasFeature("relayConfig") == true {
                    Toggle("中继（手机等设备经它连接）", isOn: Binding(
                        get: { config?["relay"]?["enabled"]?.boolValue != false },
                        set: { v in if v { patch(["relay": ["enabled": true]]) } else { confirmRelayOff = true } }))
                }
            }

            Section {
                Button("重启 daemon", role: .destructive) { confirmRestart = true }
            } footer: {
                Text("重启期间这台机器上正在跑的会话会中断，几秒后自动重连。")
            }
        }
        .sheet(isPresented: Binding(get: { diagnostic != nil }, set: { if !$0 { diagnostic = nil } })) {
            TextReportSheet(title: String(localized: "Provider 诊断 · \(diagnostic?.0 ?? "")"), text: diagnostic?.1 ?? "")
        }
        .formStyle(.grouped)
        .navigationTitle("daemon 设置")
        .task {
            systemPrompt = config?["appendSystemPrompt"]?.stringValue ?? ""
            resumePrompt = config?["resumePrompt"]?.stringValue ?? ""
            if host.providers.isEmpty { await host.loadProviders(cwd: nil) }
        }
        .onChange(of: config?["appendSystemPrompt"]?.stringValue) { _, v in systemPrompt = v ?? "" }
        .onChange(of: config?["resumePrompt"]?.stringValue) { _, v in resumePrompt = v ?? "" }
        .sheet(item: $editingProfile) { draft in TerminalProfileEditor(draft: draft) { saveProfile($0) } }
        .sheet(item: $editingAgentProfile) { draft in AgentProfileEditor(host: host, draft: draft) { saveAgentProfile($0) } }
        .confirmationDialog("重启这台机器的 daemon？", isPresented: $confirmRestart) {
            if host.terminalsSurviveRestart {
                Button("重启（终端继续运行）") { Task { try? await host.restartDaemon() } }
                Button("重启并关闭所有终端", role: .destructive) { Task { try? await host.restartDaemon(killTerminals: true) } }
            } else {
                Button("重启", role: .destructive) { Task { try? await host.restartDaemon() } }
            }
        } message: {
            Text(host.terminalsSurviveRestart
                 ? "正在运行的会话会中断（开了「重启后恢复」的会接着做）；终端里的程序可以保留。"
                 : "正在运行的会话会中断，终端也会被关闭。这台 daemon 升级到 0.15 后，重启可以保留终端。")
        }
        .confirmationDialog("关闭中继？", isPresented: $confirmRelayOff) {
            Button("关闭", role: .destructive) { patch(["relay": ["enabled": false]]) }
        } message: {
            Text("本 App 就是经中继连的这台机器，关闭后会立刻断开，要回到那台机器上才能重新打开。")
        }
    }

    private var providerIds: [String] {
        let fromSnapshot = host.providers.compactMap { $0["provider"]?.stringValue }
        let fromConfig = config?["providers"]?.objectValue?.keys.map { $0 } ?? []
        var seen = Set<String>()
        return (fromSnapshot + fromConfig.sorted()).filter { seen.insert($0).inserted }
    }

    /// Terminal profiles keep their order in the "+" menu.
    private func move(_ i: Int, by d: Int) {
        var list = host.terminalProfiles
        guard list.indices.contains(i + d) else { return }
        list.swapAt(i, i + d)
        patch(["terminalProfiles": .array(list)])
    }

    private func snapshot(_ id: String) -> JSONValue? { host.providers.first { $0["provider"]?.stringValue == id } }

    private func toggle(_ title: String, on: Bool, patch make: @escaping (Bool) -> [String: JSONValue]) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { patch(make($0)) }))
    }

    private func patch(_ p: [String: JSONValue]) {
        error = nil
        Task {
            do { try await host.patchDaemonConfig(p) }
            catch { self.error = String(localized: "保存失败：\(String(describing: error))") }
        }
    }

    private func saveProfile(_ d: ProfileDraft) {
        var list = host.terminalProfiles
        let item = d.json
        if let i = d.index, list.indices.contains(i) { list[i] = item } else { list.append(item) }
        patch(["terminalProfiles": .array(list)])
    }

    private func saveAgentProfile(_ d: AgentProfileDraft) {
        var list = config?["agentProfiles"]?.arrayValue ?? []
        let item = d.json
        if let i = d.index, list.indices.contains(i) { list[i] = item } else { list.append(item) }
        patch(["agentProfiles": .array(list)])
    }
}

struct ProfileDraft: Identifiable {
    let id = UUID()
    let index: Int?
    var name: String
    var command: String
    var args: String
    let profileId: String

    init(index: Int?, _ p: JSONValue?) {
        self.index = index
        name = p?["name"]?.stringValue ?? ""
        command = p?["command"]?.stringValue ?? ""
        args = (p?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []).joined(separator: " ")
        profileId = p?["id"]?.stringValue ?? UUID().uuidString.prefix(8).lowercased()
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(profileId), "name": .string(name), "command": .string(command)]
        let a = args.split(separator: " ").map { JSONValue.string(String($0)) }
        if !a.isEmpty { o["args"] = .array(a) }
        return .object(o)
    }
}

private struct TerminalProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProfileDraft
    let onSave: (ProfileDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("名字", text: $draft.name)
                TextField("命令（如 claude）", text: $draft.command).font(.system(.body, design: .monospaced))
                TextField("参数（空格分隔，可用 {{{prompt}}}）", text: $draft.args).font(.system(.body, design: .monospaced))
            }
            .formStyle(.grouped)
            .navigationTitle("终端 profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(draft); dismiss() }.disabled(draft.name.isEmpty || draft.command.isEmpty)
                }
            }
        }
        .macOnly { $0.frame(minWidth: 440, minHeight: 260) }
    }
}

struct AgentProfileDraft: Identifiable {
    let id = UUID()
    let index: Int?
    var name: String
    var provider: String
    var model: String
    var modeId: String
    var notes: String
    let profileId: String
    let rest: [String: JSONValue]

    init(index: Int?, _ p: JSONValue?) {
        self.index = index
        name = p?["name"]?.stringValue ?? ""
        provider = p?["provider"]?.stringValue ?? "claude"
        model = p?["model"]?.stringValue ?? ""
        modeId = p?["modeId"]?.stringValue ?? ""
        notes = p?["notes"]?.stringValue ?? ""
        profileId = p?["id"]?.stringValue ?? UUID().uuidString.prefix(8).lowercased()
        rest = p?.objectValue ?? [:]
    }

    /// Keeps fields this editor doesn't show (icon, color, thinking, featureValues).
    var json: JSONValue {
        var o = rest
        o["id"] = .string(profileId)
        o["name"] = .string(name)
        o["provider"] = .string(provider)
        o["model"] = model.isEmpty ? nil : .string(model)
        o["modeId"] = modeId.isEmpty ? nil : .string(modeId)
        o["notes"] = notes.isEmpty ? nil : .string(notes)
        return .object(o.filter { $0.value != .null })
    }
}

private struct AgentProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    @State var draft: AgentProfileDraft
    let onSave: (AgentProfileDraft) -> Void

    var body: some View {
        let entry = host.providers.first { $0["provider"]?.stringValue == draft.provider }
        NavigationStack {
            Form {
                TextField("名字", text: $draft.name)
                Picker("Provider", selection: $draft.provider) {
                    ForEach(host.providers.compactMap { $0["provider"]?.stringValue }, id: \.self) { Text($0).tag($0) }
                }
                Picker("模型", selection: $draft.model) {
                    Text("默认").tag("")
                    ForEach(entry?["models"]?.arrayValue ?? [], id: \.self) { Text($0["label"]?.stringValue ?? "").tag($0["id"]?.stringValue ?? "") }
                }
                Picker("模式", selection: $draft.modeId) {
                    Text("默认").tag("")
                    ForEach(entry?["modes"]?.arrayValue ?? [], id: \.self) { Text($0["label"]?.stringValue ?? "").tag($0["id"]?.stringValue ?? "") }
                }
                TextField("备注", text: $draft.notes, axis: .vertical)
            }
            .formStyle(.grouped)
            .navigationTitle("会话预设")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(draft); dismiss() }.disabled(draft.name.isEmpty) }
            }
        }
        .macOnly { $0.frame(minWidth: 440, minHeight: 360) }
    }
}
