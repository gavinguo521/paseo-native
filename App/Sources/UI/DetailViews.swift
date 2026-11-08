import PaseoKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Session

struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    let host: HostStore
    let ref: AgentRef
    @State private var renamingWorkspace: Workspace?
    @State private var archivingWorkspace: Workspace?
    @State private var labelingWorkspace: Workspace?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmArchive = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var agent: Agent? { host.agents[ref.agentId] }

    /// iPhone: one 「⋯」 holding everything. Separate buttons do not fit, and iOS folds the extras into its own
    /// overflow 「⋯」 — tapping through 「⋯」 → 「⋯」 → menu.
    private var narrow: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private func workspaceCommand(_ c: WorkspaceTabCommand) {
        NotificationCenter.default.post(name: .workspaceTabCommand, object: c)
    }

    var body: some View {
        AgentView(host: host, agentId: ref.agentId, workspace: model.workspace(of: ref), reading: model.readingState(for: ref), displayCache: model.sessionDisplayCaches.cache(for: ref))
            .navigationTitle(agent?.displayTitle ?? "会话")
            #if os(macOS)
            .navigationSubtitle([agent.map { model.projectName(of: $0, in: host) }, host.label].compactMap { $0 }.joined(separator: " · "))
            #else
            .navigationBarTitleDisplayMode(.inline)
            // Sessions opened without a workspace tab container: opaque bar on iOS 18, unchanged on iOS 26+.
            .compatibleNavigationBarBackground(hiddenOnNewer: false)
            #endif
            .toolbar {
                if !narrow {
                    ToolbarItem(placement: .primaryAction) {
                        Button { NotificationCenter.default.post(name: .showOutline, object: nil) } label: { Image(systemName: "list.bullet.indent") }
                            .help("提问大纲（⌘⇧O）")
                            .accessibilityLabel("提问大纲")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if narrow {
                            Section {
                                Button("提问大纲", systemImage: "list.bullet.indent") { NotificationCenter.default.post(name: .showOutline, object: nil) }
                                if model.workspace(of: ref) != nil {
                                    Button("改动与文件", systemImage: "sidebar.right") { workspaceCommand(.toggleExplorer) }
                                    Button("脚本", systemImage: "play.rectangle") { workspaceCommand(.scripts) }
                                }
                            }
                        }
                        Button("重命名", systemImage: "pencil") { newName = agent?.displayTitle ?? ""; renaming = true }
                        Button("复制会话 ID", systemImage: "doc.on.doc") { Pasteboard.copy(ref.agentId) }
                        if let cmd = agent?.resumeCommand { Button("复制恢复命令", systemImage: "terminal") { Pasteboard.copy(cmd) } }
                        Button("重新加载", systemImage: "arrow.clockwise") { Task { try? await host.reload(ref.agentId) } }
                        if agent?.parentAgentId != nil {
                            Button("解除父子关系", systemImage: "link.badge.plus") { Task { try? await host.detach(ref.agentId) } }
                        }
                        if let w = model.workspace(of: ref) {
                            Menu("工作区「\(w.name)」") {
                                WorkspaceMenuItems(host: host, workspace: w, renaming: $renamingWorkspace, archiving: $archivingWorkspace,
                                                   labeling: $labelingWorkspace)
                            }
                        }
                        Divider()
                        Button("归档", systemImage: "archivebox", role: .destructive) { confirmArchive = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("会话操作")
                }
            }
            .workspaceDialogs(renaming: $renamingWorkspace, archiving: $archivingWorkspace, labeling: $labelingWorkspace)
            .onReceive(NotificationCenter.default.publisher(for: .renameCurrent)) { _ in newName = agent?.displayTitle ?? ""; renaming = true }
            .onReceive(NotificationCenter.default.publisher(for: .archiveCurrent)) { _ in confirmArchive = true }
            .alert("重命名会话", isPresented: $renaming) {
                TextField("名字", text: $newName)
                Button("取消", role: .cancel) {}
                Button("保存") { Task { try? await host.rename(ref.agentId, to: newName) } }
            }
            .confirmationDialog("归档这个会话？", isPresented: $confirmArchive) {
                Button("归档", role: .destructive) {
                    let title = agent?.displayTitle ?? ""
                    Task { if (try? await host.archive(ref.agentId)) != nil { model.offerUndoArchive(ref, title: title) } }
                    if let w = model.workspace(of: ref) {
                        model.removeTab(.agent(ref.agentId), in: WorkspaceRef(serverId: ref.serverId, workspaceId: w.id))
                    } else {
                        model.destination = nil
                    }
                }
            } message: {
                Text(agent?.status == .running ? "它还在运行，归档会停止它。" : "归档后可以在会话历史里找回。")
            }
    }
}

// MARK: New chat

struct NewChatView: View {
    @Environment(AppModel.self) private var model
    @State private var worktree: WorktreeChoice?
    @State private var pending: PendingStart?

    var body: some View {
        let ref = model.defaultDraftWorkspace
        VStack(spacing: 0) {
            if let pending {
                PendingStartView(pending: pending)
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Text("要做点什么？").font(.system(size: 26, weight: .semibold))
                    // Side by side when there is room; stacked on a phone instead of pushing the page wider than the screen.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { pickers(ref) }
                        VStack(spacing: 8) { pickers(ref) }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity)
                .onChange(of: ref) { worktree = nil }
                Spacer()
            }
            if let ref, let host = model.host(ref.serverId), let workspace = model.workspace(ref) {
                DraftComposerView(host: host, workspace: workspace, worktree: worktree, newWorkspace: true, onCreated: { id in
                    model.draftWorkspace = ref
                    model.open(AgentRef(serverId: ref.serverId, agentId: id))
                }, onPending: { pending = $0 })
                .id(ref)
            }
        }
        .navigationTitle("新聊天")
        .background(Theme.surface0)
    }

    @ViewBuilder private func pickers(_ ref: WorkspaceRef?) -> some View {
        WorkspacePicker(selection: ref)
        if let ref, let host = model.host(ref.serverId), let w = model.workspace(ref), w.isGit {
            IsolationPicker(host: host, workspace: w, choice: $worktree, pickOnAppear: model.forkDraft?.newWorkspace == true)
        }
    }
}

/// Machine → project → workspace menu for where a new chat runs.
struct WorkspacePicker: View {
    @Environment(AppModel.self) private var model
    let selection: WorkspaceRef?

    var body: some View {
        Menu {
            ForEach(model.hosts) { host in
                Section(host.label) {
                    ForEach(Dictionary(grouping: host.workspaces.values, by: \.projectDisplayName).sorted { $0.key < $1.key }, id: \.key) { project, list in
                        Menu(project.isEmpty ? "其他" : project) {
                            ForEach(list.sorted { ($0.activityAt ?? .distantPast) > ($1.activityAt ?? .distantPast) }) { w in
                                Button(w.name.isEmpty ? w.directory : w.name) {
                                    model.draftWorkspace = WorkspaceRef(serverId: host.id, workspaceId: w.id)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(label).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .mobileTouchTarget()
            .compatibleGlassEffect(in: Capsule(), interactive: true)
        }
        // Height only: a long workspace name truncates instead of widening the page past a phone screen.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
    }

    /// "project · workspace" (workspace only when it differs), machine only when there are several.
    private var label: String {
        guard let selection, let w = model.workspace(selection) else { return String(localized: "选择项目") }
        let host = model.hosts.count > 1 ? model.host(selection.serverId)?.label : nil
        let ws = w.name == w.projectDisplayName ? nil : w.name
        return [w.projectDisplayName, ws, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: Projects

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var renaming: Workspace?
    @State private var archiving: Workspace?
    @State private var labeling: Workspace?
    @State private var renamingProject: (HostStore, String)?
    @State private var projectName = ""
    @State private var removingProject: (HostStore, String, String)?
    @State private var editingProject: ProjectEditTarget?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Banner(level: "error", message: error) }
            ForEach(model.visibleHosts) { host in
                Section {
                    let groups = Dictionary(grouping: host.workspaces.values, by: \.projectDisplayName).sorted { $0.key < $1.key }
                    ForEach(groups, id: \.key) { project, list in
                        DisclosureGroup {
                            ForEach(list) { w in
                                Button {
                                    model.draftWorkspace = WorkspaceRef(serverId: host.id, workspaceId: w.id)
                                    model.destination = .newChat
                                } label: {
                                    HStack {
                                        StatusDot(bucket: w.status)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(w.name)
                                                ForEach(w.labels, id: \.self) { name in
                                                    let c = host.labels.first { $0.name.lowercased() == name.lowercased() }?.color ?? "blue"
                                                    Text(name).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                                                        .background(labelColor(c).opacity(0.18), in: Capsule()).foregroundStyle(labelColor(c))
                                                }
                                            }
                                            Text(w.directory).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        if let b = w.currentBranch { Text(b).font(.caption).foregroundStyle(Theme.muted) }
                                        Image(systemName: "square.and.pencil").foregroundStyle(Theme.muted)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { WorkspaceMenuItems(host: host, workspace: w, renaming: $renaming, archiving: $archiving, labeling: $labeling) }
                            }
                        } label: {
                            Label(project.isEmpty ? "其他" : project, systemImage: "folder")
                                .contextMenu {
                                    if let pid = list.first?.projectId, !pid.isEmpty {
                                        if let p = host.projects[pid] {
                                            Button("编辑项目…", systemImage: "pencil") { editingProject = ProjectEditTarget(host: host, project: p) }
                                        } else {
                                            Button("重命名项目…", systemImage: "pencil") { projectName = project; renamingProject = (host, pid) }
                                        }
                                        Button("复制项目路径", systemImage: "doc.on.doc") { Pasteboard.copy(list.first?.projectRootPath ?? "") }
                                        Divider()
                                        Button("从 Paseo 移除项目…", systemImage: "folder.badge.minus", role: .destructive) { removingProject = (host, pid, project) }
                                    }
                                }
                        }
                    }
                } header: {
                    HStack(spacing: 6) { HostStatusDot(state: host.state); Text(host.label) }
                }
            }
        }
        .navigationTitle("项目")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Label("添加项目", systemImage: "folder.badge.plus") } } }
        .sheet(isPresented: $adding) { AddProjectView() }
        .sheet(item: $editingProject) { t in ProjectEditSheet(host: t.host, project: t.project) }
        .alert("重命名项目", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("名字（留空恢复默认）", text: $projectName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let (h, id) = renamingProject { Task { do { try await h.renameProject(id, name: projectName) } catch { self.error = "\(error)" } } }
            }
        }
        .confirmationDialog("从 Paseo 移除「\(removingProject?.2 ?? "")」？", isPresented: Binding(get: { removingProject != nil }, set: { if !$0 { removingProject = nil } })) {
            Button("移除", role: .destructive) {
                if let (h, id, _) = removingProject { Task { do { try await h.removeProject(id) } catch { self.error = "\(error)" } } }
            }
        } message: { Text("只是不再在 Paseo 里显示，磁盘上的文件不会删除。") }
        .workspaceDialogs(renaming: $renaming, archiving: $archiving, labeling: $labeling)
    }
}

// MARK: History

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Item] = []
    @State private var loading = false
    @AppStorage("history.grouping", store: AppDefaults.store) private var grouping = Grouping.date.rawValue
    @AppStorage("history.status", store: AppDefaults.store) private var statusFilter = StatusFilter.all.rawValue
    @State private var project: String?
    /// Next page per host; empty once everything is loaded.
    @State private var cursors: [String: String] = [:]
    @State private var loadingMore = false

    struct Item: Identifiable {
        let serverId: String
        let agent: Agent
        let project: String
        var id: String { serverId + ":" + agent.id }
    }

    enum Grouping: String { case date, project }
    enum StatusFilter: String { case all, open, archived }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let items: [Item]
    }

    private var filtered: [Item] {
        results.filter { item in
            (project == nil || item.project == project) &&
            (statusFilter == StatusFilter.all.rawValue || (item.agent.archivedAt != nil) == (statusFilter == StatusFilter.archived.rawValue))
        }
    }

    private var sections: [Section] {
        let items = filtered
        if grouping == Grouping.project.rawValue {
            var order: [String] = []
            var groups: [String: [Item]] = [:]
            for item in items {
                let key = item.serverId + "|" + item.project
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(item)
            }
            return order.map { key in
                let first = groups[key]![0]
                return Section(id: key, title: first.project, items: groups[key]!)
            }
        }
        let cal = Calendar.current, now = Date()
        func bucket(_ d: Date?) -> (Int, String) {
            guard let d else { return (5, String(localized: "更早")) }
            if cal.isDateInToday(d) { return (0, String(localized: "今天")) }
            if cal.isDateInYesterday(d) { return (1, String(localized: "昨天")) }
            let days = cal.dateComponents([.day], from: d, to: now).day ?? 0
            if days < 7 { return (2, String(localized: "最近 7 天")) }
            if days < 30 { return (3, String(localized: "最近 30 天")) }
            return (4, String(localized: "更早"))
        }
        return Dictionary(grouping: items) { bucket($0.agent.updatedAt).0 }
            .sorted { $0.key < $1.key }
            .map { Section(id: "d\($0.key)", title: bucket($0.value[0].agent.updatedAt).1, items: $0.value) }
    }

    private var projects: [String] { Array(Set(results.map(\.project))).sorted() }

    var body: some View {
        List {
            ForEach(sections) { section in
                SwiftUI.Section {
                    ForEach(section.items) { row($0) }
                } header: {
                    if grouping == Grouping.project.rawValue, let first = section.items.first, let host = model.host(first.serverId) {
                        HStack(spacing: 6) {
                            ProjectIcon(host: host, name: first.project, workspace: iconWorkspace(first, host: host), size: 14)
                            Text(section.title)
                            Text("\(section.items.count)").foregroundStyle(Theme.muted)
                        }
                    } else {
                        Text(section.title)
                    }
                }
            }
            if !cursors.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    .onAppear { Task { await loadMore() } }
            }
        }
        .overlay {
            if filtered.isEmpty {
                if loading || model.connectionKey.isEmpty { ProgressView(model.connectionKey.isEmpty ? "正在连接…" : "") }
                else if !query.isEmpty { ContentUnavailableView.search(text: query) }
                else if results.isEmpty { ContentUnavailableView("还没有会话", systemImage: "clock.arrow.circlepath") }
                else { ContentUnavailableView("没有符合筛选的会话", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
        .searchable(text: $query, prompt: "搜索标题、项目、分支")
        .navigationTitle("会话历史")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("分组", selection: $grouping) {
                        Text("按时间").tag(Grouping.date.rawValue)
                        Text("按项目").tag(Grouping.project.rawValue)
                    }
                    Picker("状态", selection: $statusFilter) {
                        Text("全部").tag(StatusFilter.all.rawValue)
                        Text("未归档").tag(StatusFilter.open.rawValue)
                        Text("已归档").tag(StatusFilter.archived.rawValue)
                    }
                    Picker("项目", selection: $project) {
                        Text("全部项目").tag(String?.none)
                        ForEach(projects, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(project != nil || statusFilter != StatusFilter.all.rawValue ? Theme.accent : Theme.foreground)
                }
                .accessibilityLabel("分组和筛选")
                .help("分组和筛选")
            }
        }
        .task(id: query + "|" + model.connectionKey) {
            try? await Task.sleep(for: .milliseconds(250))
            await load()
        }
    }

    private func row(_ item: Item) -> some View {
        let host = model.host(item.serverId)
        let showProject = grouping != Grouping.project.rawValue
        return Button {
            Task { await open(item.serverId, item.agent) }
        } label: {
            HStack(spacing: 10) {
                if showProject, let host {
                    ProjectIcon(host: host, name: item.project, workspace: iconWorkspace(item, host: host), size: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.agent.displayTitle).lineLimit(1)
                    Text([showProject ? item.project : nil,
                          model.hosts.count > 1 ? host?.label : nil,
                          item.agent.updatedAt?.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                if item.agent.archivedAt != nil {
                    // 文字标签（同官方「已归档」徽标），比原来的小图标好找
                    ArchivedSessionBadge()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        #if os(iOS)
        // 不让尾部状态标签成为系统推断分隔线起点的依据。
        .alignmentGuide(.listRowSeparatorLeading) { _ in showProject && host != nil ? 26 : 0 }
        #endif
        .contextMenu {
            let ref = AgentRef(serverId: item.serverId, agentId: item.agent.id)
            Button("打开", systemImage: "arrow.up.forward.app") { Task { await open(item.serverId, item.agent) } }
            if item.agent.archivedAt != nil {
                Button("取消归档", systemImage: "tray.and.arrow.up") {
                    Task { await model.unarchiveAndRestore(ref, open: false); await load() }
                }
            } else if let host {
                Button("归档", systemImage: "archivebox", role: .destructive) {
                    Task { try? await host.archive(item.agent.id); model.offerUndoArchive(ref, title: item.agent.displayTitle); await load() }
                }
            }
        }
    }

    private func load() async {
        loading = true
        var all: [Item] = []
        var next: [String: String] = [:]
        for h in model.visibleHosts {
            guard let page = try? await h.fetchHistoryPage(search: query, cursor: nil) else { continue }
            all += items(page.agents, host: h)
            next[h.id] = page.nextCursor
        }
        results = sorted(all)
        cursors = next
        if let p = project, !results.contains(where: { $0.project == p }) { project = nil }
        loading = false
    }

    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        var more: [Item] = []
        var next: [String: String] = [:]
        for (id, cursor) in cursors {
            guard let h = model.host(id), let page = try? await h.fetchHistoryPage(search: query, cursor: cursor) else { continue }
            more += items(page.agents, host: h)
            next[id] = page.nextCursor
        }
        let seen = Set(results.map(\.id))
        results = sorted(results + more.filter { !seen.contains($0.id) })
        cursors = next
        loadingMore = false
    }

    /// Subagents (and helpers such as the title generator) live under their parent, not in the history;
    /// ones whose parent is gone or on another machine stay, like in the sidebar.
    private func items(_ agents: [Agent], host: HostStore) -> [Item] {
        let ids = Set(agents.map(\.id)).union(host.agents.keys)
        return agents.filter { a in
            guard let parent = a.parentAgentId, a.parentServerId == nil || a.parentServerId == host.id else { return true }
            return !ids.contains(parent)
        }
        .map { Item(serverId: host.id, agent: $0, project: model.projectName(of: $0, in: host)) }
    }

    /// One icon per project: the first workspace of it that is still known.
    private func iconWorkspace(_ item: Item, host: HostStore) -> Workspace? {
        results.lazy.filter { $0.serverId == item.serverId && $0.project == item.project }
            .compactMap { $0.agent.workspaceId.flatMap { host.workspaces[$0] } }.first
    }

    private func sorted(_ items: [Item]) -> [Item] {
        items.sorted { ($0.agent.updatedAt ?? .distantPast) > ($1.agent.updatedAt ?? .distantPast) }
    }

    private func open(_ serverId: String, _ agent: Agent) async {
        let ref = AgentRef(serverId: serverId, agentId: agent.id)
        if agent.archivedAt != nil { await model.unarchiveAndRestore(ref, open: true) } else { model.open(ref) }
    }
}

struct ComingSoonView: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            .navigationTitle(title)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Binding var showAddHost: Bool
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SettingsTabPicker(tab: $tab).padding(.top, 14)
            #endif
            // iOS: the picker sits in the navigation bar, on one line with 完成.
            if tab == 0 { PreferencesView(tabPicker: $tab) } else { HostsView(showAddHost: $showAddHost, tabPicker: $tab) }
        }
        .onAppear { tab = model.settingsTab; model.settingsTab = 0 }
        #if os(macOS)
        // Same size for both tabs, so switching doesn't make the sheet jump.
        .frame(width: 600, height: 640)
        #endif
    }
}

struct ArchivedSessionBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox")
            Text("已归档")
        }
        .font(.caption).foregroundStyle(Theme.muted)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(Theme.selection, in: Capsule())
        .fixedSize()
        .help("已归档，打开时恢复")
    }
}

struct SettingsTabPicker: View {
    @Binding var tab: Int

    var body: some View {
        Picker("", selection: $tab) {
            Text("通用").tag(0)
            Text("机器").tag(1)
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }
}

struct PreferencesView: View {
    var tabPicker: Binding<Int>? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sendBehavior", store: AppDefaults.store) private var sendBehavior = SendBehavior.steer.rawValue
    @AppStorage("notifications", store: AppDefaults.store) private var notifications = true
    @AppStorage("autoExpandReasoning", store: AppDefaults.store) private var autoExpandReasoning = true
    @AppStorage("timelineDetail", store: AppDefaults.store) private var timelineDetail = TimelineDetail.collapseTurns.rawValue
    @AppStorage("sendKey", store: AppDefaults.store) private var sendKey = "enter"
    @AppStorage("selectionAutoCopy", store: AppDefaults.store) private var selectionAutoCopy = true
    @AppStorage("restoreSessionReadingPosition", store: AppDefaults.store) private var restoreSessionReadingPosition = false

    /// Official defaultSend descriptions / commandEnterDescriptions (zh-CN).
    private var sendHint: String {
        let b = SendBehavior(rawValue: sendBehavior) ?? .steer
        // 整句翻译：动作词单独翻译再嵌进句子，英文大小写和语序都对不上
        if sendKey == "cmdEnter" && !isPhone {
            return switch b {
            case .interrupt: String(localized: "Agent 运行时，⌘+Enter 会中断。Enter 会插入换行。")
            case .steer: String(localized: "Agent 运行时，⌘+Enter 会引导当前回合。Enter 会插入换行。")
            case .queue: String(localized: "Agent 运行时，⌘+Enter 会排队。Enter 会插入换行。")
            }
        }
        return switch b {
        case .interrupt: String(localized: "Agent 运行时，Enter 会中断。⌘+Enter 会排队。")
        case .steer: String(localized: "Agent 运行时，Enter 会引导当前回合。⌘+Enter 会排队。")
        case .queue: String(localized: "Agent 运行时，Enter 会排队。⌘+Enter 会提交。")
        }
    }
    @AppStorage("appearance", store: AppDefaults.store) private var appearance = "system"
    @AppStorage("fontStep", store: AppDefaults.store) private var fontStep = 0
    @AppStorage("contentWidth", store: AppDefaults.store) private var contentWidth = 820
    @AppStorage("notifications.sound", store: AppDefaults.store) private var notificationSound = true
    @AppStorage("dockBadge", store: AppDefaults.store) private var dockBadge = true
    @AppStorage("menuBarExtra", store: AppDefaults.store) private var menuBarExtra = true
    @AppStorage("liveActivity", store: AppDefaults.store) private var liveActivity = true
    @AppStorage("terminal.fontSize", store: AppDefaults.store) private var terminalFontSize = 12.0
    @Environment(AppModel.self) private var model
    @State private var permission = String(localized: "检查中…")
    @State private var diagnostics: DiagnosticsFile?
    @State private var buildingDiagnostics = false

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .help("⌥⌘T 切换")
                    Picker("字号", selection: $fontStep) {
                        Text("小").tag(-1)
                        Text("标准").tag(0)
                        Text("大").tag(1)
                        Text("特大").tag(2)
                    }
                    Picker("聊天内容宽度", selection: $contentWidth) {
                        Text("窄").tag(680)
                        Text("标准").tag(820)
                        Text("宽").tag(1040)
                        Text("铺满").tag(0)
                    }
                }
                // Official settings → 通用 → 发送 (screens/settings/general/sending-section.tsx, zh-CN wording).
                Section {
                    // Only matters with a hardware keyboard: not on iPhone.
                    if !isPhone {
                        Picker("发送快捷键", selection: $sendKey) {
                            Text("Enter").tag("enter")
                            Text("⌘+Enter").tag("cmdEnter")
                        }
                    }
                    Picker("默认发送", selection: $sendBehavior) {
                        ForEach([SendBehavior.interrupt, .steer, .queue], id: \.self) { Text($0.shortLabel).tag($0.rawValue) }
                    }
                } header: {
                    Text("发送")
                } footer: {
                    Text(sendHint)
                }
                Section {
                    Picker("聊天显示", selection: $timelineDetail) {
                        ForEach(TimelineDetail.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("切回会话时", selection: $restoreSessionReadingPosition) {
                        Text("最新消息").tag(false)
                        Text("上次阅读位置").tag(true)
                    }
                    Toggle("自动展开思考过程", isOn: $autoExpandReasoning)
                    #if os(macOS)
                    Toggle("选中文字后自动拷贝", isOn: $selectionAutoCopy)
                    #endif
                } header: {
                    Text("聊天")
                } footer: {
                    Text("「折叠做完的回合」只留下你的消息和最后的回复，中间的思考和操作收成一行「用时 …」，点开可看；看过的图片仍显示缩略图。")
                }
                NextInputPreferencesSection()
                Section("通知") {
                    Toggle("会话完成、需要批准或出错时通知我", isOn: $notifications)
                        #if os(iOS)
                        .onChange(of: notifications) { LiveActivityController.shared.sync() }
                        #endif
                    Toggle("通知时播放声音", isOn: $notificationSound).disabled(!notifications)
                    #if os(macOS)
                    Toggle("Dock 图标显示待处理的会话数", isOn: $dockBadge)
                    Toggle("在菜单栏显示会话状态", isOn: $menuBarExtra)
                    #endif
                    #if os(iOS)
                    Toggle("在灵动岛和锁屏显示运行中的会话", isOn: $liveActivity)
                        .onChange(of: liveActivity) { LiveActivityController.shared.sync() }
                    #endif
                    HStack {
                        Text("系统通知权限：\(permission)").foregroundStyle(Theme.muted)
                        Spacer()
                        Button("发送测试通知") { NotificationManager.shared.test() }
                        #if os(macOS)
                        Button("打开系统设置") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(u) }
                        }
                        #endif
                    }
                }
                LiveActivityPushSection()
                Section {
                    Picker("终端字号", selection: $terminalFontSize) {
                        ForEach([10.0, 11, 12, 13, 14, 16], id: \.self) { Text("\(Int($0))").tag($0) }
                    }
                } header: {
                    Text("终端")
                } footer: {
                    Text("新打开的终端标签生效")
                }
                Section {
                    LabeledContent("Paseo 原生客户端", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                                   + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")")
                    #if os(macOS)
                    UpdateSettingsRows()
                    #endif
                    LabeledContent("对齐官方版本", value: "v0.15.2")
                    ForEach(model.hosts) { h in
                        LabeledContent(h.label, value: h.serverInfo?.version.map { "daemon v" + $0 } ?? String(localized: "未连接"))
                    }
                    HStack {
                        Button("导出诊断信息…") {
                            buildingDiagnostics = true
                            Task {
                                diagnostics = DiagnosticsFile(text: await DiagnosticsReport.build(model: model))
                                buildingDiagnostics = false
                            }
                        }
                        .disabled(buildingDiagnostics)
                        if buildingDiagnostics { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("自动检查更新会在启动、回到前台及运行期间查询 GitHub，自动检查至少间隔 30 分钟。只下载版本信息，不上传任何数据；有新版本时提示你下载，不会自动安装。\n遇到问题时导出，发给开发者分析。包含版本、各机器的连接、Provider 和插件状态、日志；不含对话内容，配对链接和密码会隐藏。")
                }
            }
            .formStyle(.grouped)
            .task { permission = await NotificationManager.shared.permissionLabel() }
            .fileExporter(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } }),
                          document: diagnostics, contentType: .plainText,
                          defaultFilename: "Paseo-诊断-" + Date().formatted(.iso8601.year().month().day()) + ".txt") { _ in diagnostics = nil }
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
    }
}

/// The diagnostics report as a file for the save dialog.
struct DiagnosticsFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
