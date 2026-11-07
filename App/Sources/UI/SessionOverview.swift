import PaseoKit
import SwiftUI

/// 总览只读真实会话状态，权限操作继续使用会话页的 PermissionCard。
enum OverviewLane: String, CaseIterable, Identifiable {
    case input, running, review, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .input: String(localized: "待输入")
        case .running: String(localized: "运行中")
        case .review: String(localized: "待查看")
        case .done: String(localized: "已完成")
        }
    }
    static func of(_ agent: Agent) -> Self {
        switch agent.bucket {
        case .needsInput: .input
        case .failed, .attention: .review
        case .running: .running
        case .done: agent.status == .initializing ? .running : .done
        }
    }
}

struct OverviewEntry: Identifiable {
    let host: HostStore
    let agent: Agent
    var id: AgentRef { AgentRef(serverId: host.id, agentId: agent.id) }
}

@MainActor extension AppModel {
    func overviewEntries(hostID: String?, provider: String?, query: String) -> [OverviewEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return hosts.filter { hostID == nil || $0.id == hostID }.flatMap { host in
            host.agents.values.filter {
                $0.archivedAt == nil && !host.isNested($0) && (provider == nil || $0.provider == provider)
                && (text.isEmpty || [$0.displayTitle, $0.cwd, host.label, projectName(of: $0, in: host)]
                    .contains { $0.localizedStandardContains(text) })
            }.map { OverviewEntry(host: host, agent: $0) }
        }.sorted {
            let a = $0.agent.updatedAt ?? $0.agent.createdAt ?? .distantPast
            let b = $1.agent.updatedAt ?? $1.agent.createdAt ?? .distantPast
            if a != b { return a > b }
            return ($0.id.serverId, $0.id.agentId) < ($1.id.serverId, $1.id.agentId)
        }
    }
}

struct SessionOverview: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var hostID: String?
    @State private var provider: String?
    @State private var lane: OverviewLane = .input

    var body: some View {
        let entries = model.overviewEntries(hostID: hostID, provider: provider, query: query)
        VStack(spacing: 0) {
            HStack {
                TextField("搜索会话、项目或机器", text: $query).textFieldStyle(.roundedBorder)
                Menu {
                    Picker("机器", selection: $hostID) {
                        Text("全部主机").tag(String?.none)
                        ForEach(model.hosts) { Text($0.label).tag(Optional($0.id)) }
                    }
                    Picker("提供商", selection: $provider) {
                        Text("全部提供商").tag(String?.none)
                        ForEach(Array(Set(model.hosts.flatMap { $0.agents.values.map(\.provider) })).sorted(), id: \.self) {
                            Text($0).tag(Optional($0))
                        }
                    }
                } label: { Label("筛选", systemImage: "line.3.horizontal.decrease").fixedSize().mobileTouchTarget() }
                if hostID != nil || provider != nil {
                    Button("重置") { hostID = nil; provider = nil }
                }
            }.padding()
            if model.hosts.contains(where: { $0.state != .connected }) {
                Label("离线机器显示最后收到的状态，连接后自动更新", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(Theme.muted).padding(.horizontal).padding(.bottom, 8)
            }
            GeometryReader { geometry in
                if geometry.size.width < 700 {
                    VStack(spacing: 0) {
                        Picker("会话状态", selection: $lane) {
                            ForEach(OverviewLane.allCases) { item in
                                Text("\(item.title) \(entries.filter { OverviewLane.of($0.agent) == item }.count)").tag(item)
                            }
                        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal).padding(.bottom, 8)
                        laneView(lane, entries: entries)
                    }
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(OverviewLane.allCases) { item in
                                laneView(item, entries: entries).frame(width: max(260, (geometry.size.width - 60) / 4))
                            }
                        }.padding(.horizontal)
                    }
                }
            }
        }
        .background(Theme.surface0)
        .navigationTitle("会话总览")
    }

    private func laneView(_ lane: OverviewLane, entries: [OverviewEntry]) -> some View {
        let visible = entries.filter { OverviewLane.of($0.agent) == lane }
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text(lane.title).font(.headline); Spacer(); Text("\(visible.count)").monospacedDigit().foregroundStyle(Theme.muted) }
                .padding(.horizontal, 12).padding(.top, 12)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if visible.isEmpty { Text("暂无会话").foregroundStyle(Theme.muted).padding(24) }
                    ForEach(visible) { entry in OverviewCard(entry: entry) }
                }.padding(10)
            }
        }.background(Theme.surface1, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct OverviewCard: View {
    @Environment(AppModel.self) private var model
    let entry: OverviewEntry
    @State private var expanded = false
    @State private var confirmStop = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let host = entry.host
        let agent = entry.agent
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                StatusDot(bucket: agent.bucket)
                Text(agent.displayTitle).font(.headline).lineLimit(3)
            }
            Text(model.projectName(of: agent, in: host) + " · " + host.label)
                .font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            Text([agent.provider, agent.model].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            if host.state != .connected { Label("离线", systemImage: "wifi.slash").font(.caption) }
            if let start = agent.activeTurnStartedAt, agent.status == .running {
                HStack { Text("本轮用时"); Text(start, style: .timer).monospacedDigit() }.font(.caption)
            }
            if let error = agent.lastError { Text(error).font(.caption).foregroundStyle(Theme.destructive).lineLimit(3) }
            if !agent.pendingPermissions.isEmpty {
                Button(expanded ? "收起请求" : "查看待处理请求") { expanded.toggle() }
                if expanded {
                    ForEach(agent.pendingPermissions) { request in
                        PermissionCard(host: host, agentId: agent.id, request: request)
                            .id(request.id).disabled(host.state != .connected)
                    }
                }
            }
            HStack {
                if agent.status == .running || agent.status == .initializing {
                    Button("停止", role: .destructive) { confirmStop = true }.disabled(busy || host.state != .connected)
                }
                Spacer()
                Button("打开会话") { model.open(entry.id) }.buttonStyle(.bordered)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface0, in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("停止这个会话？", isPresented: $confirmStop) {
            Button("停止", role: .destructive) {
                guard host.state == .connected,
                      let current = host.agents[agent.id], current.status == .running || current.status == .initializing else { return }
                busy = true
                Task {
                    do { try await host.cancel(agent.id); error = nil } catch { self.error = String(describing: error) }
                    busy = false
                }
            }
        }
    }
}
