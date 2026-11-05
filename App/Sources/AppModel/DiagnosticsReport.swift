// 「导出诊断信息」: one text file a colleague can send when something is off — versions, each machine's connection,
// providers (with their diagnostics), plugins and their logs, this Mac's daemon log, the app's own log, and the shape
// of the session being viewed. No chat text; pairing links, passwords and keys are masked.

import Foundation
import PaseoKit

@MainActor
enum DiagnosticsReport {
    static func build(model: AppModel) async -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        out.append("# Paseo Native 诊断信息")
        out.append("导出时间：" + Date().formatted(.iso8601))
        out.append("App：" + ((info["CFBundleShortVersionString"] as? String) ?? "?") + " (" + ((info["CFBundleVersion"] as? String) ?? "?") + ")")
        out.append("系统：" + ProcessInfo.processInfo.operatingSystemVersionString + " · " + hardwareModel())

        for host in model.hosts {
            out.append("")
            out += await hostSection(host)
        }
        #if os(macOS)
        out.append("")
        out += localDaemonSection()
        #endif
        out.append("")
        out += currentSessionSection(model: model)
        out.append("")
        out.append("## App 日志（最近 500 条）")
        out += AppLog.shared.snapshot().suffix(500)
        return redact(out.joined(separator: "\n"))
    }

    private static func hostSection(_ host: HostStore) async -> [String] {
        var out = ["## 机器：" + host.label]
        out.append("连接：" + String(describing: host.state))
        if let s = host.serverInfo {
            out.append("daemon：v" + (s.version ?? "?") + " · " + (s.hostname ?? "?") + " · " + s.serverId)
            out.append("特性：" + s.features.filter { $0.value.boolValue == true }.keys.sorted().joined(separator: " "))
        }
        if let c = host.daemonConfig {
            out.append("插件总开关：" + (c["pluginsEnabled"]?.boolValue == true ? "开" : "关")
                       + " · 中继：" + (c["relay"]?["enabled"]?.boolValue == false ? "关" : "开"))
        }
        guard host.state == .connected else { return out }

        out.append("")
        out.append("### Provider")
        for p in host.providers {
            let id = p["provider"]?.stringValue ?? "?"
            out.append("- " + id + "：状态 " + (p["status"]?.stringValue ?? "?") + " · 启用 " + (p["enabled"]?.boolValue == false ? "否" : "是")
                       + " · 模型 \(p["models"]?.arrayValue?.count ?? 0) 个" + (p["error"]?.stringValue.map { " · 错误 " + $0 } ?? ""))
        }
        for p in host.providers {
            guard let id = p["provider"]?.stringValue else { continue }
            out.append("")
            out.append("### Provider 诊断：" + id)
            out.append((try? await host.providerDiagnostic(id)) ?? "诊断失败")
        }

        out.append("")
        out.append("### 插件")
        for p in host.plugins {
            out.append("- " + p.id + "：" + p.status + (p.enabled ? "" : "（已关闭）") + (p.error.map { " · 错误 " + $0 } ?? ""))
        }
        for p in host.plugins {
            let logs = await host.pluginLogs(p.id)
            guard !logs.isEmpty else { continue }
            out.append("")
            out.append("### 插件日志：" + p.id + "（最近 40 行）")
            out += logs.suffix(40)
        }
        return out
    }

    #if os(macOS)
    private static func localDaemonSection() -> [String] {
        let d = LocalDaemon.shared
        var out = ["## 本机 daemon"]
        if let s = d.status {
            out.append("运行者：" + String(describing: s.owner) + " · 版本 " + (s.version ?? "?") + " · 监听 " + (s.listen ?? "?"))
        }
        out.append("App 安装的命令行版本：" + (d.installedVersion ?? "未安装"))
        out.append("")
        out.append("### daemon 日志（最近 300 行，不含每 30 秒一次的性能统计）")
        out += d.logTail(lines: 3000).split(separator: "\n").filter { !$0.contains("\"ws_runtime_metrics\"") }.suffix(300).map(String.init)
        return out
    }
    #endif

    /// The session on screen: provider, status, and its last rows by kind and time (never their text).
    private static func currentSessionSection(model: AppModel) -> [String] {
        var ref: AgentRef?
        if case .agent(let r) = model.destination { ref = r }
        if ref == nil, let ws = model.currentWorkspace, case .agent(let id) = model.selectedTab(ws) {
            ref = AgentRef(serverId: ws.serverId, agentId: id)
        }
        guard let ref, let host = model.host(ref.serverId), let agent = host.agents[ref.agentId] else {
            return ["## 当前会话", "（没有打开会话）"]
        }
        var out = ["## 当前会话（只有类型和时间，不含内容）"]
        out.append("机器 " + host.label + " · " + agent.provider + "/" + (agent.model ?? "默认") + " · 状态 " + String(describing: agent.status) + " · id " + agent.id)
        for row in (host.timelines[agent.id]?.rows ?? []).suffix(40) {
            let time = row.timestamp.map { $0.formatted(.iso8601) } ?? "-"
            out.append(time + " " + kind(row.item))
        }
        return out
    }

    private static func kind(_ item: TimelineItem) -> String {
        switch item {
        case .toolCall(_, let name, let status, _, _, _): "toolCall " + name + " " + status
        case .plugin(_, let pluginId, let kind, _, _): "plugin " + pluginId + "/" + kind
        case .compaction(let status, _, _): "compaction " + status
        case .unknown(let type): "unknown " + type
        default: Mirror(reflecting: item).children.first?.label ?? String(describing: item)
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Masks pairing links (the key to a machine) and anything that looks like a password, token or API key.
    static func redact(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"(?i)\b(?:https?|paseo)://\S*(?:#offer=|#connect=)\S*"#, "<配对链接已隐藏>"),
            (#"(?i)\brelay://\S*[?#]\S*"#, "<配对链接已隐藏>"),
            (#"(?i)\bbearer\s+\S+"#, "Bearer <已隐藏>"),
            (#"(?i)("?(?:password|passwd|secret|token|api[_-]?key|authorization)"?\s*[:=]\s*)("[^"]*"|\S+)"#, "$1<已隐藏>"),
            (#"\bsk-[A-Za-z0-9_\-]{12,}"#, "<密钥已隐藏>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}
