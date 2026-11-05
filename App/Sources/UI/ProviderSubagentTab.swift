// A provider-internal subagent (e.g. Claude's Task tool) in its own workspace tab, read-only, live.
// Official: panels/provider-subagent-panel.tsx.

import SwiftUI
import PaseoKit

struct ProviderSubagentTab: View {
    @Environment(AppModel.self) private var model
    let host: HostStore
    let workspace: Workspace?
    let parentAgentId: String
    let subagentId: String
    @State private var env: TimelineEnvironment?
    @State private var loadingOlder = false
    @AppStorage("autoExpandReasoning") private var autoExpandReasoning = true

    private var key: String { HostStore.providerSubagentKey(parentAgentId, subagentId) }
    private var subagent: ProviderSubagent? { host.providerSubagents[parentAgentId]?.first { $0.id == subagentId } }
    private var timeline: AgentTimeline? { host.providerSubagentTimelines[key] }
    private var children: [ProviderSubagent] { host.providerSubagents(of: parentAgentId, under: subagentId) }
    private var parent: Agent? { host.agents[parentAgentId] }
    private var running: Bool { subagent?.status == "running" }
    private var supported: Bool { host.serverInfo.map { $0.hasFeature("projectedSubagentTimeline") } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            if !supported {
                ContentUnavailableView("主机版本太旧", systemImage: "arrow.up.circle",
                                       description: Text("升级这台机器上的 Paseo 后才能查看子代理的对话"))
            } else {
                transcript
            }
            bottomBar
        }
        .navigationTitle(subagent?.label ?? "子代理")
        #if os(macOS)
        .navigationSubtitle(subagent?.detail ?? parent?.displayTitle ?? "")
        #endif
        .onAppear { if env == nil { env = makeEnvironment() } }
        .task(id: host.state == .connected) {
            guard host.state == .connected, supported else { return }
            await host.loadProviderSubagentTimeline(parentAgentId: parentAgentId, subagentId: subagentId)
        }
        // Loads the subagent list, and keeps live rows and status coming: the push is on only while someone watches.
        .task(id: host.state == .connected) { await host.watchProviderSubagents(parentAgentId) }
        // Finishing settles the last streamed rows into the authoritative history.
        .onChange(of: subagent?.status) { _, status in
            guard status != nil, status != "running" else { return }
            Task { await host.loadProviderSubagentTimeline(parentAgentId: parentAgentId, subagentId: subagentId) }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let e = host.providerSubagentTimelineErrors[key] {
                    HStack {
                        Banner(level: "error", message: e)
                        Button("重试") {
                            Task { await host.loadProviderSubagentTimeline(parentAgentId: parentAgentId, subagentId: subagentId) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if timeline?.hasOlder == true {
                    ProgressView().frame(maxWidth: .infinity)
                        .onAppear {
                            guard !loadingOlder else { return }
                            loadingOlder = true
                            Task {
                                await host.loadProviderSubagentTimeline(parentAgentId: parentAgentId, subagentId: subagentId, older: true)
                                loadingOlder = false
                            }
                        }
                }
                if timeline?.isLoaded == true, timeline?.rows.isEmpty == true, !running {
                    ContentUnavailableView("没有内容", systemImage: "bubble.left")
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(DisplayItem.build(timeline?.rows ?? [], lastTurnActive: running, collapse: false,
                                          separateReasoning: autoExpandReasoning)) { item in
                    TimelineItemView(item: item).padding(4)
                }
                .environment(\.sentImages, host.sentImages)
                .environment(\.timelineActions, env?.actions ?? TimelineActions())
                .environment(\.hostFileReader, env?.fileReader)
                .environment(\.agentTitle, env?.agentTitle)
                if running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("运行中")
                    }
                    .font(.system(size: Theme.code))
                    .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: Theme.chatMaxWidth)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .environment(\.openURL, OpenURLAction { openLink($0) })
        .overlay { if timeline == nil && host.providerSubagentTimelineErrors[key] == nil { ProgressView() } }
    }

    /// Where it came from and what it spawned; there is no composer, a subagent only answers its parent.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                model.open(AgentRef(serverId: host.id, agentId: parentAgentId))
            } label: {
                Label("「\(parent?.displayTitle ?? String(parentAgentId.prefix(7)))」的子代理", systemImage: "arrow.turn.left.up")
                    .lineLimit(1)
            }
            .help("返回父会话")
            if !children.isEmpty {
                Menu {
                    ForEach(children) { sub in
                        Button {
                            model.openProviderSubagent(serverId: host.id, parentAgentId: parentAgentId, subagentId: sub.id)
                        } label: {
                            Label(sub.label, systemImage: sub.isFinished ? (sub.status == "failed" ? "xmark.circle" : "checkmark.circle") : "circle.dotted")
                        }
                    }
                } label: {
                    Label("它派出的子代理 · \(children.count)", systemImage: "person.2")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .compatibleGlassEffect(in: Capsule())
        .padding(.vertical, 10)
    }

    private func makeEnvironment() -> TimelineEnvironment {
        let host = host
        let cwd = parent?.cwd ?? workspace?.directory ?? "/"
        let reader = HostFileReader { raw in
            let path = (raw.hasPrefix("/") ? raw : cwd + "/" + raw)
            let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            return try? await host.readFile(cwd: dir, path: name, maxBytes: 20 * 1024 * 1024).data
        }
        let titles = AgentTitleLookup { id in host.agents[id]?.displayTitle ?? host.agents.first { $0.key.hasPrefix(id) }?.value.displayTitle }
        return TimelineEnvironment(actions: TimelineActions(), fileReader: reader, agentTitle: titles)
    }

    /// `paseo-file:` links open the file in a tab of this workspace; relative paths are relative to the parent's cwd.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        guard let (path, line) = FileLink.parse(url) else { return .systemAction }
        guard let workspace else { return .discarded }
        var abs = path
        if abs.hasPrefix("~/"), let home = host.homeDirectory { abs = home + abs.dropFirst(1) }
        if !abs.hasPrefix("/") { abs = (parent?.cwd ?? workspace.directory) + "/" + abs }
        abs = (abs as NSString).standardizingPath
        model.openFile(abs, line: line, in: WorkspaceRef(serverId: host.id, workspaceId: workspace.id))
        return .handled
    }
}
