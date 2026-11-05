// 设置 → 机器 → 这台 Mac: run the daemon here without the official desktop app (see LocalDaemon).

#if os(macOS)
import PaseoKit
import SwiftUI

struct LocalDaemonSection: View {
    @Environment(AppModel.self) private var model
    @State private var daemon = LocalDaemon.shared
    @State private var confirm: Action?
    @State private var showLog = false

    enum Action: String, Identifiable {
        case install, migrate, update, restart, stop, returnToOfficial
        var id: String { rawValue }
    }

    private var status: LocalDaemon.Status? { daemon.status }
    /// Sessions running on this Mac's daemon: restarting it interrupts them.
    private var runningHere: Int {
        guard let id = status?.serverId, let h = model.host(id) else { return 0 }
        return h.agents.values.filter { $0.status == .running }.count
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").foregroundStyle(Theme.muted).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Theme.muted) }
                }
                Spacer()
                if daemon.isBusy || status == nil { ProgressView().controlSize(.small) }
            }
            if let step = daemon.step { Text(step).font(.caption).foregroundStyle(Theme.muted) }
            if let e = daemon.error { Text(e).font(.caption).foregroundStyle(Theme.destructive).textSelection(.enabled) }
            if !daemon.isBusy, let status { actions(status) }
        } header: {
            Text(daemon.isTest ? "这台 Mac（测试目录）" : "这台 Mac")
        } footer: {
            Text(footer).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await daemon.refresh()
            if daemon.status?.owner == .native { await daemon.checkLatest() }
            #if DEBUG
            // PASEO_LOCAL_ACTION=install|migrate|update|restart|stop|returnToOfficial runs it without the confirmation (with PASEO_LOCAL_HOME).
            if daemon.isTest, let a = ProcessInfo.processInfo.environment["PASEO_LOCAL_ACTION"].flatMap(Action.init(rawValue:)) { run(a) }
            #endif
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { action in
            Button(confirmButton(action), role: action == .stop || action == .returnToOfficial ? .destructive : nil) { run(action) }
        } message: { action in
            Text(confirmMessage(action))
        }
        .sheet(isPresented: $showLog) { TextReportSheet(title: "daemon 日志", text: daemon.logTail()) }
    }

    @ViewBuilder private func actions(_ status: LocalDaemon.Status) -> some View {
        switch status.owner {
        case .official:
            Button("改由本 App 运行…") { confirm = .migrate }
        case .native:
            HStack {
                Button("重启") { confirm = .restart }
                Button("停止") { confirm = .stop }
                Spacer()
                if daemon.updateAvailable, let v = daemon.latestVersion {
                    Button("更新到 \(v)…") { confirm = .update }.buttonStyle(.borderedProminent)
                } else {
                    Button("检查更新") { Task { await daemon.checkLatest() } }
                }
                Button("日志") { showLog = true }
            }
            if daemon.officialAppURL != nil { Button("切回官方 App…") { confirm = .returnToOfficial } }
        case .stopped:
            if daemon.isServiceInstalled {
                HStack {
                    Button("启动") { Task { await daemon.start(); await pairIfNeeded() } }
                    if daemon.officialAppURL != nil { Button("切回官方 App…") { confirm = .returnToOfficial } }
                    Spacer()
                    Button("日志") { showLog = true }
                }
            } else {
                Button("在这台 Mac 上安装并运行 Paseo…") { confirm = .install }
            }
        case .other:
            EmptyView()
        }
    }

    private var title: String {
        guard let status else { return "检查中…" }
        switch status.owner {
        case .official: return "由官方 Paseo App 运行"
        case .native: return "由本 App 运行"
        case .stopped: return daemon.isServiceInstalled ? "已停止" : "没有运行 Paseo"
        case .other: return "由其他方式运行（命令行、Docker 等）"
        }
    }

    private var detail: String? {
        guard let status, status.owner != .stopped else { return nil }
        var parts = [status.version.map { "paseo \($0)" }, status.listen].compactMap { $0 }
        if status.owner == .native { parts.append("开机自动启动") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var footer: String {
        switch status?.owner {
        case .official: "改由本 App 运行后，daemon 开机自动启动，不再需要打开官方 App，也可以把它卸载。机器身份、配对、会话和插件都在 ~/.paseo，不会变。"
        case .native: "命令行和 daemon 装在「应用程序支持/Paseo Native」里，~/.local/bin/paseo 指向它。更新只升级 daemon；官方客户端的新功能要等本 App 跟进。不要同时打开官方 App，它会再起一个 daemon 抢同一个 ~/.paseo；想换回去用「切回官方 App」。"
        case .stopped: daemon.isServiceInstalled ? "daemon 已停止，开机也不会再启动，直到你点「启动」。" : "会安装官方的 Paseo 命令行（机器上没有 Node 20+ 时一并下载 Node），约 600 MB，用开机启动项保持运行。"
        default: ""
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .install: "在这台 Mac 上安装并运行 Paseo？"
        case .migrate: "改由本 App 运行 daemon？"
        case .update: "更新 daemon 到 \(daemon.latestVersion ?? "")？"
        case .restart: "重启 daemon？"
        case .stop: "停止 daemon？"
        case .returnToOfficial: "切回官方 Paseo App？"
        case nil: ""
        }
    }

    private func confirmButton(_ a: Action) -> String {
        switch a {
        case .install: "安装并运行"
        case .migrate: "改由本 App 运行"
        case .update: "更新并重启"
        case .restart: "重启"
        case .stop: "停止"
        case .returnToOfficial: "切回官方 App"
        }
    }

    private func confirmMessage(_ a: Action) -> String {
        let interrupt = runningHere > 0 ? "现在有 \(runningHere) 个会话正在运行，会被中断。" : "没有会话在运行。"
        switch a {
        case .install:
            return "会安装 Paseo 命令行 \(LocalDaemon.initialVersion)，约 1–2 分钟，然后开机自动运行 daemon，并把这台 Mac 加到机器列表。"
        case .migrate:
            let link = daemon.isTest ? "" : "~/.local/bin/paseo 会改为指向本 App 安装的命令行（原来指向官方 App）。"
            return "会退出官方 Paseo App、停掉它的 daemon，再用同一个 ~/.paseo 启动本 App 管理的 daemon，机器 ID 和配对不变。\(link)\(interrupt)"
        case .update:
            return "只升级 daemon（\(daemon.installedVersion ?? "?") → \(daemon.latestVersion ?? "?")），完成后会重启。\(interrupt)"
        case .restart, .stop:
            return interrupt
        case .returnToOfficial:
            let link = daemon.isTest ? "" : "~/.local/bin/paseo 会指回原来的命令行。"
            return "会停掉本 App 的 daemon、取消它的开机启动，再打开官方 Paseo App，由它用同一个 ~/.paseo 运行 daemon，机器 ID 和配对不变。\(link)本 App 装的命令行留着，以后可以再切回来。\(interrupt)"
        }
    }

    private func run(_ a: Action) {
        Task {
            switch a {
            case .install: await daemon.install()
            case .migrate: await daemon.migrateFromOfficial()
            case .update: await daemon.update()
            case .restart: await daemon.restart()
            case .stop: await daemon.stop()
            case .returnToOfficial: await daemon.returnToOfficial()
            }
            if a == .install || a == .migrate { await pairIfNeeded() }
        }
    }

    /// The local daemon joins the machine list on its own (no pairing link to copy).
    private func pairIfNeeded() async {
        guard daemon.status?.owner == .native, let id = daemon.status?.serverId, model.host(id) == nil,
              let link = await daemon.pairingLink() else { return }
        _ = try? model.addHost(link: link, label: "这台 Mac", password: nil)
    }
}
#endif
