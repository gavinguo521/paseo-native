// Agent tab: timeline, inline permission cards at the live head, composer.
// Official: panels/agent-panel.tsx, agent-stream/view.tsx.

import PaseoKit
import SwiftUI

struct AgentView: View {
    let host: HostStore
    let agentId: String
    let workspace: Workspace?
    @AppStorage("timelineDetail") private var timelineDetail = TimelineDetail.collapseTurns.rawValue
    @AppStorage("autoExpandReasoning") private var autoExpandReasoning = true
    private var collapseTurns: Bool { timelineDetail == TimelineDetail.collapseTurns.rawValue }
    @State private var atBottom = true
    /// 内容不满一屏（新会话、短会话）：关掉顶部软边缘，见 compatibleScrollEdgeEffects
    @State private var contentFits = false
    @State private var finding = false
    @State private var findQuery = ""
    @State private var matchIndex = 0
    @State private var showOutline = false
    @State private var loadingAll = false
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var displayCache = DisplayItemCache()
    /// One older page at a time.
    @State private var loadingOlder = false

    @Environment(AppModel.self) private var model
    @State private var actionError: String?

    private var agent: Agent? { host.agents[agentId] }
    private var timeline: AgentTimeline? { host.timelines[agentId] }

    private var pluginContext: PluginRowContext { PluginRowContext(host: host, agentId: agentId) }

    private var lastUserMessageId: String? {
        timeline?.rows.last { if case .userMessage = $0.item { true } else { false } }?.id
    }

    // MARK: Find & outline

    /// Messages whose text contains the query (user and assistant rows).
    private var matches: [String] {
        let q = findQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return (timeline?.rows ?? []).compactMap { r in
            switch r.item {
            case .userMessage(let t, _), .assistantMessage(let t, _): t.lowercased().contains(q) ? r.id : nil
            default: nil
            }
        }
    }

    private var currentMatch: String? {
        guard finding, !matches.isEmpty else { return nil }
        return matches[min(matchIndex, matches.count - 1)]
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("在会话中查找", text: $findQuery).textFieldStyle(.plain).frame(width: 220)
                .onSubmit { step(1) }
            if loadingAll { ProgressView().controlSize(.mini) }
            Text(matches.isEmpty ? (findQuery.isEmpty ? "" : "无结果") : "\(min(matchIndex, matches.count - 1) + 1)/\(matches.count)")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(matches.isEmpty)
                .accessibilityLabel("上一个结果")
            Button { step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(matches.isEmpty)
                .accessibilityLabel("下一个结果")
            Button { finding = false; findQuery = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .accessibilityLabel("关闭查找")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).frame(height: 36)
        .compatibleGlassEffect(in: Capsule())
        .padding(.top, 8)
        .onChange(of: findQuery) { matchIndex = max(matches.count - 1, 0); jump() }
        .onKeyPress(.escape) { finding = false; return .handled }
    }

    private func step(_ d: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (min(matchIndex, matches.count - 1) + d + matches.count) % matches.count
        jump()
    }

    private func jump() {
        guard let id = currentMatch else { return }
        withAnimation { scrollPosition.scrollTo(id: id, anchor: .center) }
    }

    private var prompts: [TimelineRow] {
        (timeline?.rows ?? []).filter { if case .userMessage = $0.item { true } else { false } }
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("提问大纲").font(.system(size: 13, weight: .semibold))
                Spacer()
                if loadingAll { ProgressView().controlSize(.mini) }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(prompts) { r in
                        Button {
                            showOutline = false
                            Task { try? await Task.sleep(for: .milliseconds(100)); withAnimation { scrollPosition.scrollTo(id: r.id, anchor: .top) } }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if case .userMessage(let t, _) = r.item { Text(t).lineLimit(2).font(.system(size: 13)) }
                                if let ts = r.timestamp { Text(formatTimestamp(ts)).font(.system(size: 11)).foregroundStyle(Theme.extraMuted) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        #if os(iOS)
        .frame(width: 340, height: 460)
        #else
        .frame(width: 380, height: 460)
        #endif
    }

    /// Find and the outline work on the whole history.
    private func ensureFullHistory() {
        guard timeline?.hasOlder == true, !loadingAll else { return }
        loadingAll = true
        Task { await host.loadFullTimeline(agentId); loadingAll = false }
    }

    /// Built once per session view so the environment values below keep their identity.
    @State private var env: TimelineEnvironment?
    @State private var showConnecting = false
    /// 会话还活着、所在工作区却已被归档（官方客户端和其他设备上看不到它）时，记下可恢复的工作区 id。
    @State private var recoverableWorkspace: String?
    @State private var restoringWorkspace = false
    @State private var linkClicks = 0

    private func makeEnvironment() -> TimelineEnvironment {
        let host = host, agentId = agentId, model = model
        let errorSink = { (e: String) in NotificationCenter.default.post(name: .timelineActionError, object: (agentId, e)) }
        let actions = TimelineActions(rewindModes: { host.agents[agentId]?.rewindModes ?? [] }, rewind: { messageId, mode in
            let text = host.timelines[agentId]?.rows.first { $0.id == messageId }.flatMap { if case .userMessage(let t, _) = $0.item { t } else { nil } }
            Task {
                do {
                    try await host.rewind(agentId, messageId: messageId, mode: mode)
                    if mode != "files", let text { NotificationCenter.default.post(name: .restoreComposer, object: text) }
                } catch { errorSink("\(error)") }
            }
        }, fork: { messageId, newWorkspace in
            Task {
                do {
                    let attachment = try await host.forkContext(agentId, boundaryMessageId: messageId)
                    model.startFork(from: AgentRef(serverId: host.id, agentId: agentId), attachment: attachment, newWorkspace: newWorkspace)
                } catch { errorSink(String(localized: "分叉失败：\(error)")) }
            }
        })
        let cwd = agent?.cwd ?? workspace?.directory ?? "/"
        let reader = HostFileReader { raw in
            let path = (raw.hasPrefix("/") ? raw : cwd + "/" + raw)
            let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            return try? await host.readFile(cwd: dir, path: name, maxBytes: 20 * 1024 * 1024).data
        }
        let titles = AgentTitleLookup { id in host.agents[id]?.displayTitle ?? host.agents.first { $0.key.hasPrefix(id) }?.value.displayTitle }
        return TimelineEnvironment(actions: actions, fileReader: reader, agentTitle: titles)
    }

    /// `paseo-file:` links open the file in a tab of this workspace; relative paths are relative to the agent's cwd.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        if let name = CommandLink.name(url) {
            // A command this session knows goes into the draft (not sent); otherwise a `/name` link keeps its path meaning.
            Task {
                let known = await host.listCommands(agentId).contains { $0.name == name || $0.name == "/" + name }
                if known { NotificationCenter.default.post(name: .appendToComposer, object: "/" + name) }
                else if url.scheme == FileLink.scheme { _ = openFileLink(url) }
            }
            return .handled
        }
        return openFileLink(url)
    }

    private func openFileLink(_ url: URL) -> OpenURLAction.Result {
        guard let (path, line) = FileLink.parse(url) else { return .systemAction }
        guard let workspace else { return .discarded }
        let ref = WorkspaceRef(serverId: host.id, workspaceId: workspace.id)
        var abs = path
        if abs.hasPrefix("~/"), let home = host.homeDirectory { abs = home + abs.dropFirst(1) }
        let relative = !abs.hasPrefix("/")
        let base = agent?.cwd ?? workspace.directory
        if relative { abs = base + "/" + abs }
        abs = (abs as NSString).standardizingPath
        guard relative else { model.openFile(abs, line: line, in: ref); return .handled }
        // A relative path missing at the root may live in a nested repo (`schema/x.md` → `repo-a/schema/x.md`):
        // the exact path wins, then a search hit ending with it; otherwise the original (and its not-found message).
        linkClicks += 1
        let click = linkClicks, target = abs
        Task {
            var resolved = target
            if await !host.fileExists(target) {
                let name = (path as NSString).lastPathComponent
                let hits = await host.pathSuggestions(cwd: base, query: name)
                if let hit = hits.first(where: { !$0.isDirectory && ($0.path == path || $0.path.hasSuffix("/" + path)) }) {
                    resolved = hit.path.hasPrefix("/") ? hit.path : (base + "/" + hit.path as NSString).standardizingPath
                }
            }
            // A later click wins over a lookup that finishes late.
            if click == linkClicks { model.openFile(resolved, line: line, in: ref) }
        }
        return .handled
    }

    /// Reconnecting / offline notice above the composer: a small glass capsule over the chat column.
    /// "Connecting" waits a moment first, so a normal launch (connected within a second or two) never flashes it.
    @ViewBuilder private var connectionBanner: some View {
        Group {
            switch host.state {
            case .connected, .idle: EmptyView()
            case .connecting:
                if showConnecting { notice { ProgressView().controlSize(.mini); Text("正在连接 \(host.label)…") } }
            case .waiting(let message, let retryAt):
                notice {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.dotWarning)
                    // 整句翻译（中英文语序不同）：倒计时作为插值嵌进同一句
                    Text("与 \(host.label) 的连接断开，\(Text(retryAt, style: .relative))后重试")
                    Button("立即重连") { host.reconnectNow() }.buttonStyle(.borderless).controlSize(.small)
                }
                .help(message)
            case .failed(let message, _):
                notice {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.dotWarning)
                    Text("无法连接 \(host.label)：\(message)").lineLimit(2)
                }
            }
        }
        .task(id: isConnecting) {
            showConnecting = false
            guard isConnecting else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { showConnecting = true }
        }
    }

    private var isConnecting: Bool { if case .connecting = host.state { true } else { false } }

    /// 工作区被归档但会话还在跑（比如归档时会话正在回复，又被 daemon 唤醒）：官方客户端按工作区列会话，会看不到它。
    @ViewBuilder private var archivedWorkspaceBanner: some View {
        Group {
            if let ws = recoverableWorkspace {
                notice {
                    Image(systemName: "archivebox").foregroundStyle(Theme.dotWarning)
                    Text("这个会话所在的工作区已被归档，官方客户端和其他设备上看不到它").lineLimit(2)
                    Button("恢复工作区") {
                        restoringWorkspace = true
                        Task {
                            if (try? await host.restoreWorkspace(ws)) != nil { recoverableWorkspace = nil }   // 失败就留着提示条，可以再点
                            restoringWorkspace = false
                        }
                    }
                    .buttonStyle(.borderless).controlSize(.small).disabled(restoringWorkspace)
                }
            }
        }
        // 本地只加载了最近的非后台工作区，找不到不代表已归档：找不到时再问 daemon 这个工作区能不能恢复
        .task(id: "\(agent?.workspaceId ?? "")|\(host.workspaces.count)|\(agent?.archivedAt == nil)|\(host.state == .connected)") {
            recoverableWorkspace = nil
            guard host.state == .connected, let a = agent, a.archivedAt == nil, a.parentAgentId == nil,
                  let ws = a.workspaceId, host.workspaces[ws] == nil, !host.workspaces.isEmpty else { return }
            guard let state = try? await host.inspectWorkspaceRecovery(ws), state["kind"]?.stringValue == "recoverable" else { return }
            if host.workspaces[ws] == nil { recoverableWorkspace = ws }
        }
    }

    private func notice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .compatibleGlassEffect(in: Capsule())
            .frame(maxWidth: Theme.chatMaxWidth)
            .padding(.horizontal, 16).padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }

    private func parentBanner(_ parentId: String) -> some View {
        // 跨机器开的子会话：父会话在 label `paseo.parent-server-id` 指的那台主机上。
        let parentHost = agent?.parentServerId.flatMap { model.host($0) } ?? host
        let parent = parentHost.agents[parentId]
        return HStack(spacing: 8) {
            Image(systemName: "arrow.turn.left.up").foregroundStyle(Theme.muted)
            Text("「\(parent?.displayTitle ?? String(parentId.prefix(7)))」的子会话").foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            if parent != nil {
                Button("返回父会话") { model.open(AgentRef(serverId: parentHost.id, agentId: parentId)) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Plain VStack, not LazyVStack: lazy height estimates made the bottom anchor scroll past the end now and
                // then after switching sessions (blank page until touched, seen on an iPhone; docs/STATUS.md).
                VStack(alignment: .leading, spacing: 14) {
                    // The scroll target layout must start at (0, 0) and span the full width: SwiftUI resolves scroll
                    // targets from its left / bottom edge, so an outer padding of 16 showed up as a sideways offset of 16
                    // (column hugging the left edge) and a bottom 16 short. The reading column is applied per row instead,
                    // and these 2pt spacers plus the 14pt row spacing give the 16pt top and bottom margins.
                    Color.clear.frame(height: 2)
                    Group {
                    if let parentId = agent?.parentAgentId { parentBanner(parentId) }
                    if let e = host.timelineErrors[agentId] {
                        HStack {
                            Banner(level: "error", message: e)
                            Button("重试") { host.retryTimeline(agentId) }.buttonStyle(.bordered)
                        }
                    }
                    if timeline?.isLoaded == true, timeline?.rows.isEmpty == true, agent?.status != .running {
                        ContentUnavailableView("还没有消息", systemImage: "bubble.left", description: Text("在下面输入要做的事"))
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    if timeline?.hasOlder == true {
                        // Loading starts when this comes near the viewport (onScrollGeometryChange below), not onAppear:
                        // the timeline is a plain VStack, so every row appears at once and onAppear would load all history.
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(displayCache.items(timeline, lastTurnActive: agent?.status == .running,
                                               collapse: collapseTurns && !finding && !showOutline,
                                               separateReasoning: autoExpandReasoning)) { item in
                        TimelineItemView(item: item)
                            .modifier(LayoutProbe(label: "item " + item.id))
                            .padding(4)
                            .background(item.id == currentMatch ? Theme.dotWarning.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .environment(\.sentImages, host.sentImages)
                    .environment(\.timelineActions, env?.actions ?? TimelineActions())
                    .environment(\.hostFileReader, env?.fileReader)
                    .environment(\.findQuery, finding ? findQuery : "")
                    .environment(\.agentTitle, env?.agentTitle)
                    .environment(\.pluginContext, pluginContext)
                    if let agent {
                        ForEach(agent.pendingPermissions) { PermissionCard(host: host, agentId: agentId, request: $0) }
                        TurnFooter(agent: agent)
                    }
                    }
                    .modifier(ReadingColumn())
                    Color.clear.frame(height: 2)
                }
                .scrollTargetLayout()
                .modifier(LayoutProbe(label: "column"))
            }
            .scrollPosition($scrollPosition)
            // Newer systems soften the top edge and hide the bottom effect; iOS 18 uses standard edges.
            .compatibleScrollEdgeEffects(topHidden: contentFits)
            .environment(\.openURL, OpenURLAction { url in openLink(url) })
            .overlay(alignment: .top) { if finding { findBar } }
            .popover(isPresented: $showOutline, arrowEdge: .top) { outline.compactPopover() }
            .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("好") {}
            } message: { Text(actionError ?? "") }
            .defaultScrollAnchor(.bottom)
            // Stay pinned to the bottom while a reply grows, unless the user scrolled up to read.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // Sending a message always jumps to it.
            .onChange(of: lastUserMessageId) { old, new in
                guard old != nil, new != nil else { return }
                withAnimation(.snappy(duration: 0.25)) { scrollPosition.scrollTo(edge: .bottom) }
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height - g.contentOffset.y - g.containerSize.height < 32
            } action: { _, bottom in atBottom = bottom }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height <= g.containerSize.height + 1
            } action: { _, fits in contentFits = fits }
            // Older history: one page when the reader scrolls within 400pt of the top of a timeline taller than the screen.
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height > g.containerSize.height && g.contentOffset.y + g.contentInsets.top < 400
            } action: { _, nearTop in
                guard nearTop, timeline?.hasOlder == true, !loadingOlder else { return }
                loadingOlder = true
                Task { await host.loadOlder(agentId); loadingOlder = false }
            }
            // PASEO_LAYOUT_DEBUG=1 (launch environment, also in Release so it can run on a device): log the scroll geometry.
            .onScrollGeometryChange(for: String.self) { g in
                "scroll container \(Int(g.containerSize.width))x\(Int(g.containerSize.height)) content \(Int(g.contentSize.width))x\(Int(g.contentSize.height)) offset \(Int(g.contentOffset.x)),\(Int(g.contentOffset.y))"
            } action: { _, s in if LayoutProbe.on { print("[layout] \(agentId.prefix(7)) " + s) } }
            .overlay {
                if host.timelineLoading.contains(agentId) && (timeline?.rows.isEmpty ?? true) { ProgressView() }
            }
            // The composer floats over the timeline (inset, not a row below it): the chips row above the input box
            // (用这句, +N −M, 子代理) is transparent, and text scrolls on behind it instead of being cut off above it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    connectionBanner
                    archivedWorkspaceBanner
                    if agent?.archivedAt != nil {
                        HStack(spacing: 12) {
                            Text("这个会话已归档").foregroundStyle(Theme.muted)
                            Button("取消归档") { Task { try? await host.unarchive(agentId) } }.buttonStyle(.bordered)
                        }
                        .padding()
                    } else {
                        ComposerView(host: host, agentId: agentId, workspace: workspace)
                    }
                }
                // 「Scroll to bottom」 is a chip at the right end of the composer's chips row (was a round button at
                // the window's far right edge).
                .environment(\.scrollToBottom, atBottom ? nil : {
                    withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                })
            }
        }
        .onAppear {
            if env == nil { env = makeEnvironment() }
            host.openTimeline(agentId)
            host.clearAttention(agentId)
            #if DEBUG && os(iOS)
            ScrollBench.startIfRequested { [host, agentId] in await host.loadFullTimeline(agentId) }
            #endif
        }
        .onDisappear { host.closeTimeline(agentId) }
        // The session being watched finished or failed.
        .phoneFeedback(trigger: agent?.status) { old, new in
            guard old == .running else { return nil }
            return new == .error ? .error : new == .idle ? .success : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInSession)) { _ in finding = true; ensureFullHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .showOutline)) { _ in showOutline = true; ensureFullHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .timelineActionError)) { n in
            if let (id, message) = n.object as? (String, String), id == agentId { actionError = message }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToMessage)) { n in
            guard let id = n.object as? String, timeline?.rows.contains(where: { $0.id == id }) == true else { return }
            withAnimation { scrollPosition.scrollTo(id: id, anchor: .top) }
        }
        .onChange(of: agent?.requiresAttention) { _, needs in if needs == true { host.clearAttention(agentId) } }
    }
}

struct TimelineEnvironment {
    let actions: TimelineActions
    let fileReader: HostFileReader
    let agentTitle: AgentTitleLookup
}

/// While running: elapsed time. Official: agent-stream/turn-footer.tsx.
private struct TurnFooter: View {
    let agent: Agent

    var body: some View {
        if agent.status == .running, let start = agent.activeTurnStartedAt {
            // Same spinner, gap and inset as the activity rows above, so the two line up.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 18, height: 18)
                Text(timerInterval: start...Date.distantFuture, countsDown: false).monospacedDigit()
            }
            .font(.system(size: Theme.code))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 4)
        } else if agent.status == .error, let e = agent.lastError {
            Banner(level: "error", message: e)
        }
    }
}

// MARK: Permission card

struct PermissionCard: View {
    let host: HostStore
    let agentId: String
    let request: PermissionRequest
    @State private var busy = false
    @State private var answers: [String: String] = [:]
    @State private var error: String?
    /// Questions are asked one at a time (official question form: 下一步 / 提交).
    @State private var step = 0
    @State private var answered = 0

    private var questionList: [JSONValue] { request.input?["questions"]?.arrayValue ?? [] }
    private var stepping: Bool { request.kind == "question" && questionList.count > 1 }
    private var onLastStep: Bool { !stepping || step >= questionList.count - 1 }

    var body: some View {
        if request.kind == "question" { questionForm } else { permissionBody }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.kind == "plan" ? String(localized: "计划") : request.title ?? String(localized: "需要权限"))
                .font(.system(size: Theme.base, weight: .medium))
            if let d = request.description, d != request.title {
                Text(d).font(.system(size: Theme.base)).foregroundStyle(Theme.muted)
            }
            if request.kind == "plan", let plan = request.planText {
                ScrollView { MarkdownView(text: plan) }.frame(maxHeight: 320)
            } else if let detail = request.detail {
                detailPreview(detail)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
            HStack(spacing: 8) {
                Spacer()
                ForEach(buttons, id: \.id) { action in
                    Button {
                        respond(action)
                    } label: {
                        Label(action.label, systemImage: action.behavior == "deny" ? "xmark" : "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(action.behavior == "deny" ? nil : Theme.accent)
                    .if(action.behavior != "deny" && action.variant != "secondary") { $0.buttonStyle(.borderedProminent) }
                    .disabled(busy)
                }
            }
        }
        .padding(14)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.dotWarning.opacity(0.5)))
        .phoneFeedback(.success, trigger: answered)
    }

    private var buttons: [PermissionAction] {
        if !request.actions.isEmpty { return request.actions }
        if request.kind == "question" {
            return [PermissionAction(id: "reject", label: String(localized: "跳过"), behavior: "deny", variant: "secondary"),
                    PermissionAction(id: "accept", label: String(localized: "提交"), behavior: "allow", variant: "primary")]
        }
        return [PermissionAction(id: "reject", label: String(localized: "拒绝"), behavior: "deny", variant: "secondary"),
                PermissionAction(id: "accept", label: request.kind == "plan" ? String(localized: "执行") : String(localized: "允许"), behavior: "allow", variant: "primary")]
    }

    @ViewBuilder private func detailPreview(_ d: ToolCallDetail) -> some View {
        switch d {
        case .shell(let command, _, _, _): CodeBlock(code: "$ " + command)
        case .edit(_, let old, let new, let unified): DiffView(diff: unified ?? DiffView.fallback(old: old ?? "", new: new ?? ""), maxHeight: 200)
        case .write(let path, let content): CodeBlock(code: path + "\n\n" + String((content ?? "").prefix(1500)))
        default: if let input = request.input { CodeBlock(code: String(input.description.prefix(1500))) }
        }
    }

    // MARK: Question form (official components/question-form-card.tsx)

    /// `kind == "question"`: `input.questions[{question, header, multiSelect, options[{label, description}]}]`.
    /// Layout like the official card: question tabs (when several), the question, option rows, an answer field,
    /// then 跳过 and 下一题 / 提交 — no repeated title or option summary above it.
    private var questionForm: some View {
        let qs = questionList
        let index = min(step, max(qs.count - 1, 0))
        return VStack(alignment: .leading, spacing: 12) {
            if stepping { questionTabs(qs, index: index) }
            if qs.indices.contains(index) { questionBlock(qs[index]) }
            if let error { Text(error).font(.system(size: Theme.base - 2)).foregroundStyle(Theme.destructive) }
            questionActions
        }
        .padding(14)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.dotWarning.opacity(0.5)))
        .phoneFeedback(.success, trigger: answered)
    }

    private func header(_ q: JSONValue) -> String { q["header"]?.stringValue ?? q["question"]?.stringValue ?? "" }

    /// One row of question tabs; scrolls sideways only when they do not fit.
    private func questionTabs(_ qs: [JSONValue], index: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            questionTabRow(qs, index: index)
            ScrollView(.horizontal, showsIndicators: false) { questionTabRow(qs, index: index) }
        }
    }

    private func questionTabRow(_ qs: [JSONValue], index: Int) -> some View {
            HStack(spacing: 6) {
                ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                    let done = !(answers[header(q)] ?? "").isEmpty
                    Button { step = i } label: {
                        HStack(spacing: 4) {
                            if done { Image(systemName: "checkmark").font(.system(size: Theme.base - 4, weight: .semibold)) }
                            Text(header(q)).lineLimit(1)
                        }
                        .font(.system(size: Theme.base - 1, weight: i == index ? .medium : .regular))
                        .foregroundStyle(i == index ? Theme.foreground : Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(i == index ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    @ViewBuilder private func questionBlock(_ q: JSONValue) -> some View {
        let key = header(q)
        let multi = q["multiSelect"]?.boolValue == true
        VStack(alignment: .leading, spacing: 8) {
            Text(q["question"]?.stringValue ?? key)
                .font(.system(size: Theme.base, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array((q["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, o in
                    optionRow(o, key: key, multi: multi)
                }
            }
            TextField("其他回答", text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.base))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface0, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }

    private func optionRow(_ o: JSONValue, key: String, multi: Bool) -> some View {
        let label = o["label"]?.stringValue ?? ""
        // Shown in Chinese with a tag; the answer still sends the option's own label.
        let recommended = label.hasSuffix("(Recommended)")
        let shown = recommended ? String(label.dropLast("(Recommended)".count)).trimmingCharacters(in: .whitespaces) : label
        let picked = answers[key]?.components(separatedBy: ", ").contains(label) == true
        return Button {
            if multi {
                var set = Set(answers[key]?.components(separatedBy: ", ").filter { !$0.isEmpty } ?? [])
                if picked { set.remove(label) } else { set.insert(label) }
                answers[key] = set.sorted().joined(separator: ", ")
            } else {
                answers[key] = label
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: multi ? (picked ? "checkmark.square.fill" : "square") : (picked ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: Theme.base + 1))
                    .foregroundStyle(picked ? Theme.accent : Theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(shown).font(.system(size: Theme.base)).foregroundStyle(Theme.foreground)
                        if recommended {
                            Text("推荐").font(.system(size: Theme.base - 4, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if let d = o["description"]?.stringValue, !d.isEmpty {
                        Text(d).font(.system(size: Theme.base - 2)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(picked ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 跳过 and 下一题 / 提交, equal width so neither wraps on a phone (official: dismiss + primary).
    private var questionActions: some View {
        let skip = buttons.first { $0.behavior == "deny" }
        let submit = buttons.first { $0.behavior != "deny" }
        return HStack(spacing: 10) {
            if let skip {
                Button { respond(skip) } label: {
                    Label(skip.label, systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuestionButtonStyle(primary: false))
            }
            if !onLastStep {
                Button { step += 1 } label: { Text("下一题").frame(maxWidth: .infinity) }
                    .buttonStyle(QuestionButtonStyle(primary: true))
            } else if let submit {
                Button { respond(submit) } label: {
                    Label(submit.label, systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuestionButtonStyle(primary: true))
            }
        }
        .disabled(busy)
    }

    private func respond(_ action: PermissionAction) {
        busy = true
        var response: [String: JSONValue] = ["behavior": .string(action.behavior)]
        if !request.actions.isEmpty { response["selectedActionId"] = .string(action.id) }
        if action.behavior == "deny" {
            response["message"] = request.kind == "question" ? "Dismissed by user" : "Denied by user"
        } else if request.kind == "question", var input = request.input?.objectValue {
            input["answers"] = .object(answers.mapValues { .string($0) })
            response["updatedInput"] = .object(input)
        }
        Task {
            do {
                try await host.respond(to: request, agentId: agentId, response: response)
                answered += 1
            } catch { self.error = "\(error)" }
            busy = false
        }
    }
}

/// PASEO_LAYOUT_DEBUG=1: prints the width of the reading column and of every timeline item as it changes,
/// to find what widens the timeline on iPhone.
struct LayoutProbe: ViewModifier {
    static let on = ProcessInfo.processInfo.environment["PASEO_LAYOUT_DEBUG"] == "1"
    let label: String

    func body(content: Content) -> some View {
        if Self.on {
            content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                print("[layout] \(label) width \(Int(w))")
            }
        } else {
            content
        }
    }
}


/// The centred reading column, applied to each timeline row (not around the lazy stack; see AgentView.body).
struct ReadingColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Theme.chatMaxWidth, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
    }
}

/// Question form buttons: one size, one line, filled accent for the primary action.
struct QuestionButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.base, weight: .medium))
            .lineLimit(1)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .foregroundStyle(primary ? Color.white : Theme.foreground)
            .background(primary ? Theme.accent : Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? .clear : Theme.border))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}
