import PaseoKit
import CoreImage
import SwiftUI

struct AddHostView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanning = false
    @State private var label = ""
    @State private var password = ""
    @State private var error: String?
    /// "link" (pairing link through the relay) or "direct" (address).
    @State private var method = "link"
    @State private var address = ""
    @State private var useTls = false
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("方式", selection: $method) {
                    // 分段控件不会截断文字，每段等宽取最长那段；标签太长（英文版尤其）会把整个表单撑出窗口，
                    // 两侧被裁掉。中继/加密说明放在下面的 footer 里。
                    Text("配对链接").tag("link")
                    Text("直连地址").tag("direct")
                }
                .pickerStyle(.segmented).labelsHidden()
                if method == "direct" {
                    Section {
                        TextField("地址", text: $address, prompt: Text(verbatim: "192.168.1.10:6767 或 localhost"))
                            .font(.system(.body, design: .monospaced)).autocorrectionDisabled()
                        Toggle("使用 TLS（wss）", isOn: $useTls)
                    } footer: {
                        Text("直连不经过中继，也没有端到端加密，只适合本机或可信的局域网。daemon 默认只监听 127.0.0.1:6767，别的设备要连需要它监听局域网地址；用域名连还要在 daemon 里允许该主机名。")
                    }
                } else {
                Section {
                    TextField("配对链接", text: $link, prompt: Text(verbatim: "https://app.paseo.sh/#offer=… 或 relay://…"), axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    #if os(iOS)
                    Button("扫描二维码", systemImage: "qrcode.viewfinder") { scanning = true }
                        .sheet(isPresented: $scanning) { QRScannerSheet { link = $0 } }
                    Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                        link = UIPasteboard.general.string ?? ""
                    }
                    #endif
                } footer: {
                    Text("经中继连接，端到端加密。在电脑上运行 paseo daemon pair，扫它显示的二维码或复制链接。链接等同于这台机器的钥匙，只保存在本机钥匙串里。")
                }
                }
                Section {
                    // iOS forms show only the prompt, so it carries the label there.
                    #if os(iOS)
                    TextField("名字", text: $label, prompt: Text("名字（留空用机器自己的名字）"))
                    SecureField("daemon 密码", text: $password, prompt: Text("daemon 密码（没设可留空）"))
                    #else
                    TextField("名字", text: $label, prompt: Text("留空用机器自己的名字"))
                    SecureField("daemon 密码", text: $password, prompt: Text("没设可留空"))
                    #endif
                }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加机器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if connecting { ProgressView().controlSize(.small) }
                    else {
                        Button(method == "direct" ? "连接并添加" : "添加") { add() }
                            .disabled((method == "direct" ? address : link).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }

    private func add() {
        error = nil
        if method == "link" {
            do { try model.addHost(link: link, label: label, password: password); dismiss() }
            catch { self.error = String(localized: "链接无效：\(error)") }
            return
        }
        connecting = true
        Task {
            do { _ = try await model.addDirectHost(address: address, useTls: useTls, label: label, password: password); dismiss() }
            catch { self.error = String(localized: "连不上：\(error)") }
            connecting = false
        }
    }
}

struct HostsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var showAddHost: Bool
    var tabPicker: Binding<Int>? = nil

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                LocalDaemonSection()
                #endif
                Section("已添加的机器") {
                    ForEach(model.hosts) { host in
                        NavigationLink {
                            HostDetailView(host: host)
                        } label: {
                            HStack(spacing: 10) {
                                HostStatusDot(state: host.state)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) { Text(host.label); LatencyBadge(host: host, size: 12) }
                                    Text([host.serverInfo?.hostname, host.serverInfo?.version.map { "paseo \($0)" }, host.state.label]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }
                        }
                    }
                    Button("添加机器", systemImage: "plus") {
                        dismiss()
                        showAddHost = true
                    }
                }
            }
            .formStyle(.grouped)
            .toolbar {
                #if os(iOS)
                if let tabPicker {
                    ToolbarItem(placement: .principal) { SettingsTabPicker(tab: tabPicker) }
                        .compatibleSharedBackgroundHidden()
                }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}

/// Long text with copy (diagnostics).
struct TextReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button { Pasteboard.copy(text) } label: { Text("复制").mobileTouchTarget() }
                Button { dismiss() } label: { Text("完成").mobileTouchTarget() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading) }
        }
        .macOnly { $0.frame(minWidth: 640, minHeight: 480) }
    }
}

/// Machine identity colours (official host badges).
enum HostColor {
    static let all: [(name: String, label: String, color: SwiftUI.Color)] = [
        ("blue", String(localized: "蓝"), .blue), ("green", String(localized: "绿"), .green), ("orange", String(localized: "橙"), .orange), ("purple", String(localized: "紫"), .purple),
        ("pink", String(localized: "粉"), .pink), ("teal", String(localized: "青"), .teal), ("red", String(localized: "红"), .red), ("yellow", String(localized: "黄"), .yellow),
    ]
    static func color(for serverId: String) -> SwiftUI.Color? {
        let name = AppDefaults.store.string(forKey: "hostColor." + serverId) ?? ""
        return all.first { $0.name == name }?.color
    }
}

enum QRCode {
    static func image(_ text: String) -> Image? {
        let f = CIFilter(name: "CIQRCodeGenerator")
        f?.setValue(Data(text.utf8), forKey: "inputMessage")
        f?.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f?.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}

struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    @State private var label = ""
    @State private var password = ""
    @State private var confirmRemove = false
    @State private var pairing: String?
    @State private var status: HostStore.DaemonStatus?
    @State private var busy: String?
    @State private var result: String?
    @State private var confirmUpdate = false
    @State private var report: String?
    @AppStorage private var color: String

    init(host: HostStore) {
        self.host = host
        _color = AppStorage(wrappedValue: "", "hostColor." + host.id, store: AppDefaults.store)
    }

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("连接", value: host.state.label)
                if let t = host.latencyText { LabeledContent("延迟", value: t) }
                if let info = host.serverInfo {
                    LabeledContent("主机名", value: info.hostname ?? "—")
                    LabeledContent("版本", value: info.version ?? "—")
                }
                LabeledContent(host.offer.isDirect ? "直连" : "中继", value: host.offer.directEndpoint ?? host.offer.relayEndpoint)
                LabeledContent("会话 / 工作区", value: "\(host.agents.count) / \(host.workspaces.count)")
                Button("立即重连") { host.reconnectNow() }
            }
            Section("这台机器") {
                NavigationLink("daemon 设置") { DaemonSettingsView(host: host) }
                if let s = status {
                    LabeledContent("daemon", value: [s.version.map { "v" + $0 }, s.pid.map { "pid \($0)" },
                                                     s.startedAt.map { String(localized: "启动于 \(formatTimestamp($0))") }].compactMap { $0 }.joined(separator: " · "))
                }
                HStack {
                    Button("更新 daemon…") { confirmUpdate = true }
                    Button("诊断报告") { run(String(localized: "生成诊断中")) { report = try await host.diagnostics() } }
                    Spacer()
                    if let busy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(Theme.muted) }
                }
                .disabled(busy != nil || host.state != .connected)
                if let result { Text(result).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Section {
                if let pairing {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = QRCode.image(pairing) { qr.interpolation(.none).resizable().frame(width: 160, height: 160) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在另一台设备的 Paseo 里扫码或粘贴链接，就能连上这台机器。").font(.system(size: 12))
                            Text("配对链接等同这台机器的钥匙，不要发到聊天或公开的地方。").font(.system(size: 12)).foregroundStyle(Theme.dotWarning)
                            HStack {
                                Button("复制链接") { Pasteboard.copy(pairing) }
                                Button("隐藏") { self.pairing = nil }
                            }
                        }
                    }
                } else {
                    Button("显示配对二维码和链接") { run(String(localized: "获取中")) { pairing = try await host.pairingLink() } }
                        .disabled(host.state != .connected)
                }
            } header: { Text("添加到其他设备") }
            Section("外观") {
                Picker("颜色", selection: $color) {
                    Text("无").tag("")
                    ForEach(HostColor.all, id: \.name) { c in
                        Label { Text(c.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(c.color) }.tag(c.name)
                    }
                }
                Text("在侧栏和会话标题里用来区分机器").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            SkillsSection(host: host)
            LabelsManager(host: host)
            PluginsSection(host: host)
            Section("名字") {
                TextField("名字", text: $label)
                    .onSubmit { model.rename(host: host.id, to: label) }
            }
            Section {
                SecureField("新密码", text: $password)
                Button("保存密码") { model.setPassword(host: host.id, password.isEmpty ? nil : password); password = "" }
            } header: {
                Text("daemon 密码")
            } footer: {
                Text(host.offer.password == nil ? "未设置" : "已保存在钥匙串")
            }
            Section {
                Button("移除这台机器", role: .destructive) { confirmRemove = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.label)
        .onAppear { label = host.label }
        .task(id: host.state == .connected) { status = try? await host.daemonStatus() }
        .onDisappear {
            pairing = nil
            if label != host.label, !label.isEmpty { model.rename(host: host.id, to: label) }
        }
        .confirmationDialog("更新「\(host.label)」上的 daemon？", isPresented: $confirmUpdate) {
            Button("更新") { run(String(localized: "更新中，可能要几分钟")) { let v = try await host.updateDaemon(); result = String(localized: "已更新：\(v)，daemon 会自动重启") } }
        } message: { Text("更新期间这台机器上运行中的会话可能会中断。") }
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            TextReportSheet(title: "诊断报告", text: report ?? "")
        }
        .confirmationDialog("移除「\(host.label)」？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { model.removeHost(host.id); dismiss() }
        } message: {
            Text("只删除本机保存的配对信息，不影响那台机器。")
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        busy = label
        result = nil
        Task {
            do { try await work() } catch { result = String(localized: "失败：\(error)") }
            busy = nil
        }
    }
}

/// Paseo orchestration skills on the host (official settings → host → 编排 skills).
private struct SkillsSection: View {
    let host: HostStore
    @State private var status: HostStore.SkillsStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var choosing = false
    @State private var all = true
    @State private var picked: Set<String> = []
    @State private var confirm: [String] = []
    @State private var confirmUninstall = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateLabel)
                    if let s = status, s.state == "drift", !s.pendingOps.isEmpty {
                        Text(s.pendingOps.joined(separator: String(localized: "、", comment: "列举时的分隔符（顿号）"))).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else if let s = status {
                    if s.state != "up-to-date" { Button(s.state == "not-installed" ? "安装" : "更新") { run { try await host.skills("reconcile") } } }
                    if s.state != "not-installed" {
                        Button("选择…") { all = s.selected == nil; picked = Set(s.selected ?? s.available); choosing = true }
                        Button("卸载", role: .destructive) { confirmUninstall = true }
                    }
                }
            }
            if choosing, let s = status {
                Toggle("全部 skills（包括以后新增的）", isOn: $all)
                if !all {
                    ForEach(s.available, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { picked.contains(name) }, set: { if $0 { picked.insert(name) } else { picked.remove(name) } }))
                    }
                }
                HStack {
                    Spacer()
                    Button("取消") { choosing = false }
                    Button("保存") { save(confirmed: []) }.buttonStyle(.borderedProminent)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
        } header: {
            Text("编排 skills")
        } footer: {
            Text("教会 Agent 通过 paseo 命令行编排任务，装在主机的 ~/.agents、~/.claude、~/.codex 里。")
        }
        .task(id: host.state == .connected) { if host.state == .connected { run { try await host.skills("get_status") } } }
        .confirmationDialog("移除取消勾选的 skills？", isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } })) {
            Button("移除", role: .destructive) { let c = confirm; confirm = []; save(confirmed: c) }
        } message: { Text("将从 ~/.agents、~/.claude、~/.codex 中删除 \(confirm.joined(separator: String(localized: "、", comment: "列举时的分隔符（顿号）")))，你在这些 skill 文件夹里加的内容也会一并删除。") }
        .confirmationDialog("卸载 Paseo skills？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { run { try await host.skills("uninstall") } }
        } message: { Text("会从 ~/.agents、~/.claude、~/.codex 移除所有 Paseo 编排 skills。") }
    }

    private var stateLabel: String {
        switch status?.state {
        case "up-to-date": String(localized: "已安装，是最新的") + (status?.selected.map { String(localized: "（选了 \($0.count) 个）") } ?? "")
        case "drift": String(localized: "有更新可用")
        case "not-installed": String(localized: "未安装")
        default: String(localized: "检查中…")
        }
    }

    private func save(confirmed: [String]) {
        run {
            let r = try await host.saveSkillSelection(all ? nil : Array(picked).sorted(), confirmedRemovals: confirmed)
            if !r.confirmRemovals.isEmpty && confirmed.isEmpty { confirm = r.confirmRemovals } else { choosing = false }
            return r
        }
    }

    private func run(_ work: @escaping () async throws -> HostStore.SkillsStatus) {
        busy = true
        error = nil
        Task {
            do { status = try await work() } catch { self.error = "\(error)" }
            busy = false
        }
    }
}
