// Companion plugins: the daemon-side halves of features this client builds in (usage ring, reply speed,
// next-message suggestion, Chinese titles, board). They stay plugins because they run on the machine, but
// the client installs them itself, after asking once per machine, so a fresh install works out of the box.

import PaseoKit
import SwiftUI

struct CompanionPlugin: Identifiable {
    let id: String
    let name: String
    let summary: String
    /// Install reference for plugin.source.install: a plugins.paseo.sh entry or a git source.
    let source: String
    /// Ticked in the install sheet. Optional ones (they need something else on the machine) start unticked
    /// and never trigger the automatic prompt on their own.
    var recommended = true
}

enum CompanionPlugins {
    static let all: [CompanionPlugin] = [
        CompanionPlugin(id: "usage-reset", name: String(localized: "限额刷新时间"), summary: String(localized: "侧栏底部的用量环和各限额的刷新时间"),
                        source: "plugins.paseo.sh/52216108/usage-reset"),
        CompanionPlugin(id: "turn-speed", name: String(localized: "回合速度"), summary: String(localized: "每轮回复底部的生成速度和 token 数"),
                        source: "plugins.paseo.sh/52216108/turn-speed"),
        CompanionPlugin(id: "next-input", name: String(localized: "下一句建议"), summary: String(localized: "空输入框里预测你接下来要说的话"),
                        source: "plugins.paseo.sh/52216108/next-input"),
        CompanionPlugin(id: "title-style", name: String(localized: "标题风格"), summary: String(localized: "新会话自动起中文任务标题"),
                        source: "github:gavinguo521/title-style"),
        CompanionPlugin(id: "agent-taskboard", name: String(localized: "看板"), summary: String(localized: "在侧栏打开 agent-taskboard 看板；要先在那台机器上装好并启动看板服务"),
                        source: "git:gavinguo521/paseo-plugins:agent-taskboard", recommended: false),
        // 只要装在一台机器上（它会合并已关联机器的会话），所以不默认勾选。
        CompanionPlugin(id: "live-activity", name: String(localized: "灵动岛推送"), summary: String(localized: "App 不在前台时也更新 iPhone 灵动岛和锁屏；装一台就够，装完在设置 → 通知里配置 APNs 密钥"),
                        source: "git:gavinguo521/paseo-plugins:live-activity", recommended: false),
    ]

    /// Companions not installed on `host`, once its plugin list is known and it can install from sources.
    @MainActor static func missing(on host: HostStore) -> [CompanionPlugin] {
        guard host.state == .connected, host.pluginsLoaded,
              host.serverInfo?.hasFeature("pluginSourceInstallation") == true else { return [] }
        return all.filter { c in !host.plugins.contains { $0.id == c.id } }
    }
}

/// Asks once per machine to install the missing companion plugins, then installs them one by one.
struct CompanionPluginsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    let plugins: [CompanionPlugin]
    @State private var selected: Set<String>
    @State private var progress: [String: Phase] = [:]
    @State private var installing = false

    enum Phase: Equatable { case installing, done, failed(String) }

    init(host: HostStore, plugins: [CompanionPlugin]) {
        self.host = host
        self.plugins = plugins
        _selected = State(initialValue: Set(plugins.filter(\.recommended).map(\.id)))
    }

    private var finished: Bool { !progress.isEmpty && !progress.values.contains(.installing) && !installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("为 \(host.label) 安装配套插件").font(.title3.weight(.semibold))
                Text("这几项功能要在那台机器上运行，以插件形式装在它的 Paseo 里。装好后对这台机器的所有客户端都生效，随时可以在设置里停用或移除。")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plugins) { p in
                    HStack(alignment: .top, spacing: 10) {
                        status(p)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.name).font(.system(size: 13, weight: .medium))
                                if !p.recommended { Text("可选").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(Theme.border)) }
                            }
                            Text(p.summary).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            if case .failed(let e) = progress[p.id] {
                                Text(e).font(.system(size: 11)).foregroundStyle(Theme.destructive).lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack {
                if !finished {
                    Button("以后再说") { dismiss() }.disabled(installing)
                }
                Spacer()
                if finished {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(installing ? "正在安装…" : "安装") { install() }
                        .keyboardShortcut(.defaultAction)
                        .compatibleGlassButtonStyle(prominent: true)
                        .disabled(installing || selected.isEmpty)
                }
            }
        }
        .padding(24)
        .macOnly { $0.frame(width: 440) }
        .interactiveDismissDisabled(installing)
    }

    @ViewBuilder private func status(_ p: CompanionPlugin) -> some View {
        switch progress[p.id] {
        case .installing: ProgressView().controlSize(.small).frame(width: 18)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).frame(width: 18)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.destructive).frame(width: 18)
        case nil:
            Toggle("", isOn: Binding(get: { selected.contains(p.id) }, set: { on in
                if on { selected.insert(p.id) } else { selected.remove(p.id) }
            }))
            .labelsHidden().checkboxOnMac().disabled(installing)
            // 18pt 只够 Mac 的复选框；iOS 的开关更宽，固定 18 会盖住右边的名称
            .macOnly { $0.frame(width: 18) }
        }
    }

    private func install() {
        installing = true
        Task {
            for p in plugins where selected.contains(p.id) {
                progress[p.id] = .installing
                do {
                    try await host.installPlugin(source: p.source, ref: nil)
                    progress[p.id] = .done
                } catch {
                    progress[p.id] = .failed("\(error)")
                }
            }
            // Installing them means wanting them to run; a new daemon has the global switch off.
            if !host.pluginsGloballyEnabled { try? await host.patchDaemonConfig(["pluginsEnabled": true]) }
            installing = false
        }
    }
}
