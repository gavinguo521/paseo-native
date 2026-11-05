// Composer in the PaseoPro style: a glass capsule with "+" and send, and small glass chips above it
// (workspace diff, subagents, model, thinking, mode). Enter sends on Mac (Shift+Enter newline).
// While running, sending follows the "sendBehavior" preference: steer (default), interrupt, or queue.

import PaseoKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// True while an input method (pinyin, voice input…) still holds uncommitted text in the focused field.
/// Keys must then go to the input method: Return commits the text, Esc cancels it (official checks isComposing).
@MainActor func inputMethodComposing() -> Bool {
    #if os(macOS)
    return (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    #else
    return (FirstResponder.current as? UITextInput)?.markedTextRange != nil
    #endif
}

#if os(iOS)
/// Finds the first responder by sending it an action (UIKit has no public getter).
@MainActor private enum FirstResponder {
    private static weak var found: UIResponder?
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.paseoCaptureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
    static func capture(_ r: UIResponder) { found = r }
}

extension UIResponder {
    @objc func paseoCaptureFirstResponder() { MainActor.assumeIsolated { FirstResponder.capture(self) } }
}
#endif

enum SendBehavior: String, CaseIterable {
    case steer, interrupt, queue

    var label: String {
        switch self {
        case .steer: "插话（引导当前回合）"
        case .interrupt: "打断并重新开始"
        case .queue: "排队，等这一轮结束再发"
        }
    }

    /// Official option names (settings.general.defaultSend.options).
    var shortLabel: String {
        switch self {
        case .interrupt: "中断"
        case .steer: "引导"
        case .queue: "排队"
        }
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let host: HostStore
    let agentId: String
    let workspace: Workspace?
    @AppStorage("sendBehavior") private var sendBehavior = SendBehavior.steer.rawValue
    @State private var text = ""
    @State private var images: [ImageAttachment] = []
    @State private var sending = false
    @State private var sentCount = 0
    @State private var error: String?
    @State private var showSubagents = false
    @State private var showBackgroundTasks = false
    @State private var uploads: [UploadItem] = []
    @State private var autocomplete = AutocompleteModel()
    @State private var suggestion: NextInputSuggestion?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone width: subagents move up to the chip row and the context ring drops its text.
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif
    @FocusState private var focused: Bool

    private var agent: Agent? { host.agents[agentId] }
    private var running: Bool { agent?.status == .running }
    private var behavior: SendBehavior { SendBehavior(rawValue: sendBehavior) ?? .steer }
    private var queued: [QueuedMessage] { model.queue[agentId] ?? [] }
    private var subagents: [Agent] {
        host.agents.values.filter { $0.parentAgentId == agentId && $0.archivedAt == nil }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
    /// 全部后代会话（子会话、子会话的子会话……），深度优先，depth 0 = 直接子会话；弹层按它缩进成树，
    /// 不然孙会话只能先点进子会话才看得到。
    private var descendants: [(agent: Agent, depth: Int)] {
        let live = host.agents.values.filter { $0.archivedAt == nil && $0.parentAgentId != nil
            && ($0.parentServerId == nil || $0.parentServerId == host.id) }
        let children = Dictionary(grouping: live) { $0.parentAgentId! }
        var out: [(agent: Agent, depth: Int)] = []
        var seen: Set<String> = [agentId]
        func walk(_ id: String, _ depth: Int) {
            for c in (children[id] ?? []).sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) })
            where seen.insert(c.id).inserted {
                out.append((c, depth))
                walk(c.id, depth + 1)
            }
        }
        walk(agentId, 0)
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            if !queued.isEmpty { queueTrack }
            NextInputSource(host: host, agentId: agentId, suggestion: $suggestion)
            ComposerShell(text: $text, images: $images, focused: $focused, error: error, placeholder: placeholder,
                          autocomplete: autocomplete, onPick: pick, uploads: $uploads,
                          onFiles: { uploadFiles($0, to: host, into: $uploads) },
                          onAlternateSubmit: { send(alternate: true) }, onRecall: recall, onCycleMode: cycleMode,
                          onTabEmpty: { if let s = suggestion { text = s.text; return true }; return false },
                          searchForge: workspace?.isGit == true ? { [host, dir = workspace!.directory] q in try await host.forgeSearch(cwd: dir, query: q) } : nil) {
                chips
            } controls: {
                ComposerControls(summary: composerSummary(host, agent?.provider ?? "", agent?.model,
                                                          agent?.thinkingOptionId ?? agent?.effectiveThinkingOptionId)) { controls }
            } trailing: {
                if !compact { subagentPill }
                if let usage = agent?.lastUsage { ContextRing(usage: usage, quota: (host, agentId, agent?.model), compact: compact) }
                if hasContent {
                    RoundButton(systemImage: "arrow.up", busy: sending, help: running ? behavior.label : "发送") { send() }
                } else if let s = suggestion, !running, !s.needsEditing {
                    // One tap sends the suggested next message; accent and a paper plane so it never reads as "send nothing".
                    RoundButton(systemImage: "paperplane.fill", busy: sending, help: "发送建议：" + s.text, fill: Theme.accent) { sendSuggestion(s) }
                } else if running {
                    RoundButton(systemImage: "stop.fill", busy: false, help: "中断（Esc）") { Task { try? await host.cancel(agentId) } }
                }
            } onSubmit: { send() }
        }
        .phoneFeedback(.impact(weight: .light), trigger: sentCount)
        .onKeyPress(.escape) {
            guard running, !inputMethodComposing() else { return .ignored }
            Task { try? await host.cancel(agentId) }
            return .handled
        }
        .onAppear {
            #if os(macOS)
            // Only on the Mac: on iPhone and iPad focusing would throw the keyboard over half the screen.
            focused = true
            #endif
            if text.isEmpty, let draft = model.composerDrafts[agentId] { text = draft }
        }
        .onChange(of: text) { _, t in model.saveDraft(t, for: agentId) }
        #if DEBUG
        .task { if model.debugPane == "subagents" { try? await Task.sleep(for: .seconds(4)); showSubagents = true } }
        #endif
        .task(id: host.state == .connected) { await host.watchProviderSubagents(agentId) }
        .onChange(of: text) { _, t in autocomplete.update(text: t, host: host, agentId: agentId, cwd: agent?.cwd) }
        .onChange(of: agent?.status) { _, status in
            if status != .running { flushQueue() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .restoreComposer)) { n in
            if let t = n.object as? String { text = t; focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appendToComposer)) { n in
            guard let t = n.object as? String, model.currentWorkspace?.workspaceId == workspace?.id else { return }
            text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + t + " "
            focused = true
        }
    }

    /// The current turn's task list (official composer task pill).
    private var latestTodos: [TodoItem]? {
        for r in (host.timelines[agentId]?.rows ?? []).reversed() {
            if case .todo(let items) = r.item { return items }
            if case .userMessage = r.item { return nil }
        }
        return nil
    }

    private func sendSuggestion(_ s: NextInputSuggestion) {
        sending = true
        Task {
            do { try await NextInputSource.send(s, host: host, agentId: agentId); suggestion = nil }
            catch { self.error = "发送建议失败：\(error)" }
            sending = false
        }
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || uploads.contains { $0.done }
    }

    private var placeholder: String {
        #if os(macOS)
        if let s = suggestion { return s.text + "　（Tab 采用）" }
        #else
        if let s = suggestion { return s.text }
        #endif
        guard running else { return "发送消息" }
        switch behavior {
        case .steer: return "插话，引导当前回合"
        case .interrupt: return "发送会打断当前回合"
        case .queue: return "排队，这一轮结束后发送"
        }
    }

    @ViewBuilder private var chips: some View {
        #if os(iOS)
        // No Tab on a phone: the suggestion is taken only from this chip (tapping the box used to take it, even when
        // you meant to type something else). The paper-plane button still sends it as is.
        if text.isEmpty, let s = suggestion {
            Button { text = s.text } label: {
                Chip {
                    Image(systemName: "text.insert")
                    Text("用这句")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("把建议填进输入框：" + s.text)
        }
        #endif
        if let todos = latestTodos, !todos.isEmpty, todos.contains(where: { !$0.completed }) {
            Chip {
                Image(systemName: "checklist")
                Text("任务 \(todos.filter(\.completed).count)/\(todos.count)")
                if let current = todos.first(where: { $0.status == "in_progress" }) {
                    Text(current.text).lineLimit(1).frame(maxWidth: 260)
                }
            }
            .help(todos.map { ($0.completed ? "✓ " : "○ ") + $0.text }.joined(separator: "\n"))
        }
        backgroundTaskPill
        if let workspace, let add = workspace.additions, let del = workspace.deletions, add + del > 0 {
            Chip {
                Image(systemName: "pencil.line")
                Text("+\(add)").foregroundStyle(Theme.diffAdd)
                Text("−\(del)").foregroundStyle(Theme.diffRemove)
            }
        }
        if compact { subagentPill }
    }

    /// Subagents live beside the context ring in the bottom row: both are this session's current state.
    @ViewBuilder private var subagentPill: some View {
        let providerSubs = host.providerSubagents(of: agentId)
        let nested = descendants.map(\.agent)
        if !nested.isEmpty || !providerSubs.isEmpty {
            Button { showSubagents.toggle() } label: {
                Chip {
                    Image(systemName: "person.2")
                    // Narrow composer (iPad portrait, split view): just the count.
                    ViewThatFits(in: .horizontal) {
                        Text(subagentPillLabel(providerSubs)).fixedSize()
                        Text("\(nested.count + providerSubs.count)").fixedSize()
                    }
                    if providerSubs.contains(where: { !$0.isFinished }) || nested.contains(where: { $0.status == .running }) {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(subagentPillLabel(providerSubs))
            .popover(isPresented: $showSubagents, arrowEdge: .bottom) {
                // A real popover on iPhone too, not a full-height sheet with the list floating in it.
                subagentList.compactPopover()
            }
        }
    }

    /// Claude 在后台跑的命令（Bash 的 run_in_background）。daemon 不提供这个列表，由时间线推出来（`backgroundTasks`）。
    private var backgroundTasks: [AgentBackgroundTask] {
        let ended = agent.map { $0.status == .closed || $0.status == .error } ?? false
        return host.timelines[agentId]?.backgroundTasks(sessionEnded: ended) ?? []
    }

    /// 有后台命令在跑时显示；点开列出这个会话的后台命令（在跑的在前），点一条跳到时间线里那条命令。
    @ViewBuilder private var backgroundTaskPill: some View {
        let tasks = backgroundTasks
        let running = tasks.filter { $0.state == .running }.count
        if running > 0 {
            Button { showBackgroundTasks.toggle() } label: {
                Chip {
                    Image(systemName: "terminal")
                    ViewThatFits(in: .horizontal) {
                        Text("\(running) 个后台任务").fixedSize()
                        Text("\(running)").fixedSize()
                    }
                    ProgressView().controlSize(.mini)
                }
            }
            .buttonStyle(.plain)
            .help("\(running) 个后台任务运行中")
            .accessibilityLabel("\(running) 个后台任务运行中")
            .popover(isPresented: $showBackgroundTasks, arrowEdge: .bottom) {
                backgroundTaskList(tasks).compactPopover()
            }
        }
    }

    private func backgroundTaskList(_ tasks: [AgentBackgroundTask]) -> some View {
        let ordered = tasks.filter { $0.state == .running }.reversed() + tasks.filter { $0.state != .running }.reversed().prefix(10)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ordered) { task in
                    Button {
                        showBackgroundTasks = false
                        NotificationCenter.default.post(name: .scrollToMessage, object: task.rowId)
                    } label: {
                        BackgroundTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 420)
        #if os(iOS)
        .frame(width: 340)
        #else
        .frame(width: 400)
        #endif
    }

    /// Like the official pill: active states with counts, otherwise the total.
    private func subagentPillLabel(_ providerSubs: [ProviderSubagent]) -> String {
        let subagents = descendants.map(\.agent)
        let running = providerSubs.filter { !$0.isFinished }.count + subagents.filter { $0.status == .running }.count
        let failed = providerSubs.filter { $0.status == "failed" }.count + subagents.filter { $0.status == .error }.count
        let needsInput = subagents.filter { $0.bucket == .needsInput }.count
        let review = subagents.filter { $0.bucket == .attention }.count
        var parts: [String] = []
        if needsInput > 0 { parts.append("\(needsInput) 个需要输入") }
        if failed > 0 { parts.append("\(failed) 个失败") }
        if running > 0 { parts.append("\(running) 个运行中") }
        if review > 0 { parts.append("\(review) 个待查看") }
        return parts.isEmpty ? "\(subagents.count + providerSubs.count) 个子代理" : parts.joined(separator: " · ")
    }

    private var finishedSubagentCount: Int {
        host.providerSubagents(of: agentId).filter(\.isFinished).count
            + subagents.filter { $0.status == .idle || $0.status == .error }.count
    }

    /// Clears finished provider subagents from the pill and archives finished child sessions.
    private func archiveFinishedSubagents() {
        host.hideProviderSubagents(host.providerSubagents(of: agentId).filter(\.isFinished).map(\.id))
        let finished = subagents.filter { $0.status == .idle || $0.status == .error }.map(\.id)
        Task { for id in finished { try? await host.archive(id) } }
        showSubagents = false
    }

    /// Per-message settings, inside the input box like the official composer.
    @ViewBuilder private var controls: some View {
        if let agent {
            ModelMenu(host: host, provider: agent.provider, cwd: agent.cwd, selection: agent.model) { id in
                Task { try? await host.setModel(agentId, modelId: id) }
            }
            ThinkingMenu(host: host, provider: agent.provider, model: agent.model, selection: agent.thinkingOptionId ?? agent.effectiveThinkingOptionId) { id in
                Task { try? await host.setThinking(agentId, optionId: id) }
            }
            if !agent.availableModes.isEmpty {
                Menu {
                    ForEach(agent.availableModes) { mode in
                        Button { Task { try? await host.setMode(agentId, modeId: mode.id) } } label: {
                            if mode.id == agent.currentModeId { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                        }
                    }
                } label: {
                    ControlLabel(systemImage: "shield.lefthalf.filled", title: agent.currentMode?.label ?? "模式", rowTitle: "模式")
                }
                .controlMenuStyle()
            }
            ForEach(agent.composerFeatures) { f in FeatureChip(feature: f) { value in
                Task { try? await host.setFeature(agentId, featureId: f.id, value: value) }
            } }
            let profiles = host.agentProfiles.filter { $0["provider"]?.stringValue == agent.provider }
            if !profiles.isEmpty {
                Menu {
                    Section("套用配置") {
                        ForEach(profiles, id: \.self) { p in
                            Button(p["name"]?.stringValue ?? "配置") { apply(profile: p) }
                        }
                    }
                } label: { ControlLabel(systemImage: "person.crop.square", title: "配置", rowTitle: "套用配置", rowValue: false) }
                    .controlMenuStyle()
                    .help("套用 Agent 配置（模型、思考、模式、开关）")
            }
        }
    }

    private var subagentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if finishedSubagentCount > 0 {
                Button(action: archiveFinishedSubagents) {
                    Label("归档已完成的子代理", systemImage: "archivebox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(descendants, id: \.agent.id) { sub, depth in
                        HStack(spacing: 0) {
                            if depth > 0 {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    .padding(.leading, 14 + CGFloat(depth - 1) * 16).padding(.trailing, -8)
                            }
                            SubagentRowButton(label: sub.displayTitle, detail: sub.status == .running ? "运行中" : nil) {
                                StatusDot(bucket: sub.bucket)
                            } action: {
                                showSubagents = false
                                model.open(AgentRef(serverId: host.id, agentId: sub.id))
                            }
                            Menu {
                                Button("解除父子关系", systemImage: "link") { Task { try? await host.detach(sub.id) } }
                                Button("归档", systemImage: "archivebox", role: .destructive) { Task { try? await host.archive(sub.id) } }
                            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                .controlMenuStyle()
                                .accessibilityLabel("更多操作")
                                .padding(.trailing, 10)
                        }
                    }
                    ForEach(host.providerSubagents(of: agentId)) { sub in
                        SubagentRowButton(label: sub.label, detail: sub.detail) {
                            ProviderSubagentStatusIcon(status: sub.status)
                        } action: {
                            showSubagents = false
                            model.openProviderSubagent(serverId: host.id, parentAgentId: agentId, subagentId: sub.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
        }
        #if os(iOS)
        .frame(width: 340)
        #else
        .frame(width: 400)
        #endif
        .fixedSize(horizontal: false, vertical: true)
    }

    private var queueTrack: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(queued) { q in
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(Theme.muted)
                    Text(q.text).lineLimit(1)
                    if !q.images.isEmpty { Text("· \(q.images.count) 张图").foregroundStyle(Theme.muted) }
                    Spacer()
                    Button("编辑") { model.queue[agentId]?.removeAll { $0.id == q.id }; text = q.text; images = q.images; focused = true }
                    Button("现在发送") { model.queue[agentId]?.removeAll { $0.id == q.id }; dispatch(q.text, q.images, files: q.files, steer: true) }
                    Button { model.queue[agentId]?.removeAll { $0.id == q.id } } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("移出队列")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
            }
        }
        .frame(maxWidth: Theme.chatMaxWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func pick(_ s: Suggestion) {
        switch s.local {
        case "exit":
            text = ""
            autocomplete.dismiss()
            Task { try? await host.archive(agentId) }
            if let w = workspace { model.removeTab(.agent(agentId), in: WorkspaceRef(serverId: host.id, workspaceId: w.id)) }
            else { model.destination = nil }
        case "clear", "new":
            text = ""
            autocomplete.dismiss()
            if let a = agent {
                model.draftPreset = AppModel.DraftPreset(provider: a.provider, model: a.model, thinking: a.thinkingOptionId, modeId: a.currentModeId)
            }
            if s.local == "clear" { Task { try? await host.archive(agentId) } }
            if let w = workspace {
                let ws = WorkspaceRef(serverId: host.id, workspaceId: w.id)
                if s.local == "clear" { model.removeTab(.agent(agentId), in: ws, replacement: .draft(UUID().uuidString)) }
                else { model.select(.draft(UUID().uuidString), in: ws) }
            } else {
                model.destination = .newChat
            }
        default:
            autocomplete.apply(s, to: &text)
        }
    }

    /// Agent profile on a running agent: same-provider values applied one control at a time.
    private func apply(profile p: JSONValue) {
        Task {
            if let m = p["model"]?.stringValue { try? await host.setModel(agentId, modelId: m) }
            if let t = p["thinkingOptionId"]?.stringValue { try? await host.setThinking(agentId, optionId: t) }
            if let mode = p["modeId"]?.stringValue { try? await host.setMode(agentId, modeId: mode) }
            for (k, v) in p["featureValues"]?.objectValue ?? [:] { try? await host.setFeature(agentId, featureId: k, value: v) }
        }
    }

    /// Last thing the user sent here, for ↑ in an empty box.
    private func recall() {
        let rows = host.timelines[agentId]?.rows ?? []
        for r in rows.reversed() { if case .userMessage(let t, _) = r.item { text = t; return } }
    }

    private func cycleMode() {
        guard let agent, !agent.availableModes.isEmpty else { return }
        let modes = agent.availableModes
        let i = modes.firstIndex { $0.id == agent.currentModeId } ?? -1
        let next = modes[(i + 1) % modes.count]
        Task { try? await host.setMode(agentId, modeId: next.id) }
    }

    /// `alternate` (⌘Enter) flips queue ↔ send now while a turn is running.
    private func send(alternate: Bool = false) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasContent, !sending else { return }
        var behavior = self.behavior
        if alternate { behavior = behavior == .queue ? .steer : .queue }
        guard !uploads.contains(where: { !$0.done && $0.error == nil }) else { error = "文件还在上传"; return }
        let attached = images
        let files = uploads.compactMap(\.file).map(\.attachment)
        text = ""
        images = []
        uploads = []
        if running && behavior == .queue && (agent?.pendingPermissions.isEmpty ?? true) {
            model.queue[agentId, default: []].append(QueuedMessage(text: message, images: attached, files: files))
            return
        }
        dispatch(message, attached, files: files, steer: running && behavior == .steer)
    }

    private func dispatch(_ message: String, _ attached: [ImageAttachment], files: [JSONValue] = [], steer: Bool) {
        sending = true
        error = nil
        host.noteActivity()
        Task {
            do {
                try await host.send(message, to: agentId, steer: steer, images: attached, attachments: files)
                sentCount += 1
            } catch {
                self.error = "发送失败：\(error)"
                if text.isEmpty { text = message; images = attached }
            }
            sending = false
        }
    }

    /// Queued messages go out one per turn: the next one waits for the turn it starts to finish.
    private func flushQueue() {
        guard var list = model.queue[agentId], !list.isEmpty else { return }
        let next = list.removeFirst()
        model.queue[agentId] = list
        dispatch(next.text, next.images, files: next.files, steer: true)
    }
}

extension Agent {
    /// Provider features offered in the composer and command palette. Claude's 「Fast」 is left out (user's call:
    /// too easy to switch on by mistake); other providers keep theirs.
    var composerFeatures: [AgentFeature] {
        guard provider == "claude" else { return features }
        return features.filter { !$0.id.lowercased().contains("fast") && $0.label.lowercased() != "fast" }
    }
}

/// Provider feature (e.g. fast mode, plan mode): toggle chip or select menu.
struct FeatureChip: View {
    let feature: AgentFeature
    let onChange: (JSONValue) -> Void
    @Environment(\.controlsInSheet) private var inSheet

    var body: some View {
        if feature.isToggle, inSheet {
            Toggle(isOn: Binding(get: { feature.boolValue }, set: { onChange(.bool($0)) })) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt").font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 24)
                    Text(feature.label)
                }
            }
            .tint(Theme.accent)
        } else if feature.isToggle {
            Button { onChange(.bool(!feature.boolValue)) } label: {
                ControlLabel(systemImage: feature.boolValue ? "bolt.fill" : "bolt", title: feature.label, on: feature.boolValue, chevron: false)
            }
            .help(feature.boolValue ? "已开启，点击关闭" : "点击开启")
            .buttonStyle(.plain)
        } else if !feature.options.isEmpty {
            Menu {
                ForEach(feature.options) { o in
                    Button { onChange(.string(o.id)) } label: {
                        if o.id == feature.selectedId { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                    }
                }
            } label: {
                ControlLabel(systemImage: "slider.horizontal.3", title: inSheet ? (feature.options.first { $0.id == feature.selectedId }?.label ?? "默认") : feature.label + "：" + (feature.options.first { $0.id == feature.selectedId }?.label ?? "默认"), rowTitle: feature.label)
            }
            .controlMenuStyle()
        }
    }
}

struct SubagentRowButton<Icon: View>: View {
    let label: String
    let detail: String?
    @ViewBuilder let icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon.frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 13)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProviderSubagentStatusIcon: View {
    let status: String

    var body: some View {
        switch status {
        case "running": ProgressView().controlSize(.mini)
        case "failed": Image(systemName: "xmark.circle").foregroundStyle(Theme.destructive).accessibilityLabel("失败")
        case "canceled": Image(systemName: "minus.circle").foregroundStyle(Theme.muted).accessibilityLabel("已取消")
        default: Image(systemName: "asterisk").foregroundStyle(Theme.muted).accessibilityHidden(true)
        }
    }
}

/// A file being uploaded to the host (or done) for the next message.
struct UploadItem: Identifiable {
    let id = UUID()
    let name: String
    var file: UploadedFile?
    var error: String?
    var done: Bool { file != nil }
}

struct UploadTray: View {
    @Binding var items: [UploadItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        if item.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.destructive) }
                        else if item.done { Image(systemName: "doc.fill").foregroundStyle(Theme.muted) }
                        else { ProgressView().controlSize(.mini) }
                        Text(item.name).lineLimit(1).frame(maxWidth: 180)
                        Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            .accessibilityLabel("移除附件")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.surface2, in: Capsule())
                    .help(item.error ?? item.name)
                }
            }
            .padding(.top, 6).padding(.horizontal, 4)
        }
    }
}

/// Reads picked files and uploads them to `host`, updating the tray as each finishes.
@MainActor
func uploadFiles(_ urls: [URL], to host: HostStore, into items: Binding<[UploadItem]>) {
    for url in urls {
        let item = UploadItem(name: url.lastPathComponent)
        items.wrappedValue.append(item)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 50 * 1024 * 1024 else { throw HostStore.ActionError.rejected("文件超过 50 MB") }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let f = try await host.upload(fileName: url.lastPathComponent, mimeType: mime, data: data)
                if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].file = f }
            } catch {
                if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].error = "\(error)" }
            }
        }
    }
}

struct QueuedMessage: Identifiable {
    let id = UUID()
    let text: String
    let images: [ImageAttachment]
    var files: [JSONValue] = []
}

/// New chat: pick provider/model/thinking; the first message creates the agent in `workspace`.
struct DraftComposerView: View {
    let host: HostStore
    let workspace: Workspace
    var worktree: WorktreeChoice? = nil
    /// The new-chat page: the session gets its own new workspace in the project directory (official new-workspace
    /// screen, isolation "local"). A draft tab inside a workspace leaves this off and joins that workspace.
    var newWorkspace = false
    let onCreated: (String) -> Void
    /// 发出到 daemon 回复之间的首条消息（失败或完成时回 nil），由外层换成 PendingStartView 显示。
    var onPending: (PendingStart?) -> Void = { _ in }
    @AppStorage("draft.provider") private var provider = "claude"
    /// Model / thinking / mode are remembered per provider (official: per-provider draft preferences).
    @State private var model = ""
    @State private var thinking = ""
    @State private var mode = ""
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var images: [ImageAttachment] = []
    @State private var sending = false
    @State private var error: String?
    @State private var autocomplete = AutocompleteModel()
    @State private var uploads: [UploadItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let fork = app.forkDraft {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                    Text("带着「\(fork.title)」的对话上下文").lineLimit(1)
                    Button { app.forkDraft = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("取消带上下文")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).frame(height: 28)
                .glassEffect(.regular, in: Capsule())
            }
            shell
        }
        .onChange(of: text) { _, t in autocomplete.update(text: t, host: host, agentId: nil, cwd: workspace.directory) }
        .onAppear {
            if let f = app.forkDraft {
                provider = f.provider
                model = f.model ?? ""
                thinking = f.thinking ?? ""
                mode = f.modeId ?? ""
            } else if let p = app.draftPreset {
                app.draftPreset = nil
                provider = p.provider
                model = p.model ?? ""
                thinking = p.thinking ?? ""
                mode = p.modeId ?? ""
            } else {
                loadRemembered()
            }
        }
        .onChange(of: model) { remember() }
        .onChange(of: thinking) { remember() }
        .onChange(of: mode) { remember() }
    }

    private var shell: some View {
        ComposerShell(text: $text, images: $images, focused: $focused, error: error, placeholder: "发送消息",
                      autocomplete: autocomplete, onPick: { autocomplete.apply($0, to: &text) }, uploads: $uploads,
                      onFiles: { uploadFiles($0, to: host, into: $uploads) },
                      searchForge: workspace.isGit ? { [host, dir = workspace.directory] q in try await host.forgeSearch(cwd: dir, query: q) } : nil) {
            EmptyView()
        } controls: {
            ComposerControls(summary: composerSummary(host, provider, model.isEmpty ? nil : model, thinking.isEmpty ? nil : thinking)) {
            Menu {
                ForEach(host.providers.filter { $0["enabled"]?.boolValue != false }, id: \.self) { p in
                    let id = p["provider"]?.stringValue ?? ""
                    Button { provider = id; loadRemembered() } label: {
                        if id == provider { Label(p["label"]?.stringValue ?? id, systemImage: "checkmark") } else { Text(p["label"]?.stringValue ?? id) }
                    }
                }
            } label: {
                ControlLabel(systemImage: "cpu", title: providerLabel, rowTitle: "提供方")
            }
            .controlMenuStyle()
            ModelMenu(host: host, provider: provider, cwd: workspace.directory, selection: model.isEmpty ? nil : model) { model = $0 ?? ""; thinking = "" }
            ThinkingMenu(host: host, provider: provider, model: model.isEmpty ? nil : model, selection: thinking.isEmpty ? nil : thinking) { thinking = $0 ?? "" }
            let modes = providerEntry?["modes"]?.arrayValue ?? []
            if !modes.isEmpty {
                let current = effectiveMode.isEmpty ? (providerEntry?["defaultModeId"]?.stringValue ?? "") : effectiveMode
                Menu {
                    ForEach(modes, id: \.self) { m in
                        let id = m["id"]?.stringValue ?? ""
                        Button { mode = id } label: {
                            if id == current { Label(m["label"]?.stringValue ?? id, systemImage: "checkmark") } else { Text(m["label"]?.stringValue ?? id) }
                        }
                    }
                } label: {
                    ControlLabel(systemImage: "shield.lefthalf.filled",
                                 title: modes.first { $0["id"]?.stringValue == current }?["label"]?.stringValue ?? "模式", rowTitle: "模式")
                }
                .controlMenuStyle()
            }
            if !host.agentProfiles.isEmpty {
                Menu {
                    Section("套用配置") {
                        ForEach(host.agentProfiles, id: \.self) { p in
                            Button(p["name"]?.stringValue ?? "配置") {
                                provider = p["provider"]?.stringValue ?? provider
                                model = p["model"]?.stringValue ?? ""
                                thinking = p["thinkingOptionId"]?.stringValue ?? ""
                                mode = p["modeId"]?.stringValue ?? ""
                            }
                        }
                    }
                } label: { ControlLabel(systemImage: "person.crop.square", title: "配置", rowTitle: "套用配置", rowValue: false) }
                    .controlMenuStyle()
            }
            }
        } trailing: {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RoundButton(systemImage: "arrow.up", busy: sending, help: "开始") { create() }
            }
        } onSubmit: { create() }
        .task { await host.loadProviders(cwd: workspace.directory) }
        .onAppear {
            #if os(macOS)
            focused = true
            #endif
        }
    }

    private var providerEntry: JSONValue? { host.providers.first { $0["provider"]?.stringValue == provider } }

    /// 新会话没选过模式时默认最宽松的权限模式（Claude bypassPermissions、Codex full-access）；提供方没有这类模式才交给 daemon 默认。
    private var effectiveMode: String {
        if !mode.isEmpty { return mode }
        let ids = (providerEntry?["modes"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        return ["bypassPermissions", "full-access"].first(where: ids.contains) ?? ""
    }

    /// 没选模型时显式带上提供方的默认模型：daemon 收到不带模型的创建请求，要先等这个目录的提供方快照
    /// （列模型）准备好才能开会话，实测要多等约 2 秒；带上模型只要零点几秒。快照还没拿到就照旧交给 daemon。
    private var effectiveModel: String? {
        if !model.isEmpty { return model }
        return models(host, provider).first { $0["isDefault"]?.boolValue == true }?["id"]?.stringValue
    }

    private func loadRemembered() {
        let d = UserDefaults.standard
        model = d.string(forKey: "draft.\(provider).model") ?? ""
        thinking = d.string(forKey: "draft.\(provider).thinking") ?? ""
        mode = d.string(forKey: "draft.\(provider).mode") ?? ""
    }

    private func remember() {
        let d = UserDefaults.standard
        d.set(model, forKey: "draft.\(provider).model")
        d.set(thinking, forKey: "draft.\(provider).thinking")
        d.set(mode, forKey: "draft.\(provider).mode")
    }

    /// Where a new workspace opens: the project's root (a worktree workspace's project is its main checkout).
    private var projectDirectory: String { workspace.projectRootPath.isEmpty ? workspace.directory : workspace.projectRootPath }

    private var providerLabel: String {
        host.providers.first { $0["provider"]?.stringValue == provider }?["label"]?.stringValue ?? provider
    }

    private func create() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        sending = true
        error = nil
        let attachments = (app.forkDraft.map { [$0.attachment] } ?? []) + uploads.compactMap(\.file).map(\.attachment)
        // 先显示刚发的消息并清空输入框（官方提交时同样清空），失败再原样还回去。
        let images = images
        onPending(PendingStart(text: prompt, images: images))
        text = ""
        self.images = []
        Task {
            do {
                let id: String
                if let worktree {
                    var config: [String: JSONValue] = ["provider": .string(provider), "cwd": .string(workspace.directory)]
                    if let model = effectiveModel { config["model"] = .string(model) }
                    if !thinking.isEmpty { config["thinkingOptionId"] = .string(thinking) }
                    if !effectiveMode.isEmpty { config["modeId"] = .string(effectiveMode) }
                    let (_, agentId) = try await host.createWorkspace(source: .object(worktree.source), agentConfig: config, prompt: prompt, images: images,
                                                                      attachments: attachments)
                    guard let agentId else { throw HostStore.ActionError.rejected("工作区已创建，但会话没有启动") }
                    id = agentId
                } else if newWorkspace, !workspace.projectId.isEmpty {
                    var config: [String: JSONValue] = ["provider": .string(provider), "cwd": .string(projectDirectory)]
                    if let model = effectiveModel { config["model"] = .string(model) }
                    if !thinking.isEmpty { config["thinkingOptionId"] = .string(thinking) }
                    if !effectiveMode.isEmpty { config["modeId"] = .string(effectiveMode) }
                    let source: [String: JSONValue] = ["kind": "directory", "path": .string(projectDirectory),
                                                       "projectId": .string(workspace.projectId)]
                    let (_, agentId) = try await host.createWorkspace(source: .object(source), agentConfig: config, prompt: prompt,
                                                                      images: images, attachments: attachments)
                    guard let agentId else { throw HostStore.ActionError.rejected("工作区已创建，但会话没有启动") }
                    id = agentId
                } else {
                    id = try await host.createAgent(workspace: workspace, provider: provider, model: effectiveModel,
                                                    modeId: effectiveMode.isEmpty ? nil : effectiveMode, thinkingOptionId: thinking.isEmpty ? nil : thinking,
                                                    prompt: prompt, images: images, attachments: attachments)
                }
                uploads = []
                app.forkDraft = nil
                onCreated(id)
                onPending(nil)
            } catch {
                onPending(nil)
                if text.isEmpty { text = prompt }
                if self.images.isEmpty { self.images = images }
                self.error = "创建失败：\(error)"
            }
            sending = false
        }
    }
}

@MainActor private func models(_ host: HostStore, _ provider: String) -> [JSONValue] {
    host.providers.first { $0["provider"]?.stringValue == provider }?["models"]?.arrayValue ?? []
}

/// "Opus 5.5 · Medium": the model and thinking level, for the single settings button on narrow screens.
@MainActor func composerSummary(_ host: HostStore, _ provider: String, _ model: String?, _ thinking: String?) -> String {
    let list = models(host, provider)
    let entry = list.first { $0["id"]?.stringValue == model } ?? list.first { $0["isDefault"]?.boolValue == true }
    let modelLabel = entry?["label"]?.stringValue ?? model ?? "默认模型"
    let current = thinking ?? entry?["defaultThinkingOptionId"]?.stringValue
    let thinkingLabel = (entry?["thinkingOptions"]?.arrayValue ?? []).first { $0["id"]?.stringValue == current }?["label"]?.stringValue
    return [modelLabel, thinkingLabel].compactMap { $0 }.joined(separator: " · ")
}

/// Composer settings (provider, model, thinking, mode, toggles): inline where there is room; on an iPhone one
/// button with a summary opens them in a bottom sheet instead of a row you have to scroll sideways.
struct ComposerControls<Content: View>: View {
    let summary: String
    @ViewBuilder let content: Content
    @State private var showing = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        if compact {
            folded
        } else {
            #if os(iOS)
            // iPad portrait, split view: all the controls if they fit, else the same button as on iPhone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { content }.fixedSize()
                folded
            }
            #else
            content
            #endif
        }
    }

    private var folded: some View {
        Button { showing = true } label: { ControlLabel(systemImage: "slider.horizontal.3", title: summary) }
            .buttonStyle(.plain)
            .sheet(isPresented: $showing) {
                NavigationStack {
                    // One control per row of a grouped list, like system Settings.
                    // Settings rows rather than toolbar capsules (ControlLabel / FeatureChip read this).
                    List { content }
                        .environment(\.controlsInSheet, true)
                        .navigationTitle("会话设置")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showing = false } } }
                }
                .presentationDetents([.medium, .large])
            }
            #if DEBUG
            // PASEO_SHOW_CONTROLS=1 opens the sheet (simulator screenshots).
            .task {
                if ProcessInfo.processInfo.environment["PASEO_SHOW_CONTROLS"] == "1" {
                    try? await Task.sleep(for: .seconds(4))
                    showing = true
                }
            }
            #endif
    }
}

struct ModelMenu: View {
    let host: HostStore
    let provider: String
    let cwd: String
    let selection: String?
    let onSelect: (String?) -> Void

    @State private var browsing = false
    @State private var query = ""

    var body: some View {
        let list = models(host, provider)
        Group {
            if list.count > 8 {
                Button { browsing = true } label: { ControlLabel(systemImage: "sparkle", title: label(list), rowTitle: "模型") }
                    .buttonStyle(.plain)
                    .popover(isPresented: $browsing, arrowEdge: .bottom) { browser(list) }
            } else {
                menu(list)
            }
        }
        .task(id: provider) { if host.providers.isEmpty { await host.loadProviders(cwd: cwd) } }
    }

    /// Searchable list for providers with many models (official model browser).
    private func browser(_ list: [JSONValue]) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? list : list.filter {
            ($0["label"]?.stringValue ?? "").lowercased().contains(q) || ($0["id"]?.stringValue ?? "").lowercased().contains(q)
        }
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索模型", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { m in
                        let id = m["id"]?.stringValue ?? ""
                        Button { onSelect(id); browsing = false; query = "" } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m["label"]?.stringValue ?? id).font(.system(size: 13))
                                    if let d = m["description"]?.stringValue { Text(d).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
                                }
                                Spacer()
                                if id == selection { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if shown.isEmpty { Text("没有匹配的模型").foregroundStyle(Theme.muted).padding() }
                }
            }
            .macOnly { $0.frame(height: 320) }
        }
        .pickerSheet(width: 320, height: 370)
    }

    private func menu(_ list: [JSONValue]) -> some View {
        Menu {
            if list.isEmpty { Text("加载中…") }
            ForEach(list, id: \.self) { m in
                let id = m["id"]?.stringValue ?? ""
                Button { onSelect(id) } label: {
                    if id == selection { Label(m["label"]?.stringValue ?? id, systemImage: "checkmark") } else { Text(m["label"]?.stringValue ?? id) }
                }
            }
        } label: {
            ControlLabel(systemImage: "sparkle", title: label(list), rowTitle: "模型")
        }
        .controlMenuStyle()
    }

    private func label(_ list: [JSONValue]) -> String {
        if let selection, let m = list.first(where: { $0["id"]?.stringValue == selection }) { return m["label"]?.stringValue ?? selection }
        if selection == nil, let m = list.first(where: { $0["isDefault"]?.boolValue == true }) { return m["label"]?.stringValue ?? "默认模型" }
        return selection ?? "默认模型"
    }
}

/// Thinking level options come from the model entry in the providers snapshot.
struct ThinkingMenu: View {
    let host: HostStore
    let provider: String
    let model: String?
    let selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        let list = models(host, provider)
        let entry = list.first { $0["id"]?.stringValue == model } ?? list.first { $0["isDefault"]?.boolValue == true }
        let options = entry?["thinkingOptions"]?.arrayValue ?? []
        if !options.isEmpty {
            let current = selection ?? entry?["defaultThinkingOptionId"]?.stringValue
            Menu {
                ForEach(options, id: \.self) { o in
                    let id = o["id"]?.stringValue ?? ""
                    Button { onSelect(id) } label: {
                        if id == current { Label(o["label"]?.stringValue ?? id, systemImage: "checkmark") } else { Text(o["label"]?.stringValue ?? id) }
                    }
                }
            } label: {
                ControlLabel(systemImage: "brain", title: options.first { $0["id"]?.stringValue == current }?["label"]?.stringValue ?? current ?? "思考", rowTitle: "思考")
            }
            .controlMenuStyle()
        }
    }
}

extension EnvironmentValues {
    /// Set while the timeline is scrolled up: the composer shows a 「⌄」 chip at the right of its chips row.
    @Entry var scrollToBottom: (() -> Void)? = nil
}

/// True inside the iPhone「会话设置」sheet: the composer controls render as settings rows instead of capsules.
extension EnvironmentValues {
    @Entry var controlsInSheet = false
}

/// Menu styling shared by the composer controls; sized to content in the toolbar, full row width in the sheet.
struct ControlMenuStyle: ViewModifier {
    @Environment(\.controlsInSheet) private var inSheet

    func body(content: Content) -> some View {
        let styled = content.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        if inSheet { styled } else { styled.fixedSize() }
    }
}

extension View {
    func controlMenuStyle() -> some View { modifier(ControlMenuStyle()) }
}

/// A setting inside the composer toolbar: icon + value (+ chevron), lighter than a glass chip.
/// In the settings sheet: "icon  名称 ……… 当前值 ⌃⌄", like a row in system Settings.
struct ControlLabel: View {
    let systemImage: String
    let title: String
    /// Row name shown in the settings sheet（模型 / 思考 / 模式…）; `title` becomes the trailing value.
    var rowTitle: String? = nil
    /// Show `title` as the trailing value of the sheet row (off for action rows like 套用配置).
    var rowValue = true
    var on = false
    var chevron = true
    @State private var hovering = false
    @Environment(\.controlsInSheet) private var inSheet

    var body: some View {
        if inSheet { row } else { capsule }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(rowTitle ?? title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if rowTitle != nil, rowValue {
                Text(title).foregroundStyle(Theme.muted).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var capsule: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text(title).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.6) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(on ? Theme.accent : Theme.muted)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(hovering || on ? Theme.surface2 : .clear, in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

/// Small glass capsule used above the composer.
struct Chip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// Chips row above a glass capsule input: "+" · text · trailing button. Accepts pasted and dropped images.
struct ComposerShell<Chips: View, Controls: View, Trailing: View>: View {
    @Binding var text: String
    @Binding var images: [ImageAttachment]
    var focused: FocusState<Bool>.Binding
    let error: String?
    let placeholder: String
    var autocomplete: AutocompleteModel? = nil
    var onPick: ((Suggestion) -> Void)? = nil
    var uploads: Binding<[UploadItem]>? = nil
    var onFiles: (@MainActor @Sendable ([URL]) -> Void)? = nil
    /// ⌘Enter: the other send behavior (queue ↔ now).
    var onAlternateSubmit: (() -> Void)? = nil
    /// ↑ in an empty box: bring back the last sent message.
    var onRecall: (() -> Void)? = nil
    /// ⇧Tab: next permission mode.
    var onCycleMode: (() -> Void)? = nil
    /// Tab in an empty box (e.g. accept the suggested next message); true when handled.
    var onTabEmpty: (() -> Bool)? = nil
    /// Issue / PR search on the workspace's forge; picks become attachments in `uploads`.
    var searchForge: ((String) async throws -> [ForgeItem])? = nil
    @ViewBuilder let chips: Chips
    @ViewBuilder let controls: Controls
    @ViewBuilder let trailing: Trailing
    let onSubmit: () -> Void
    @State private var picking = false
    @State private var pickingFiles = false
    #if os(iOS)
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    #endif
    @State private var dropTargeted = false
    @State private var fullscreen = false
    #if os(macOS)
    /// ⌘V interception: the text field's editor only pastes text, so images never reached onPasteCommand.
    @State private var pasteMonitor: Any?
    #endif
    @State private var pickingForge = false
    @State private var forgeQuery = ""
    @State private var forgeResults: [ForgeItem] = []
    @State private var forgeError: String?
    /// "enter" (⇧↩ newline) or "cmdEnter" (↩ newline, ⌘↩ send).
    @AppStorage("sendKey") private var sendKey = "enter"

    #if os(macOS)
    /// 在输入框的光标处插入换行（有选中文字时替换掉），走当前的文字编辑器，撤销也正常。
    private func insertNewlineAtCursor() {
        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
    }
    #else
    /// Hardware Return in ComposerTextView (input method not composing, no ⇧): ↩ sends, ⌘↩ the other send;
    /// with 「⌘↩ 发送」 set, ↩ types a newline. False = let the text view type the newline.
    private func hardwareReturn(_ command: Bool) -> Bool {
        if let a = autocomplete, a.isActive { onPick?(a.items[a.index]); return true }
        if sendKey == "cmdEnter" {
            guard command else { return false }
            onSubmit()
            return true
        }
        if command, let onAlternateSubmit { onAlternateSubmit(); return true }
        onSubmit()
        return true
    }

    /// Same keys as the Mac's onKeyPress: completion list, ↑ recall, ⇧Tab mode, Tab in an empty box.
    private func hardwareKey(_ key: ComposerKey) -> Bool {
        guard let a = autocomplete, a.isActive else {
            switch key {
            case .up: if text.isEmpty, let onRecall { onRecall(); return true }
            case .shiftTab: if let onCycleMode { onCycleMode(); return true }
            case .tab: if text.isEmpty, onTabEmpty?() == true { return true }
            default: break
            }
            return false
        }
        switch key {
        case .up: a.index = max(0, a.index - 1)
        case .down: a.index = min(a.items.count - 1, a.index + 1)
        case .tab: onPick?(a.items[a.index])
        case .shiftTab: return false
        case .escape: a.dismiss()
        }
        return true
    }
    #endif
    @Environment(\.scrollToBottom) private var scrollToBottom

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive).padding(.leading, 8) }
                if let autocomplete, autocomplete.isActive {
                    SuggestionList(model: autocomplete) { onPick?($0) }
                }
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { chips }.padding(.vertical, 2) }
                    if let scrollToBottom {
                        Button(action: scrollToBottom) { Chip { Image(systemName: "chevron.down") } }
                            .buttonStyle(.plain)
                            .help("滚动到底部")
                            .accessibilityLabel("滚动到底部")
                            .transition(.opacity)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !images.isEmpty { AttachmentTray(images: $images) }
                    if let uploads, !uploads.wrappedValue.isEmpty { UploadTray(items: uploads) }
                    #if os(iOS)
                    ComposerTextView(text: $text, placeholder: placeholder, focused: focused, fontSize: Theme.content,
                                     onReturn: hardwareReturn, onKey: hardwareKey, onPasteImages: { images += $0 })
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                    #else
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.content))
                        .lineLimit(3...12)
                        .focused(focused)
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                        #if os(macOS)
                        .onKeyPress(.return, phases: .down) { press in
                            // Return confirms the input method's pending text (e.g. stops voice input), never sends it.
                            if inputMethodComposing() { return .ignored }
                            // ⇧↩ 换行：自己在光标处插入换行。交还给系统的话，多行 TextField 在 macOS 上把 ⇧↩ 当成结束输入，换不了行。
                            if press.modifiers.contains(.shift) { insertNewlineAtCursor(); return .handled }
                            if let a = autocomplete, a.isActive { onPick?(a.items[a.index]); return .handled }
                            if sendKey == "cmdEnter" {
                                // ↩ inserts a newline; ⌘↩ sends.
                                guard press.modifiers.contains(.command) else { insertNewlineAtCursor(); return .handled }
                                onSubmit()
                                return .handled
                            }
                            if press.modifiers.contains(.command), let onAlternateSubmit { onAlternateSubmit(); return .handled }
                            onSubmit()
                            return .handled
                        }
                        .onPasteCommand(of: [.png, .tiff, .jpeg, .heic, .fileURL]) { providers in
                            ImageTools.load(providers) { images += $0 }
                        }
                        #endif
                    #endif
                    HStack(spacing: 2) {
                        Menu {
                            #if os(iOS)
                            // iPhone / iPad: photos come from the library first; the Files app stays one tap away.
                            Button("从相册选择…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                            Button("从文件选择图片…", systemImage: "photo") { picking = true }
                            #else
                            Button("选择图片…", systemImage: "photo") { picking = true }
                            #endif
                            if onFiles != nil { Button("选择文件…", systemImage: "doc") { pickingFiles = true } }
                            #if os(macOS)
                            Button("粘贴图片", systemImage: "doc.on.clipboard") { pasteImages() }
                            #endif
                            if searchForge != nil, uploads != nil {
                                Button("添加 Issue / PR…", systemImage: "number") { pickingForge = true }
                            }
                            Divider()
                            Button("全屏编辑", systemImage: "arrow.up.left.and.arrow.down.right") { fullscreen = true }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28)
                                .foregroundStyle(Theme.muted)
                        }
                        .controlMenuStyle()
                        .help("添加图片或文件")
                        .accessibilityLabel("添加图片或文件")
                        .popover(isPresented: $pickingForge, arrowEdge: .bottom) { forgePicker }
                        #if os(iOS)
                        // ComposerControls folds itself into one button when the row is too narrow.
                        controls
                        #else
                        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 2) { controls } }
                        #endif
                        Spacer(minLength: 8)
                        HStack(spacing: 8) { trailing }
                    }
                }
                #if os(macOS)
                // iOS: ComposerTextView passes these keys to hardwareKey.
                .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape]) { press in
                    // Arrows, Tab and Esc pick or cancel input method candidates while it is composing.
                    if inputMethodComposing() { return .ignored }
                    guard let a = autocomplete, a.isActive else {
                        if press.key == .upArrow, text.isEmpty, let onRecall { onRecall(); return .handled }
                        if press.key == .tab, press.modifiers.contains(.shift), let onCycleMode { onCycleMode(); return .handled }
                        if press.key == .tab, text.isEmpty, onTabEmpty?() == true { return .handled }
                        return .ignored
                    }
                    switch press.key {
                    case .upArrow: a.index = max(0, a.index - 1)
                    case .downArrow: a.index = min(a.items.count - 1, a.index + 1)
                    case .tab: onPick?(a.items[a.index])
                    default: a.dismiss()
                    }
                    return .handled
                }
                #endif
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.accent, lineWidth: dropTargeted ? 2 : 0))
            }
        }
        #if os(macOS)
        .onAppear {
            guard pasteMonitor == nil else { return }
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard focused.wrappedValue,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      e.charactersIgnoringModifiers?.lowercased() == "v",
                      pasteAttachments() else { return e }
                return nil
            }
        }
        .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil } }
        #endif
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            // Images become inline images; other files are uploaded as attachments.
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let onFiles {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                        Task { @MainActor in
                            if isImage { images += ImageTools.attachments(from: [url]) } else { onFiles([url]) }
                        }
                    }
                } else {
                    ImageTools.load([p]) { images += $0 }
                }
            }
            return true
        }
        .sheet(isPresented: $fullscreen) {
            VStack(spacing: 0) {
                TextEditor(text: $text).font(.system(size: Theme.content)).padding(12)
                Divider()
                HStack {
                    Text("\(text.count) 字").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("完成") { fullscreen = false }.keyboardShortcut(.cancelAction)
                    Button("发送") { fullscreen = false; onSubmit() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
            .macOnly { $0.frame(minWidth: 720, minHeight: 520) }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { images += ImageTools.attachments(from: urls) }
        }
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let a = ImageTools.attachment(from: data) {
                        images.append(a)
                    }
                }
            }
        }
        #endif
        .background {
            Color.clear.fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { onFiles?(urls) }
            }
        }
        .frame(maxWidth: Theme.chatMaxWidth)
        .padding(.horizontal, 16)
        .bottomBarPlacement()
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    private var forgePicker: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索 Issue 或 PR（编号或关键词）", text: $forgeQuery).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let forgeError { Text(forgeError).font(.caption).foregroundStyle(Theme.destructive).padding(10) }
                    ForEach(forgeResults) { item in
                        Button {
                            uploads?.wrappedValue.append(UploadItem(name: "#\(item.number) " + item.title,
                                                                    file: UploadedFile(id: item.id, fileName: "#\(item.number) " + item.title, size: 0, attachment: item.attachment)))
                            pickingForge = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.isChangeRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                                    .foregroundStyle(item.state.lowercased() == "open" ? Theme.dotSuccess : Theme.muted)
                                Text("#\(item.number)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                                Text(item.title).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if forgeResults.isEmpty && forgeError == nil {
                        Text(forgeQuery.isEmpty ? "输入关键词搜索" : "没有结果").font(.caption).foregroundStyle(Theme.muted).padding(10)
                    }
                }
            }
            .macOnly { $0.frame(height: 280) }
        }
        .pickerSheet(width: 380, height: 330)
        .task(id: forgeQuery) {
            guard let searchForge else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { forgeResults = try await searchForge(forgeQuery); forgeError = nil }
            catch { forgeError = "\(error)"; forgeResults = [] }
        }
    }

    #if os(macOS)
    /// Pastes images (and, with uploads, other copied files) as attachments. Returns false when the
    /// clipboard holds text instead, so ⌘V falls through to the normal text paste.
    private func pasteAttachments() -> Bool {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            let isImage = { (u: URL) in UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true }
            let pics = urls.filter(isImage), others = urls.filter { !isImage($0) }
            if !pics.isEmpty { images += ImageTools.attachments(from: pics) }
            if !others.isEmpty, let onFiles { onFiles(others) }
            return !pics.isEmpty || (!others.isEmpty && onFiles != nil)
        }
        // Text wins when both are present (copying from a web page puts an image and text on the clipboard).
        if let text = pb.string(forType: .string), !text.isEmpty { return false }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let a = ImageTools.attachment(from: data) {
            images.append(a)
            return true
        }
        return false
    }

    private func pasteImages() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty {
            images += ImageTools.attachments(from: urls)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let a = ImageTools.attachment(from: data) {
            images.append(a)
        }
    }
    #endif
}

struct RoundButton: View {
    let systemImage: String
    let busy: Bool
    let help: String
    var fill: Color = .black
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if busy { ProgressView().controlSize(.mini).tint(.white) }
                else { Image(systemName: systemImage).font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension Notification.Name {
    static let focusComposer = Notification.Name("paseo.focusComposer")
    static let openCommandPalette = Notification.Name("paseo.openCommandPalette")
    static let openSettings = Notification.Name("paseo.openSettings")
    static let restoreComposer = Notification.Name("paseo.restoreComposer")
    static let findInSession = Notification.Name("paseo.findInSession")
    static let showOutline = Notification.Name("paseo.showOutline")
    static let toggleSidebar = Notification.Name("paseo.toggleSidebar")
    static let archiveCurrent = Notification.Name("paseo.archiveCurrent")
    static let renameCurrent = Notification.Name("paseo.renameCurrent")
    static let showShortcuts = Notification.Name("paseo.showShortcuts")
    static let cycleAppearance = Notification.Name("paseo.cycleAppearance")
    static let searchFiles = Notification.Name("paseo.searchFiles")
    /// Object: WorkspaceRef (or nil for the current one).
    static let importSessions = Notification.Name("paseo.importSessions")
    /// Object: (WorkspaceRef, absolute path).
    static let openFileTab = Notification.Name("paseo.openFileTab")
    static let addProject = Notification.Name("paseo.addProject")
    /// Object: (agentId, message) from timeline actions (rewind, fork).
    static let timelineActionError = Notification.Name("paseo.timelineActionError")
    /// Scroll the visible agent's chat to a timeline row id.
    static let scrollToMessage = Notification.Name("paseo.scrollToMessage")
    /// Adds a reference (e.g. `@path`) to the composer of the current workspace's agent.
    static let appendToComposer = Notification.Name("paseo.appendToComposer")
}

/// 后台任务列表里的一行：状态、命令、运行了多久或结束摘要。
private struct BackgroundTaskRow: View {
    let task: AgentBackgroundTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.command).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                Group {
                    if task.state == .running, let start = task.startedAt {
                        // 每 30 秒刷新「已运行」。
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("运行中 · 已运行 " + formatDuration(max(0, context.date.timeIntervalSince(start))))
                        }
                    } else {
                        Text([stateLabel, task.summary].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var stateLabel: String {
        switch task.state {
        case .running: "运行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .stopped: "已停止"
        case .interrupted: "已中断（会话已结束）"
        }
    }

    @ViewBuilder private var icon: some View {
        switch task.state {
        case .running: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.dotSuccess)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.destructive)
        case .stopped, .interrupted: Image(systemName: "stop.circle").foregroundStyle(Theme.muted)
        }
    }
}
