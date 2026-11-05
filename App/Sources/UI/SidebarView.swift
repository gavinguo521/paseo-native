// Sidebar: title, search, host filter with destination icons, sessions under light project headers,
// floating Liquid Glass footer capsules.

import PaseoKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @Binding var showAddHost: Bool
    /// Collapsed sidebar groups, kept across launches (official sidebar remembers them too).
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed).sorted(), forKey: "sidebar.collapsed") }
    }
    @State private var expandedAll: Set<String> = []
    @State private var hoveredGroup: String?
    @State private var renamingWorkspace: Workspace?
    @State private var archivingWorkspace: Workspace?
    @State private var labelingWorkspace: Workspace?
    @State private var renamingAgent: AgentRef?
    @State private var newName = ""
    @State private var archivingAgent: AgentRef?
    @State private var sessionError: String?
    @State private var editingProject: ProjectEditTarget?
    /// A project group being removed from Paseo: its project on every machine it is on (official sidebar removes them all).
    @State private var removingProject: (name: String, targets: [ProjectEditTarget])?
    @State private var removeError: String?
    /// Comma-separated nav rows hidden from the sidebar (official sidebar navigation settings).
    @AppStorage("sidebar.hiddenNav") private var hiddenNavRaw = ""
    private var hiddenNav: Set<String> { Set(hiddenNavRaw.split(separator: ",").map(String.init)) }
    /// Holding ⌘ shows the ⌘1…9 targets (official row shortcut badges).
    @State private var commandHeld = false
    #if os(macOS)
    @State private var flagsMonitor: Any?
    #endif

    private static let rowsPerGroup = 8
    #if os(iOS)
    /// iPad: the sidebar has a toolbar row (sidebar toggle) — put the title there instead of a second row.
    /// By device, not size class: the sidebar column reports compact even on a full-screen iPad.
    private var titleInToolbar: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private let titleInToolbar = false
    #endif

    /// 和官方 Paseo 区分开：整体作为产品名，同字号同粗细。
    private func appTitle(size: CGFloat) -> some View {
        Text("Paseo Native").font(.system(size: size, weight: .bold)).lineLimit(1)
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !titleInToolbar {
                    appTitle(size: 26)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 14)
                }

                SearchCapsule(text: $model.search)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                filterBar.padding(.bottom, 2)

                if model.hosts.isEmpty {
                    emptyState
                }
                let groups = model.groups
                ForEach(groups) { group in
                    groupView(group)
                }
                if groups.isEmpty && !model.hosts.isEmpty && (!model.search.isEmpty || !model.labelFilter.isEmpty || model.hostFilter != nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("没有匹配的会话").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Button("清除搜索和筛选") { model.search = ""; model.labelFilter = []; model.hostFilter = nil }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(16)
                }
                Color.clear.frame(height: 96)
            }
        }
        .scrollIndicators(.never)
        .overlay(alignment: .bottom) { bottomBar }
        #if os(iOS)
        .toolbar {
            if titleInToolbar {
                ToolbarItem(placement: .topBarLeading) {
                    appTitle(size: 22).fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        #endif
        #if os(macOS)
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                let held = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                if held != commandHeld { commandHeld = held }
                return e
            }
        }
        .onDisappear { if let m = flagsMonitor { NSEvent.removeMonitor(m) } }
        .task {
            #if DEBUG
            // PASEO_HOVER_GROUP=1 shows the first group in its hover state, for screenshots.
            // PASEO_COLLAPSE_ALL=1 starts with every group collapsed.
            if ProcessInfo.processInfo.environment["PASEO_COLLAPSE_ALL"] == "1" {
                try? await Task.sleep(for: .seconds(4))
                collapsed = Set(model.groups.map(\.id))
            }
            // PASEO_DIAGNOSTICS_OUT=<path> writes the 「导出诊断信息」 report there once the machines have connected.
            if let path = ProcessInfo.processInfo.environment["PASEO_DIAGNOSTICS_OUT"] {
                try? await Task.sleep(for: .seconds(10))
                try? await DiagnosticsReport.build(model: model).write(toFile: path, atomically: true, encoding: .utf8)
            }
            if ProcessInfo.processInfo.environment["PASEO_HOVER_GROUP"] == "1" {
                try? await Task.sleep(for: .seconds(4))
                hoveredGroup = model.groups.first?.id
            }
            #endif
        }
        #endif
        .workspaceDialogs(renaming: $renamingWorkspace, archiving: $archivingWorkspace, labeling: $labelingWorkspace)
        .alert("重命名会话", isPresented: Binding(get: { renamingAgent != nil }, set: { if !$0 { renamingAgent = nil } })) {
            TextField("名字", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let r = renamingAgent, let h = model.host(r.serverId) { Task { try? await h.rename(r.agentId, to: newName) } }
            }
        }
        .confirmationDialog("归档这个会话？", isPresented: Binding(get: { archivingAgent != nil }, set: { if !$0 { archivingAgent = nil } })) {
            Button("归档", role: .destructive) {
                if let r = archivingAgent, let h = model.host(r.serverId) { Task { try? await h.archive(r.agentId) } }
            }
        } message: {
            Text(archivingAgent.flatMap { model.agent($0) }?.status == .running ? "它还在运行，归档会停止它。" : "归档后可以在会话历史里找回。")
        }
        .sheet(item: $editingProject) { t in ProjectEditSheet(host: t.host, project: t.project) }
        .alert("新建会话失败", isPresented: Binding(get: { sessionError != nil }, set: { if !$0 { sessionError = nil } })) {
            Button("好") {}
        } message: { Text(sessionError ?? "") }
        .confirmationDialog("从 Paseo 移除「\(removingProject?.name ?? "")」？", isPresented: Binding(get: { removingProject != nil }, set: { if !$0 { removingProject = nil } })) {
            Button("移除", role: .destructive) {
                guard let targets = removingProject?.targets else { return }
                Task {
                    for t in targets {
                        do { try await t.host.removeProject(t.project.id) } catch { removeError = t.host.label + "：\(error)" }
                    }
                }
            }
        } message: {
            let machines = removingProject?.targets.count ?? 0
            Text((machines > 1 ? String(localized: "会从 \(machines) 台机器上一起移除。") : "") + String(localized: "里面的工作区和会话会一起归档，正在运行的会被停止；磁盘上的文件不会删除。"))
        }
        .alert("移除项目失败", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("好") {}
        } message: { Text(removeError ?? "") }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack {
            Menu {
                Button { model.hostFilter = nil } label: { check(String(localized: "全部主机"), model.hostFilter == nil) }
                Divider()
                ForEach(model.hosts) { h in
                    Button { model.hostFilter = h.id } label: { check(h.label, model.hostFilter == h.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.hostFilter.flatMap { model.host($0)?.label } ?? String(localized: "全部主机"))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            if !hiddenNav.contains("history") { navIcon("clock.arrow.circlepath", String(localized: "会话历史"), .history) }
            if !hiddenNav.contains("schedules") { navIcon("calendar", String(localized: "计划任务"), .schedules) }
            if model.hasBoardPlugin && !hiddenNav.contains("board") { navIcon("rectangle.split.3x1", String(localized: "看板"), .board) }
            Menu {
                Picker("分组", selection: Binding(get: { model.grouping }, set: { model.grouping = $0 })) {
                    ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("排序", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    ForEach(SidebarSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Menu("侧栏显示") {
                    ForEach([("history", String(localized: "会话历史")), ("schedules", String(localized: "计划任务")), ("board", String(localized: "看板"))], id: \.0) { id, title in
                        Button { toggleNav(id) } label: { check(title, !hiddenNav.contains(id)) }
                    }
                }
                if !model.allLabels.isEmpty {
                    Section("按标签筛选") {
                        ForEach(model.allLabels) { l in
                            Button { toggleLabel(l.id) } label: { check(l.name, model.labelFilter.contains(l.id)) }
                        }
                        Button { toggleLabel("") } label: { check(String(localized: "无标签"), model.labelFilter.contains("")) }
                        if !model.labelFilter.isEmpty { Button("清除筛选") { model.labelFilter = [] } }
                    }
                }
            } label: {
                Image(systemName: model.labelFilter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .frame(width: 28, height: 28)
            .help("分组、排序和筛选")
            .accessibilityLabel("分组、排序和筛选")
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
        .padding(.leading, 16)
        .padding(.trailing, 10)
    }

    /// History, schedules and board as icons beside the filter (they used to be three full rows).
    private func navIcon(_ icon: String, _ title: String, _ destination: Destination) -> some View {
        let selected = model.destination == destination
        return Button {
            if destination == .board, case .agent(let r) = model.destination, let w = model.workspace(of: r) {
                model.boardWorkspace = WorkspaceRef(serverId: r.serverId, workspaceId: w.id)
            }
            model.destination = destination
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Theme.foreground : Theme.muted)
                .frame(width: 28, height: 28)
                .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func toggleNav(_ id: String) {
        var s = hiddenNav
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        hiddenNavRaw = s.sorted().joined(separator: ",")
    }

    private func toggleLabel(_ id: String) {
        if model.labelFilter.contains(id) { model.labelFilter.remove(id) } else { model.labelFilter.insert(id) }
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Groups

    @ViewBuilder private func groupView(_ group: SessionGroup) -> some View {
        let isCollapsed = collapsed.contains(group.id) && model.search.isEmpty
        // Not a Button: the 「+」 and 「⋯」 inside must stay separately clickable.
        Group {
            // Project icon and name; hovering swaps the icon for the collapse chevron and shows 「+」 and 「⋯」 (official sidebar).
            HStack(spacing: 8) {
                let hovered = hoveredGroup == group.id
                ZStack {
                    groupIcon(group).opacity(hovered ? 0 : 1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .opacity(hovered ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                Text(group.name).font(.system(size: Theme.base, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                if model.hosts.count > 1, !group.hostLabel.isEmpty {
                    if case .project = group.kind, let c = HostColor.color(for: group.serverId) { Circle().fill(c).frame(width: 6, height: 6) }
                    Text(group.hostLabel).font(.system(size: Theme.base - 2)).foregroundStyle(Theme.extraMuted).lineLimit(1)
                }
                Spacer(minLength: 4)
                // Touch screens have no hover: show 「+」「⋯」 all the time instead of hiding them behind it.
                #if os(macOS)
                let showActions = hovered
                #else
                let showActions = true
                #endif
                if showActions {
                    let targets = sessionTargets(group)
                    if targets.count > 1 {
                        // The project is on several machines: pick where the session runs.
                        Menu {
                            Section("在哪台机器上新建工作区") {
                                ForEach(targets, id: \.host.id) { t in Button(t.host.label) { start(t) } }
                            }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("在此项目新建工作区")
                        .accessibilityLabel("在此项目新建工作区，选择机器")
                    } else if let t = targets.first {
                        Button { start(t) } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("在此项目新建工作区")
                        .accessibilityLabel("在此项目新建工作区")
                    }
                    Menu { groupMenu(group) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("分组操作")
                } else if isCollapsed && group.bucket != .done {
                    StatusDot(bucket: group.bucket)
                }
            }
            .foregroundStyle(Theme.muted)
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(hoveredGroup == group.id ? Theme.selection.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) {
                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            }
        }
        .onHover { hoveredGroup = $0 ? group.id : (hoveredGroup == group.id ? nil : hoveredGroup) }
        .contextMenu { groupMenu(group) }

        // A collapsed group still shows the session being viewed, so the selection never disappears (official 0.15 #8395).
        let current = group.rows.filter { isSelected($0.serverId, $0.agent) }
        let showAll = expandedAll.contains(group.id) || !model.search.isEmpty
        let visible = isCollapsed ? current : showAll ? group.rows : Array(group.rows.prefix(Self.rowsPerGroup))
        if !visible.isEmpty {
            ForEach(visible, id: \.agent.id) { row in
                let ref = AgentRef(serverId: row.serverId, agentId: row.agent.id)
                let workspace = model.workspace(of: ref)
                SessionRow(agent: row.agent, bucket: row.bucket, selected: isSelected(row.serverId, row.agent), workspace: workspace,
                           context: rowContext(group, row.agent, serverId: row.serverId),
                           shortcut: commandHeld ? shortcutNumber(ref) : nil) {
                    model.openRow(ref)
                }
                .contextMenu { rowMenu(row.agent, serverId: row.serverId, workspace: workspace) }
                #if os(iOS)
                .modifier(SwipeActions(
                    leading: row.bucket == .attention
                        ? SwipeAction(title: String(localized: "已读"), systemImage: "checkmark", tint: Theme.dotSuccess) {
                            if let workspace, let h = model.host(row.serverId) { Task { try? await h.markWorkspaceRead(workspace.id) } }
                            else { model.host(row.serverId)?.clearAttention(row.agent.id) }
                        }
                        : nil,
                    trailing: SwipeAction(title: String(localized: "归档"), systemImage: "archivebox", tint: Theme.destructive) {
                        if let workspace { archivingWorkspace = workspace } else { archivingAgent = ref }
                    }))
                #endif
            }
            if !isCollapsed && !showAll && group.agents.count > Self.rowsPerGroup {
                Button("显示其余 \(group.agents.count - Self.rowsPerGroup) 个") {
                    withAnimation(.snappy(duration: 0.2)) { _ = expandedAll.insert(group.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.leading, 40)
                .padding(.vertical, 6)
            }
        }
    }

    /// Project group header: new session (per machine when the project is on several), new worktree, copy path, collapse.
    @ViewBuilder private func groupMenu(_ group: SessionGroup) -> some View {
        if case .project = group.kind {
            let targets = sessionTargets(group)
            if targets.count > 1 {
                Menu("新建工作区", systemImage: "folder.badge.plus") {
                    ForEach(targets, id: \.host.id) { t in Button(t.host.label) { start(t) } }
                }
            } else if let t = targets.first {
                Button("新建工作区", systemImage: "folder.badge.plus") { start(t) }
            }
            if let w = group.workspace {
                let ref = WorkspaceRef(serverId: group.serverId, workspaceId: w.id)
                Button("新建 worktree 会话…", systemImage: "arrow.triangle.branch") { model.draftWorkspace = ref; model.destination = .newChat }
                Button("复制项目路径", systemImage: "doc.on.doc") { Pasteboard.copy(w.projectRootPath.isEmpty ? w.directory : w.projectRootPath) }
            } else if let project = group.project {
                Button("复制项目路径", systemImage: "doc.on.doc") { Pasteboard.copy(project.rootPath) }
            }
            if !targets.isEmpty { Divider() }
            // Name and icon live on each machine's own project.
            let editable: [ProjectEditTarget] = model.visibleHosts.compactMap { h in
                h.projects.values.first { model.groupName(h.id, $0.displayName) == group.name }.map { ProjectEditTarget(host: h, project: $0) }
            }
            if editable.count > 1 {
                Menu("编辑项目", systemImage: "pencil") {
                    ForEach(editable) { t in Button(String(localized: "\(t.host.label) 上的「\(t.project.displayName)」…")) { editingProject = t } }
                }
            } else if let t = editable.first {
                Button("编辑项目…", systemImage: "pencil") { editingProject = t }
            }
            // Same project under different names on different machines: merge by hand (kept in this app only).
            let others = model.groups.filter { g in
                if case .project = g.kind { return g.id != group.id } else { return false }
            }
            if !others.isEmpty {
                Menu("合并到…", systemImage: "arrow.triangle.merge") {
                    Section("把「\(group.name)」并入") {
                        ForEach(others) { g in
                            Button(g.hostLabel.isEmpty ? g.name : g.name + " · " + g.hostLabel) { model.mergeProject(group.name, into: g.name) }
                        }
                    }
                }
            }
            if model.projectAliases.values.contains(group.name) {
                Button("取消合并", systemImage: "arrow.triangle.branch") { model.unmergeProject(group.name) }
            }
            if !editable.isEmpty {
                Divider()
                Button("从 Paseo 移除项目…", systemImage: "folder.badge.minus", role: .destructive) {
                    removingProject = (group.name, editable)
                }
            }
            Divider()
        }
        Button(collapsed.contains(group.id) ? "展开" : "折叠") {
            if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
        }
        Button("全部折叠") { collapsed = Set(model.groups.map(\.id)) }
        Button("全部展开") { collapsed = [] }
    }

    /// Where a project group can start a session, one per machine: that machine's most recent workspace of the group,
    /// else its project of the same name (a workspace is opened in its main directory). The group's own machine first.
    private struct SessionTarget {
        let host: HostStore
        let workspace: Workspace?
        let project: Project?
    }

    private func sessionTargets(_ group: SessionGroup) -> [SessionTarget] {
        guard case .project = group.kind else { return [] }
        let hosts = model.visibleHosts.sorted { a, b in a.id == group.serverId && b.id != group.serverId }
        return hosts.compactMap { h in
            let workspace = group.rows.filter { $0.serverId == h.id }
                .compactMap { r in r.agent.workspaceId.flatMap { h.workspaces[$0] } }
                .max { ($0.activityAt ?? .distantPast) < ($1.activityAt ?? .distantPast) }
            let project = h.projects.values.first { model.groupName(h.id, $0.displayName) == group.name }
            guard workspace != nil || project != nil else { return nil }
            return SessionTarget(host: h, workspace: workspace, project: project)
        }
    }

    /// 「+」 on a project: a new workspace with its first session (official new-workspace screen). Adding a session to an
    /// existing workspace is the 「+」 in that workspace's tab bar.
    private func start(_ t: SessionTarget) {
        if let w = t.workspace {
            model.draftWorkspace = WorkspaceRef(serverId: t.host.id, workspaceId: w.id)
            model.destination = .newChat
        } else if let project = t.project {
            Task {
                do { try await model.startSession(in: project, host: t.host) } catch { sessionError = "\(error)" }
            }
        }
    }

    @ViewBuilder private func groupIcon(_ group: SessionGroup) -> some View {
        switch group.kind {
        case .project:
            if let host = model.host(group.serverId) { ProjectIcon(host: host, name: group.name, workspace: group.workspace, size: 16, project: group.project) }
        case .pinned: Image(systemName: "pin").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .status(let b):
            if b == .done { Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            else { StatusDot(bucket: b) }
        }
    }

    /// A workspace row is selected while any of its tabs is shown; a session without a workspace while it is shown.
    private func isSelected(_ serverId: String, _ agent: Agent) -> Bool {
        if let ws = agent.workspaceId { return model.currentWorkspace == WorkspaceRef(serverId: serverId, workspaceId: ws) }
        return model.destination == .agent(AgentRef(serverId: serverId, agentId: agent.id))
    }

    private func shortcutNumber(_ ref: AgentRef) -> Int? {
        model.orderedSessions.prefix(9).firstIndex(of: ref).map { $0 + 1 }
    }

    /// Project name under the title where the group does not already say it.
    private func rowContext(_ group: SessionGroup, _ agent: Agent, serverId: String) -> String? {
        if case .project = group.kind {
            // A project merged across machines says which machine each workspace is on.
            guard Set(group.rows.map(\.serverId)).count > 1 else { return nil }
            return model.host(serverId)?.label
        }
        guard let h = model.host(serverId) else { return nil }
        return model.projectName(of: agent, in: h) + (model.hosts.count > 1 ? " · " + h.label : "")
    }

    @ViewBuilder private func rowMenu(_ agent: Agent, serverId: String, workspace: Workspace?) -> some View {
        if let host = model.host(serverId) {
            let ref = AgentRef(serverId: serverId, agentId: agent.id)
            if let workspace {
                // The row is the workspace; its sessions are tabs, managed from the tab bar.
                Button("在此工作区新建会话", systemImage: "square.and.pencil") {
                    model.select(.draft(UUID().uuidString), in: WorkspaceRef(serverId: serverId, workspaceId: workspace.id))
                }
                WorkspaceMenuItems(host: host, workspace: workspace, renaming: $renamingWorkspace, archiving: $archivingWorkspace,
                                   labeling: $labelingWorkspace)
            } else {
                Button("重命名…", systemImage: "pencil") { newName = agent.displayTitle; renamingAgent = ref }
                Button("复制会话 ID", systemImage: "doc.on.doc") { Pasteboard.copy(agent.id) }
                Divider()
                Button("归档…", systemImage: "archivebox", role: .destructive) { archivingAgent = ref }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有机器").font(.system(size: 14, weight: .semibold))
            Text("在电脑上运行 paseo daemon pair，把配对链接粘贴进来。").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Button("添加机器") { showAddHost = true }.buttonStyle(.glassProminent).tint(Theme.accent)
        }
        .padding(16)
    }

    // MARK: Bottom bar

    private var bottomBar: some View { buttons }

    /// Footer actions as floating Liquid Glass capsules: add project / usage / machines on the left,
    /// help / settings on the right (same actions as the official footer, native look).
    private var buttons: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                HStack(spacing: 2) {
                    footerButton("folder.badge.plus", help: String(localized: "添加项目")) { NotificationCenter.default.post(name: .addProject, object: nil) }
                    UsageFooterButton { model.destination = .usage } fallback: {
                        footerButton("gauge.with.dots.needle.50percent", help: String(localized: "用量"), selected: model.destination == .usage) { model.destination = .usage }
                    }
                    machinesMenu
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: Capsule())
                Spacer()
                HStack(spacing: 2) {
                    helpMenu
                    footerButton("gearshape", help: String(localized: "设置（⌘,）")) { model.settingsTab = 0; showSettings = true }
                        .keyboardShortcut(",", modifiers: .command)
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.horizontal, 14)
            .bottomBarPlacement()
        }
    }

    private func footerButton(_ icon: String, help: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { footerIcon(icon, selected: selected) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }

    private func footerIcon(_ icon: String, selected: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(selected ? Theme.foreground : Theme.muted)
            .frame(width: 36, height: 36)
            .background(selected ? Theme.selection.opacity(0.8) : .clear, in: Circle())
            .contentShape(Circle())
    }

    /// Machines: status of each, filter the sidebar to one, add or manage them.
    private var machinesMenu: some View {
        Menu {
            Section("机器") {
                ForEach(model.hosts) { h in
                    Button { model.hostFilter = model.hostFilter == h.id ? nil : h.id } label: {
                        Label(h.label + "　" + (h.latencyText ?? h.state.label), systemImage: model.hostFilter == h.id ? "checkmark" : h.state == .connected ? "circle.fill" : "circle")
                    }
                }
                if model.hostFilter != nil { Button("显示全部机器") { model.hostFilter = nil } }
            }
            Divider()
            Button("添加机器…", systemImage: "plus") { showAddHost = true }
            Button("管理机器…", systemImage: "server.rack") { model.settingsTab = 1; showSettings = true }
        } label: { footerIcon("server.rack", selected: model.hostFilter != nil) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("机器")
            .accessibilityLabel("机器")
    }

    private var helpMenu: some View {
        Menu {
            Button("键盘快捷键", systemImage: "keyboard") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
            Button("命令面板", systemImage: "command") { NotificationCenter.default.post(name: .openCommandPalette, object: nil) }
            Divider()
            Button("关于 / 版本信息", systemImage: "info.circle") { model.settingsTab = 0; showSettings = true }
            Link(destination: URL(string: "https://paseo.sh")!) { Label("Paseo 官网", systemImage: "safari") }
        } label: { footerIcon("questionmark.circle") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("帮助")
            .accessibilityLabel("帮助")
    }
}

struct SearchCapsule: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("搜索会话", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.extraMuted) }.buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassEffect(.regular, in: Capsule())
    }
}

private struct SessionRow: View {
    let agent: Agent
    /// Most urgent status among the workspace's sessions.
    let bucket: StatusBucket
    let selected: Bool
    var workspace: Workspace? = nil
    /// Secondary line (project) when the group is not a project.
    var context: String? = nil
    var shortcut: Int? = nil
    let action: () -> Void

    private var pullRequest: PullRequestInfo? { workspace?.pullRequest }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone: the change counts and PR number go on a second line instead of cutting the title short.
    private var badgesBelow: Bool { sizeClass == .compact }
    #else
    private let badgesBelow = false
    #endif
    /// The workspace's title (official sidebar), else the session's.
    private var title: String { workspace?.title.flatMap { $0.isEmpty ? nil : $0 } ?? agent.displayTitle }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Status sits in front of the title, in the indent under the project icon.
                StatusDot(bucket: bucket).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        // One step above the official base size (users found the list small).
                        .font(.system(size: Theme.base + 1, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                    if let context {
                        Text(context).font(.system(size: Theme.base - 2)).foregroundStyle(Theme.extraMuted).lineLimit(1)
                    }
                    if badgesBelow, hasBadges { HStack(spacing: 8) { badges } }
                }
                Spacer(minLength: 6)
                if let shortcut {
                    Text("⌘\(shortcut)").font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Theme.muted)
                }
                if !badgesBelow { badges }
                trailing
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            // Touch: the system's 44pt row (34 was the Mac size, cramped and fiddly to hit on a phone).
            #if os(iOS)
            .frame(minHeight: 44)
            #else
            .frame(minHeight: 34)
            #endif
            .padding(.vertical, context == nil && !(badgesBelow && hasBadges) ? 0 : 3)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(hoverInfo)
    }

    private var hasBadges: Bool {
        let changed = workspace.map { ($0.additions ?? 0) + ($0.deletions ?? 0) > 0 } ?? false
        let pr = pullRequest.map { $0.number != nil && ($0.isOpen || $0.isMerged) } ?? false
        return changed || pr
    }

    /// Uncommitted change counts and the open / merged PR number.
    @ViewBuilder private var badges: some View {
        if let w = workspace, let add = w.additions, let del = w.deletions, add + del > 0 {
            HStack(spacing: 3) {
                Text("+\(add)").foregroundStyle(Theme.diffAdd)
                Text("−\(del)").foregroundStyle(Theme.diffRemove)
            }
            .font(.system(size: Theme.base - 2.5, design: .monospaced))
            .help(w.currentBranch.map { String(localized: "分支 \($0)") } ?? String(localized: "未提交的改动"))
        }
        if let pr = pullRequest, let n = pr.number, pr.isOpen || pr.isMerged {
            HStack(spacing: 3) {
                if pr.isOpen, pr.checksStatus != nil, pr.checksStatus != "none" { ChecksDot(status: pr.checksStatus) }
                Text("#\(n)").font(.system(size: Theme.base - 2, design: .monospaced))
            }
            .foregroundStyle(pr.isMerged ? SwiftUI.Color.purple : Theme.muted)
            .help(pr.title)
        }
    }

    /// Official hover card, as a tooltip: title, path, branch, PR and checks.
    private var hoverInfo: String {
        var lines = [title, agent.cwd]
        if let b = workspace?.currentBranch { lines.append(String(localized: "分支 \(b)")) }
        if let pr = workspace?.pullRequest {
            lines.append("PR " + (pr.number.map { "#\($0) " } ?? "") + pr.title)
            if !pr.checks.isEmpty {
                let failed = pr.checks.filter { $0.status == "failure" }.count, pending = pr.checks.filter { $0.status == "pending" }.count
                lines.append(String(localized: "检查：") + (failed > 0 ? String(localized: "\(failed) 项失败") : pending > 0 ? String(localized: "\(pending) 项进行中") : String(localized: "全部通过")))
            }
        }
        if let w = workspace, let a = w.additions, let d = w.deletions, a + d > 0 { lines.append(String(localized: "未提交 +\(a) −\(d)")) }
        return lines.joined(separator: "\n")
    }

    /// Right side: only how long a running session has been quiet; the status itself is in front.
    @ViewBuilder private var trailing: some View {
        if agent.bucket == .running {
            // Re-evaluated every minute: a running session that stopped reporting may be stuck.
            TimelineView(.everyMinute) { context in
                if let quiet = agent.quietMinutes(now: context.date) {
                    Text("\(quiet) 分钟").font(.system(size: 10.5)).foregroundStyle(Theme.dotWarning)
                        .help("运行中，但已经 \(quiet) 分钟没有新动静")
                }
            }
        }
    }
}

#if os(iOS)
struct SwipeAction {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

/// iPhone list swipes on the hand-drawn sidebar rows (List's swipeActions need a List):
/// drag to reveal the button, drag far to trigger it.
struct SwipeActions: ViewModifier {
    let leading: SwipeAction?
    let trailing: SwipeAction?
    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    private let reveal: CGFloat = 76
    private let trigger: CGFloat = 170

    func body(content: Content) -> some View {
        content
            // While open, a tap on the row closes it instead of opening the session. Only on the row itself
            // (it moves with it): covering the revealed button too swallowed its tap, so 归档 did nothing.
            .overlay { if settled != 0 { Color.clear.contentShape(Rectangle()).onTapGesture { close() } } }
            .offset(x: offset)
            .background(alignment: offset > 0 ? .leading : .trailing) {
                if let a = offset > 0 ? leading : offset < 0 ? trailing : nil {
                    Button {
                        close()
                        a.action()
                    } label: {
                        Label(a.title, systemImage: a.systemImage).labelStyle(.iconOnly)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(a.tint, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .frame(width: abs(offset))
                    .padding(.horizontal, 4)
                    .accessibilityLabel(a.title)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                        var x = settled + v.translation.width
                        if x > 0, leading == nil { x = 0 }
                        if x < 0, trailing == nil { x = 0 }
                        offset = x
                    }
                    .onEnded { _ in
                        let x = offset
                        if x <= -trigger, let t = trailing { close(); fire(t) }
                        else if x >= trigger, let l = leading { close(); fire(l) }
                        else {
                            let target: CGFloat = x < -reveal / 2 ? -reveal : x > reveal / 2 ? reveal : 0
                            withAnimation(.snappy(duration: 0.2)) { offset = target }
                            settled = target
                        }
                    }
            )
            .accessibilityActions {
                if let l = leading { Button(l.title, action: l.action) }
                if let t = trailing { Button(t.title, action: t.action) }
            }
            #if DEBUG
            // PASEO_SWIPE_DEMO=1: the first row starts swiped open (screenshots).
            .onAppear {
                if ProcessInfo.processInfo.environment["PASEO_SWIPE_DEMO"] == "1", !Self.demoShown, trailing != nil {
                    Self.demoShown = true
                    offset = -reveal; settled = -reveal
                }
            }
            #endif
    }

    #if DEBUG
    @MainActor private static var demoShown = false
    #endif

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
        settled = 0
    }

    private func fire(_ a: SwipeAction) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        a.action()
    }
}
#endif

extension Agent {
    /// Running sessions with no update for this long are flagged (sidebar, menu bar).
    static let quietThreshold: TimeInterval = 10 * 60

    /// Minutes since the last update of a running session, once past the threshold.
    func quietMinutes(now: Date = Date()) -> Int? {
        guard status == .running, let t = updatedAt, now.timeIntervalSince(t) > Self.quietThreshold else { return nil }
        return Int(now.timeIntervalSince(t) / 60)
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

/// A project's icon (its own image, from the daemon) or, like the official app, its initial on a muted
/// identity colour picked by hashing the project key.
struct ProjectIcon: View {
    let host: HostStore
    let name: String
    let workspace: Workspace?
    var size: CGFloat = 16
    /// For a project without workspaces: where its id, key and icon revision come from.
    var project: Project? = nil

    private var projectId: String? { workspace?.projectId ?? project?.id }
    private var revision: String? { workspace?.projectIconRevision ?? project?.iconRevision }

    // Official styles/identity-colors.ts, same order (the hash indexes into it).
    private static let colors: [UInt32] = [0x7a6aa8, 0x3d7ea6, 0x388068, 0xa4673a, 0xb05c80, 0x6a70b8, 0x368080, 0xb06260, 0x8f7838, 0x5179b0]

    /// Official createProjectViewKey: the project key, else JSON [serverId, projectId].
    private var viewKey: String {
        if let k = workspace?.projectKey ?? project?.projectKey, !k.isEmpty { return k }
        return "[\"\(host.id)\",\"\(projectId ?? name)\"]"
    }

    private var color: Color {
        var hash: UInt32 = 0
        for unit in viewKey.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        let rgb = Self.colors[Int(hash % UInt32(Self.colors.count))]
        return Color(red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }

    private var image: Image? {
        guard let id = projectId, let data = host.projectIcons[id]?.data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    var body: some View {
        Group {
            if let image {
                // Someone's logo: sized, never clipped (official project-icon-view.tsx).
                image.resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: (size * 0.25).rounded())
                    .fill(color)
                    .overlay {
                        Text(String(name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"))
                            .font(.system(size: size * 0.62, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .task(id: (projectId ?? "") + (revision ?? "")) {
            if let projectId { await host.loadProjectIcon(projectId: projectId, revision: revision) }
        }
    }
}
