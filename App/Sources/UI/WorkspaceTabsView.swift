// Workspace with tabs: agents, terminals, changes, files and new-agent drafts.
// Official: screens/workspace/workspace-desktop-tabs-row.tsx, workspace-new-tab-menu.tsx, workspace-tab-menu.ts
// (no split panes yet). Closing a top-level agent tab archives it, like the official close policy.

import PaseoKit
import SwiftUI
import WebKit

struct WorkspaceTabsView: View {
    @Environment(AppModel.self) private var model
    let host: HostStore
    let ref: WorkspaceRef
    @State private var pendingClose: [WorkspaceTab] = []
    @State private var showScripts = false
    @AppStorage("explorer.visible") private var explorerVisible = false
    @AppStorage("explorer.tab") private var explorerTab = "changes"
    @AppStorage("explorer.width") private var explorerWidth: Double = 360
    @State private var error: String?
    @State private var showSetupLog = false
    @State private var askingURL = false
    @State private var urlText = ""
    @State private var renamingTerminal: String?
    @State private var terminalName = ""
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// iPhone, iPad split view / Slide Over: no room for the explorer beside the chat.
    @State private var explorerSheet = false
    /// Width of this view (= the window on iPhone), to size the title menu in the toolbar.
    @State private var viewWidth: CGFloat = 0
    private var narrow: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// Wide: the column beside the chat. Narrow: a bottom sheet (its own flag, so going narrow never pops it up).
    private func toggleExplorer() {
        if narrow { explorerSheet.toggle() } else { withAnimation { explorerVisible.toggle() } }
    }

    private func showExplorer() {
        if narrow { explorerSheet = true } else { explorerVisible = true }
    }

    private var workspace: Workspace? { host.workspaces[ref.workspaceId] }
    private var selectedIsAgent: Bool { if case .agent = selected { true } else { false } }
    private var tabs: [WorkspaceTab] { model.tabs(ref) }
    private var selected: WorkspaceTab? { model.selectedTab(ref) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                setupBanner
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: narrow ? nil : 380)
            if explorerVisible, !narrow, let workspace {
                ResizeHandle(width: $explorerWidth)
                explorer(workspace).frame(width: explorerWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .task(id: host.state == .connected) {
            if host.state == .connected, let workspace {
                await host.subscribeTerminals(workspace: workspace)
                if workspace.kind == "worktree" { await host.subscribeSetup(workspaceId: workspace.id) }
            }
        }
        .sheet(isPresented: $explorerSheet) {
            if let workspace {
                explorer(workspace).presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showSetupLog) {
            if let s = host.setupStatus[ref.workspaceId] { SetupLogSheet(setup: s) }
        }
        // Tabs live in the window toolbar (like Safari's compact tabs); the window title would only repeat the selected tab.
        .toolbar {
            // iPhone: the title slot (spans the room between the buttons); wider: the tab strip on the leading side.
            ToolbarItem(placement: narrow ? .principal : .navigation) { tabArea }
            .compatibleSharedBackgroundHidden()
            // Older systems use the standard placement of principal and primary-action items.
            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            if narrow {
                // iPhone: room for one button only. A session tab puts 右栏 / 脚本 into its own 「⋯」 menu;
                // other tabs get this one. More buttons than fit end up in iOS's overflow 「⋯」, menu inside menu.
                if !selectedIsAgent {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("改动与文件", systemImage: "sidebar.right") { toggleExplorer() }
                            Button(scriptTrouble ? "脚本（有异常）" : "脚本", systemImage: "play.rectangle") { showScripts = true }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("工作区操作")
                    }
                }
            } else {
            ToolbarItem(placement: .primaryAction) {
                Button { toggleExplorer() } label: { Image(systemName: "sidebar.right") }
                    .help(explorerVisible ? "隐藏右栏（⌘E）" : "显示改动与文件（⌘E）")
                    .accessibilityLabel(explorerVisible ? "隐藏右栏" : "显示改动与文件")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showScripts = true } label: {
                    Image(systemName: "play.rectangle")
                        .overlay(alignment: .topTrailing) {
                            if scriptTrouble { Circle().fill(Theme.destructive).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                        }
                }
                    .help(scriptTrouble ? "脚本：有服务异常或退出出错" : "脚本")
                    .accessibilityLabel(scriptTrouble ? "脚本：有服务异常或退出出错" : "脚本")
                    .popover(isPresented: Binding(get: { showScripts && !narrow }, set: { if !$0 { showScripts = false } }),
                             arrowEdge: .bottom) { scriptsPanel }
            }
            // Panels (explorer, scripts) | this view (outline, more).
            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            }
        }
        // Narrow: no toolbar button to anchor a popover on, so a sheet.
        .sheet(isPresented: Binding(get: { showScripts && narrow }, set: { if !$0 { showScripts = false } })) { scriptsPanel }
        // The principal slot (iPhone title) only exists while the title area does.
        .if(!narrow) { $0.toolbar(removing: .title) }
        #if os(iOS)
        // Cover the navigation and status-bar safe areas while tab content scrolls underneath.
        .toolbarBackground(Theme.surface0, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        #endif
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { viewWidth = $0 }
        .confirmationDialog(closeTitle, isPresented: Binding(get: { !pendingClose.isEmpty }, set: { if !$0 { pendingClose = [] } })) {
            Button(closeButton, role: .destructive) { let t = pendingClose; pendingClose = []; close(t, confirmed: true) }
        } message: { Text(closeMessage) }
        .alert("打开网页", isPresented: $askingURL) {
            TextField("地址，例如 http://localhost:3000", text: $urlText)
            Button("取消", role: .cancel) {}
            Button("打开") {
                var u = urlText.trimmingCharacters(in: .whitespaces)
                if !u.contains("://") { u = "http://" + u }
                if URL(string: u) != nil { model.select(.browser(u), in: ref) }
            }
        }
        .alert("重命名终端", isPresented: Binding(get: { renamingTerminal != nil }, set: { if !$0 { renamingTerminal = nil } })) {
            TextField("名字", text: $terminalName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let id = renamingTerminal { Task { do { try await host.renameTerminal(id, title: terminalName) } catch { self.error = "\(error)" } } }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") {}
        } message: { Text(error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceTabCommand)) { n in
            guard model.currentWorkspace == ref, let command = n.object as? WorkspaceTabCommand else { return }
            perform(command)
        }
        .task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { applyDebugTab() } }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch selected {
        case .agent(let id):
            AgentDetailView(host: host, ref: AgentRef(serverId: ref.serverId, agentId: id)).id(id)
        case .terminal(let id):
            TerminalHost(host: host, terminalId: id).id(id)
                .navigationTitle(title(.terminal(id)))
                .modifier(WorkspaceSubtitle(host: host, workspace: workspace))
        case .changes:
            if let workspace {
                ChangesView(host: host, workspace: workspace)
                    .navigationTitle("改动").modifier(WorkspaceSubtitle(host: host, workspace: workspace))
            }
        case .files:
            if let workspace {
                FilesView(host: host, workspace: workspace)
                    .navigationTitle("文件").modifier(WorkspaceSubtitle(host: host, workspace: workspace))
            }
        case .browser(let url):
            BrowserTab(initialURL: url) { newURL in
                if let i = tabs.firstIndex(of: .browser(url)), newURL != url { model.removeTab(.browser(url), in: ref, replacement: .browser(newURL)); _ = i }
            }
            .id(url)
            .navigationTitle(URL(string: url)?.host() ?? String(localized: "浏览器")).modifier(WorkspaceSubtitle(host: host, workspace: workspace))
        case .file(let path):
            FileViewer(host: host, cwd: (path as NSString).deletingLastPathComponent, path: (path as NSString).lastPathComponent,
                       line: model.fileLines[path])
                .id(path + ":" + String(model.fileLines[path] ?? 0))
                .navigationTitle((path as NSString).lastPathComponent).modifier(WorkspaceSubtitle(host: host, workspace: workspace))
        case .subagent(let parent, let id):
            ProviderSubagentTab(host: host, workspace: workspace, parentAgentId: parent, subagentId: id)
                .id(parent + "/" + id)
        case .draft(let id):
            if let workspace {
                DraftTabView(host: host, workspace: workspace, onCreated: { agentId in
                    model.removeTab(.draft(id), in: ref, replacement: .agent(agentId))
                }, onTerminal: { terminalId in
                    model.removeTab(.draft(id), in: ref, replacement: .terminal(terminalId))
                })
                .id(id)
                .navigationTitle("新会话").modifier(WorkspaceSubtitle(host: host, workspace: workspace))
            }
        case nil:
            ContentUnavailableView {
                Label("没有打开的标签", systemImage: "rectangle.stack")
            } actions: {
                Button("新会话") { perform(.newAgent) }.compatibleGlassButtonStyle(prominent: true).tint(Theme.accent)
            }
            .navigationTitle(workspace?.name ?? String(localized: "工作区"))
        }
    }

    /// Worktree setup commands (official Setup panel), shown until they succeed.
    @ViewBuilder private var setupBanner: some View {
        if let s = host.setupStatus[ref.workspaceId], s.status != "completed" {
            let done = s.commands.filter { $0.status == "completed" }.count
            HStack(spacing: 8) {
                if s.status == "running" { ProgressView().controlSize(.small) }
                else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(s.status == "failed" ? Theme.destructive : Theme.dotWarning) }
                Text(s.status == "running" ? String(localized: "正在初始化 worktree（\(done)/\(max(s.commands.count, 1))）")
                     : s.status == "blocked" ? String(localized: "worktree 初始化被拦下，需要你确认后手动运行")
                     : (s.error.map { String(localized: "worktree 初始化失败：\($0)") } ?? String(localized: "worktree 初始化失败")))
                    .font(.system(size: 12)).lineLimit(1)
                Spacer()
                Button("查看日志") { showSetupLog = true }.controlSize(.small)
                if s.status != "running" {
                    Button("重新运行") { Task { do { try await host.rerunSetup(workspaceId: ref.workspaceId) } catch { self.error = "\(error)" } } }
                        .controlSize(.small).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.surface1)
            Divider()
        }
    }

    /// A service is unhealthy or a script exited with an error.
    private var scriptTrouble: Bool {
        (host.scripts[ref.workspaceId] ?? []).contains { $0.health == "unhealthy" || (!$0.isRunning && ($0.exitCode ?? 0) != 0) }
    }

    // MARK: Explorer

    @ViewBuilder private var scriptsPanel: some View {
        if let workspace {
            ScriptsView(host: host, workspace: workspace, openLog: { id in
                showScripts = false
                model.select(.terminal(id), in: ref)
            }, openInTab: { url in
                showScripts = false
                model.select(.browser(url), in: ref)
            })
            .pickerSheet(width: 420, height: 360)
        }
    }

    /// Changes and files beside the chat. Official: screens/workspace/explorer-sidebar.tsx.
    private func explorer(_ workspace: Workspace) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $explorerTab) {
                Text("改动").tag("changes")
                Text("文件").tag("files")
                Text("大纲").tag("outline")
                if workspace.pullRequest != nil { Text("PR").tag("pr") }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).frame(height: 42)
            Divider()
            if explorerTab == "files" {
                FilesView(host: host, workspace: workspace, compact: true)
            } else if explorerTab == "pr", let pr = workspace.pullRequest {
                PRPanel(host: host, workspace: workspace, pr: host.prStatus[workspace.directory]?.pullRequest ?? pr)
            } else if explorerTab == "outline" {
                OutlineColumn(host: host, agentId: { if case .agent(let id) = selected { id } else { nil } }())
            } else {
                ChangesView(host: host, workspace: workspace, compact: true)
            }
        }
        .background(Theme.surface0)
    }

    // MARK: Tab bar

    /// Mac and iPad: the tab strip; iPhone has no room for it, so one "current tab ▾" menu.
    @ViewBuilder private var tabArea: some View {
        #if os(iOS)
        if sizeClass == .compact {
            tabSwitcher
        } else {
            // "+" outside the strip, so it never scrolls or gets clipped away.
            HStack(spacing: 4) {
                tabBar(includeNew: false).frame(minWidth: 220, idealWidth: 460, maxWidth: 460)
                newTabMenu
            }
        }
        #else
        tabBar(includeNew: true).frame(minWidth: 200, idealWidth: 560, maxWidth: 560)
        #endif
    }

    private var tabSwitcher: some View {
        Menu {
            // Inline picker: every row gets its icon and the system checkmark, so titles line up.
            Picker("标签", selection: Binding(get: { selected }, set: { if let t = $0 { model.select(t, in: ref) } })) {
                ForEach(tabs, id: \.self) { tab in
                    Label(title(tab), systemImage: symbol(tab)).tag(Optional(tab))
                }
            }
            .pickerStyle(.inline)
            Section("新标签") { newTabItems }
            if let selected, let i = tabs.firstIndex(of: selected) {
                Section { Menu("这个标签") { menu(selected, index: i) } }
            }
        } label: {
            // iPhone: just the title (no tab count button, user's call: too much going on); tapping it still
            // switches tabs.
            compactTitle
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "\(headerTitle)，轻点切换标签"))
    }

    /// Workspace title, the same as its sidebar row; "project · machine" under it (official CompactWorkspaceHeader).
    private var headerTitle: String {
        if let t = workspace?.title, !t.isEmpty { return t }
        if case .agent(let id) = selected, let a = host.agents[id] { return a.displayTitle }
        return workspace?.name ?? String(localized: "工作区")
    }

    private var compactTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headerTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.foreground).lineLimit(1)
            let sub = [workspace?.projectDisplayName, host.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
        }
        // Left-aligned like the official header. The title slot shrinks to its content and centers it, and does not
        // clamp what is too wide (it then runs under the back button). So: the room between the back button (~72pt
        // with its gap) and the 「⋯」 button on the right (~44pt + margins), i.e. width − 150. Too wide to center
        // there, the bar slides it left against the back button, so short titles start on the left too.
        .frame(width: max(120, viewWidth - 150), alignment: .leading)
        .contentShape(Rectangle())
    }

    private func tabBar(includeNew: Bool) -> some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                            TabChip(icon: { icon(tab) }, title: title(tab), selected: tab == selected,
                                    onSelect: { model.select(tab, in: ref) }, onClose: { close([tab]) })
                                .contextMenu { menu(tab, index: i) }
                                .id(tab)
                                .draggable(TabDrag(index: i))
                                .dropDestination(for: TabDrag.self) { items, _ in
                                    guard let from = items.first?.index else { return false }
                                    model.moveTab(from: from, to: i, in: ref)
                                    return true
                                }
                        }
                        if includeNew { newTabMenu.padding(.leading, 2) }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selected) { _, t in if let t { withAnimation { proxy.scrollTo(t) } } }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var newTabMenu: some View {
        Menu {
            newTabItems
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Theme.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("新标签")
        .accessibilityLabel("新标签")
    }

    @ViewBuilder private var newTabItems: some View {
        Button { perform(.newAgent) } label: { Label("Agent", systemImage: "square.and.pencil") }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Button { perform(.newTerminal) } label: { Label("终端", systemImage: "apple.terminal") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        if !host.terminalProfiles.isEmpty {
            Menu {
                ForEach(Array(host.terminalProfiles.enumerated()), id: \.offset) { _, p in
                    Button(p["name"]?.stringValue ?? "") { newTerminal(profile: p) }
                }
            } label: { Label("终端配置", systemImage: "terminal") }
        }
        Button { perform(.changes) } label: { Label("改动", systemImage: "plusminus") }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        Button { perform(.files) } label: { Label("文件", systemImage: "folder") }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        Button { askBrowserURL() } label: { Label("浏览器…", systemImage: "globe") }
            .keyboardShortcut("b", modifiers: [.command, .shift])
    }

    @ViewBuilder private func menu(_ tab: WorkspaceTab, index: Int) -> some View {
        switch tab {
        case .agent(let id):
            Button("复制会话 ID", systemImage: "doc.on.doc") { Pasteboard.copy(id) }
            if let cmd = host.agents[id]?.resumeCommand {
                Button("复制恢复命令", systemImage: "terminal") { Pasteboard.copy(cmd) }
                    .help(cmd)
            }
            Button("重新加载", systemImage: "arrow.clockwise") { Task { try? await host.reload(id) } }
        case .terminal(let id):
            Button("重命名…", systemImage: "pencil") { terminalName = title(tab); renamingTerminal = id }
            Button("复制终端 ID", systemImage: "doc.on.doc") { Pasteboard.copy(id) }
        case .file(let path):
            Button("复制路径", systemImage: "doc.on.doc") { Pasteboard.copy(path) }
            if let w = workspace, path.hasPrefix(w.directory + "/"), let u = w.fileWebURL(String(path.dropFirst(w.directory.count + 1))) {
                Button("在网页上打开", systemImage: "safari") { openURL(u) }
            }
        case .browser(let url):
            Button("复制地址", systemImage: "doc.on.doc") { Pasteboard.copy(url) }
            if let u = URL(string: url) { Button("在系统浏览器打开", systemImage: "safari") { openURL(u) } }
        default:
            EmptyView()
        }
        Divider()
        Button("关闭左侧标签") { close(Array(tabs.prefix(index))) }.disabled(index == 0)
        Button("关闭右侧标签") { close(Array(tabs.dropFirst(index + 1))) }.disabled(index >= tabs.count - 1)
        Button("关闭其他标签") { close(tabs.filter { $0 != tab }) }.disabled(tabs.count < 2)
        Button(closeLabel(tab), role: .destructive) { close([tab]) }
    }

    private func closeLabel(_ tab: WorkspaceTab) -> String {
        if case .agent(let id) = tab, host.agents[id]?.isSubagent == false { return String(localized: "关闭并归档") }
        return String(localized: "关闭")
    }

    @ViewBuilder private func icon(_ tab: WorkspaceTab) -> some View {
        switch tab {
        case .agent(let id):
            if let a = host.agents[id], a.bucket != .done { StatusDot(bucket: a.bucket) }
            else { Image(systemName: "bubble.left") }
        case .terminal(let id):
            if host.terminals[ref.workspaceId]?.first(where: { $0.id == id })?.activity == "working" { ProgressView().controlSize(.mini) }
            else { Image(systemName: "apple.terminal") }
        case .changes: Image(systemName: "plusminus")
        case .files: Image(systemName: "folder")
        case .file: Image(systemName: "doc.text")
        case .browser: Image(systemName: "globe")
        case .draft: Image(systemName: "square.and.pencil")
        case .subagent(let parent, let id):
            switch providerSubagent(parent, id)?.status {
            case "running": ProgressView().controlSize(.mini)
            case "failed": Image(systemName: "xmark.circle").foregroundStyle(Theme.destructive)
            default: Image(systemName: "person.crop.square")
            }
        }
    }

    /// Plain SF Symbol per tab kind, for menus (they cannot show status dots or spinners).
    private func symbol(_ tab: WorkspaceTab) -> String {
        switch tab {
        case .agent: "bubble.left"
        case .terminal: "apple.terminal"
        case .changes: "plusminus"
        case .files: "folder"
        case .file: "doc.text"
        case .browser: "globe"
        case .draft: "square.and.pencil"
        case .subagent: "person.crop.square"
        }
    }

    private func title(_ tab: WorkspaceTab) -> String {
        switch tab {
        case .agent(let id): host.agents[id]?.displayTitle ?? String(localized: "会话")
        case .terminal(let id):
            host.terminals[ref.workspaceId]?.first { $0.id == id }.map { $0.title ?? $0.name } ?? String(localized: "终端")
        case .changes: String(localized: "改动")
        case .files: String(localized: "文件")
        case .file(let path): (path as NSString).lastPathComponent
        case .browser(let url): URL(string: url)?.host().map { h in URL(string: url)?.port.map { "\(h):\($0)" } ?? h } ?? String(localized: "浏览器")
        case .draft: String(localized: "新会话")
        case .subagent(let parent, let id): providerSubagent(parent, id)?.label ?? String(localized: "子代理")
        }
    }

    private func providerSubagent(_ parent: String, _ id: String) -> ProviderSubagent? {
        host.providerSubagents[parent]?.first { $0.id == id }
    }

    @Environment(\.openURL) private var openURL

    /// Prefills the first running service's address.
    private func askBrowserURL() {
        urlText = (host.scripts[ref.workspaceId] ?? []).first { $0.isRunning && !$0.urls.isEmpty }?.urls.first?.url ?? "http://localhost:3000"
        askingURL = true
    }

    // MARK: Actions

    private func perform(_ command: WorkspaceTabCommand) {
        switch command {
        case .newAgent: model.select(.draft(UUID().uuidString), in: ref)
        case .newTerminal: newTerminal()
        case .changes: model.select(.changes, in: ref)
        case .files: model.select(.files, in: ref)
        case .browser: askBrowserURL()
        case .closeCurrent: if let selected { close([selected]) }
        case .toggleExplorer: toggleExplorer()
        case .scripts: showScripts = true
        case .step(let d):
            guard let selected, let i = tabs.firstIndex(of: selected), !tabs.isEmpty else { return }
            model.select(tabs[(i + d + tabs.count) % tabs.count], in: ref)
        case .index(let n):
            if tabs.indices.contains(n) { model.select(tabs[n], in: ref) }
        }
    }

    /// A profile runs its command; `{{{prompt}}}` placeholders are dropped since there is no prompt here.
    private func newTerminal(profile: JSONValue? = nil) {
        guard let workspace else { return }
        Task {
            do {
                let t: TerminalInfo
                if let p = profile, let command = p["command"]?.stringValue {
                    let args = (p["args"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.contains("{{{prompt}}}") }
                    t = try await host.createTerminal(workspace: workspace, name: p["name"]?.stringValue, command: command, args: args)
                } else {
                    t = try await host.createTerminal(workspace: workspace)
                }
                model.select(.terminal(t.id), in: ref)
            } catch { self.error = "\(error)" }
        }
    }

    /// Top-level agents are archived and terminals killed, so those ask first (running agents, any terminal).
    private func close(_ list: [WorkspaceTab], confirmed: Bool = false) {
        guard !list.isEmpty else { return }
        if !confirmed {
            let needsConfirm = list.contains { tab in
                switch tab {
                case .terminal: true
                case .agent(let id): list.count > 1 ? host.agents[id]?.isSubagent == false : host.agents[id]?.status == .running
                default: false
                }
            }
            if needsConfirm { pendingClose = list; return }
        }
        for tab in list {
            switch tab {
            case .agent(let id) where host.agents[id]?.isSubagent == false && host.agents[id]?.archivedAt == nil:
                model.closingTabs.insert(tab)
                model.removeTab(tab, in: ref)
                Task {
                    do { try await host.archive(id) } catch { self.error = String(localized: "归档失败：\(error)") }
                    model.closingTabs.remove(tab)
                }
            case .terminal(let id):
                model.closingTabs.insert(tab)
                model.removeTab(tab, in: ref)
                Task {
                    do { try await host.killTerminal(id, workspaceId: ref.workspaceId) } catch { self.error = String(localized: "关闭终端失败：\(error)") }
                    model.closingTabs.remove(tab)
                }
            default:
                model.removeTab(tab, in: ref)
            }
        }
    }

    private var closeCounts: (agents: Int, terminals: Int) {
        var agents = 0, terminals = 0
        for tab in pendingClose {
            switch tab {
            case .agent(let id) where host.agents[id]?.isSubagent == false: agents += 1
            case .terminal: terminals += 1
            default: break
            }
        }
        return (agents, terminals)
    }

    private var closeTitle: String {
        let c = closeCounts
        if pendingClose.count == 1, c.terminals == 1 { return String(localized: "关闭这个终端？") }
        if pendingClose.count == 1, c.agents == 1 { return String(localized: "归档运行中的会话？") }
        return String(localized: "关闭 \(pendingClose.count) 个标签？")
    }

    private var closeButton: String { closeCounts.agents > 0 ? String(localized: "关闭并归档") : String(localized: "关闭") }

    private var closeMessage: String {
        let c = closeCounts
        var parts: [String] = []
        if c.agents > 0 { parts.append(String(localized: "归档 \(c.agents) 个会话（可在会话历史里找回）")) }
        if c.terminals > 0 { parts.append(String(localized: "结束 \(c.terminals) 个终端里运行的进程")) }
        return parts.isEmpty ? "" : String(localized: "将会\(parts.joined(separator: String(localized: "，", comment: "列举时的分隔符（逗号）")))。")
    }

    private func applyDebugTab() {
        #if DEBUG
        guard model.debugPane == "host" else { return }
        model.debugPane = nil
        switch model.debugHostTab {
        case "changes": model.select(.changes, in: ref)
        case "terminal": if let t = tabs.first(where: { if case .terminal = $0 { true } else { false } }) { model.select(t, in: ref) }
        case "scripts": showScripts = true
        case "draft": perform(.newAgent)
        case "browser": model.select(.browser(ProcessInfo.processInfo.environment["PASEO_DEBUG_URL"] ?? "https://example.com"), in: ref)
        case "explorer": showExplorer()
        case "file":
            if let w = workspace {
                let f = ProcessInfo.processInfo.environment["PASEO_DEBUG_FILE"] ?? "README.en.md"
                let line = Int(ProcessInfo.processInfo.environment["PASEO_DEBUG_LINE"] ?? "20") ?? 20
                model.openFile(f.hasPrefix("/") ? f : w.directory + "/" + f, line: line > 0 ? line : nil, in: ref)
            }
        case "newTerminal": perform(.newTerminal)
        case "subagent":
            if case .agent(let parent) = selected, let sub = host.providerSubagents(of: parent).first {
                model.openProviderSubagent(serverId: host.id, parentAgentId: parent, subagentId: sub.id)
            }
        default: model.select(.files, in: ref)
        }
        #endif
    }
}

/// Drag payload for reordering tabs within one workspace.
struct TabDrag: Codable, Transferable {
    let index: Int
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .data) }
}

enum WorkspaceTabCommand {
    case newAgent, newTerminal, changes, files, browser, closeCurrent, toggleExplorer, scripts
    case step(Int)
    case index(Int)
}

extension Notification.Name {
    static let workspaceTabCommand = Notification.Name("paseo.workspaceTabCommand")
}

/// PR conversation and checks beside the chat; failures and comments can be handed to the agent.
/// Official: PR panel (pull_request_timeline, forge check details).
private struct PRPanel: View {
    let host: HostStore
    let workspace: Workspace
    let pr: PullRequestInfo
    @State private var items: [PRTimelineItem]?
    @State private var error: String?
    @State private var expanded: String?
    @State private var details: [String: CheckDetails] = [:]
    @State private var detailError: [String: String] = [:]
    @State private var showResolved = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button { if let u = URL(string: pr.url) { openURL(u) } } label: {
                    Text((pr.number.map { "#\($0) " } ?? "") + pr.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Text("\(pr.headRefName) → \(pr.baseRefName)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                if !pr.checks.isEmpty { checks }
                Divider()
                conversation
            }
            .padding(14)
        }
        .task(id: pr.number) { await load() }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("检查").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.extraMuted)
            ForEach(pr.checks) { c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ChecksDot(status: c.status)
                        Text(c.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if let d = c.duration { Text(d).font(.system(size: 11)).foregroundStyle(Theme.extraMuted) }
                        if c.status == "failure" {
                            Button(expanded == c.id ? "收起" : "详情") { toggle(c) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        }
                    }
                    if expanded == c.id {
                        if let d = details[c.id] {
                            VStack(alignment: .leading, spacing: 4) {
                                if let t = d.title { Text(t).font(.system(size: 12, weight: .medium)) }
                                if !d.failedJobs.isEmpty { Text(String(localized: "失败的 job：\(d.failedJobs.joined(separator: String(localized: "、", comment: "列举时的分隔符（顿号）")))")).font(.system(size: 11)) }
                                ForEach(d.annotations.prefix(12), id: \.self) { a in
                                    Text([a.path.map { $0 + (a.line.map { ":\($0)" } ?? "") }, a.message].compactMap { $0 }.joined(separator: " "))
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(3)
                                }
                                if let s = d.summary, !s.isEmpty { Text(String(s.prefix(1200))).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(12) }
                                Button("添加到聊天", systemImage: "text.bubble") { NotificationCenter.default.post(name: .appendToComposer, object: d.asPrompt) }
                                    .controlSize(.small)
                            }
                            .padding(8).background(Theme.surface1, in: RoundedRectangle(cornerRadius: 8))
                        } else if let e = detailError[c.id] {
                            Text(e).font(.caption).foregroundStyle(Theme.destructive)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var conversation: some View {
        HStack {
            Text("评论").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.extraMuted)
            Spacer()
            Toggle("显示已解决", isOn: $showResolved).checkboxOnMac().font(.system(size: 11))
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                .accessibilityLabel("刷新评论")
        }
        if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
        else if let items {
            let shown = items.filter { showResolved || !$0.isResolved }
            if shown.isEmpty { Text("还没有评论").font(.caption).foregroundStyle(Theme.muted) }
            ForEach(shown) { item in commentCard(item) }
        } else { ProgressView().controlSize(.small) }
    }

    private func commentCard(_ item: PRTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.author).font(.system(size: 12, weight: .semibold))
                if item.kind == "review", let s = item.reviewState {
                    Text(s == "approved" ? "批准" : s == "changes_requested" ? "要求修改" : "评审")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(s == "approved" ? Theme.dotSuccess : s == "changes_requested" ? Theme.destructive : Theme.muted)
                }
                if item.isResolved { Text("已解决").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                if item.isOutdated { Text("已过时").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                Spacer()
                if let d = item.createdAt { Text(formatTimestamp(d)).font(.system(size: 10)).foregroundStyle(Theme.extraMuted) }
            }
            if let p = item.path {
                Text(p + (item.line.map { ":\($0)" } ?? "")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            if !item.body.isEmpty { MarkdownView(text: item.body) }
            HStack(spacing: 10) {
                Button("添加到聊天") { NotificationCenter.default.post(name: .appendToComposer, object: prompt(item)) }
                if let u = URL(string: item.url), !item.url.isEmpty { Button("在网页上看") { openURL(u) } }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
        }
        .padding(10)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
    }

    private func prompt(_ item: PRTimelineItem) -> String {
        var out = "PR 上 \(item.author) 的" + (item.kind == "review" ? "评审" : "评论")
        if let p = item.path { out += "（`" + p + (item.line.map { ":\($0)" } ?? "") + "`）" }
        return out + "：\n\n" + item.body + "\n\n请处理这条意见。"
    }

    private func toggle(_ c: PullRequestInfo.Check) {
        if expanded == c.id { expanded = nil; return }
        expanded = c.id
        guard details[c.id] == nil else { return }
        Task {
            do { details[c.id] = try await host.checkDetails(cwd: workspace.directory, pr: pr, check: c) }
            catch { detailError[c.id] = "\(error)" }
        }
    }

    private func load() async {
        do { items = try await host.prTimeline(cwd: workspace.directory, pr: pr); error = nil }
        catch { self.error = "\(error)" }
    }
}

/// The selected agent's prompts; click scrolls the chat there (official outline sidebar).
private struct OutlineColumn: View {
    let host: HostStore
    let agentId: String?

    var body: some View {
        if let agentId {
            let prompts = (host.timelines[agentId]?.rows ?? []).filter { $0.item.startsTurn }
            if prompts.isEmpty {
                ContentUnavailableView("还没有提问", systemImage: "list.bullet.indent")
            } else {
                List(prompts) { r in
                    Button {
                        NotificationCenter.default.post(name: .scrollToMessage, object: r.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text(r)).lineLimit(3).font(.system(size: 12))
                            if let t = r.timestamp { Text(formatTimestamp(t)).font(.system(size: 10)).foregroundStyle(Theme.extraMuted) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .task(id: agentId) { if host.timelines[agentId]?.hasOlder == true { await host.loadFullTimeline(agentId) } }
            }
        } else {
            ContentUnavailableView("选中一个会话标签后显示它的提问", systemImage: "list.bullet.indent")
        }
    }

    private func text(_ r: TimelineRow) -> String {
        switch r.item {
        case .userMessage(let t, _): t
        case .toolCall(_, _, _, _, _, let m): m?["text"]?.stringValue ?? ""
        default: ""
        }
    }
}

/// Web page tab: address bar, back/forward/reload. Official browser tab (without element picking).
private struct BrowserTab: View {
    let initialURL: String
    let onNavigate: (String) -> Void
    @State private var address = ""
    @State private var web = WebController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { web.view.goBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    .accessibilityLabel("后退")
                Button { web.view.goForward() } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                    .accessibilityLabel("前进")
                Button { web.view.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                    .accessibilityLabel("重新加载")
                TextField("地址", text: $address).textFieldStyle(.roundedBorder)
                    .onSubmit {
                        var u = address.trimmingCharacters(in: .whitespaces)
                        if !u.contains("://") { u = "http://" + u }
                        if let url = URL(string: u) { web.view.load(URLRequest(url: url)); onNavigate(u) }
                    }
            }
            .padding(8)
            Divider()
            WebContainer(controller: web)
        }
        .onAppear {
            address = initialURL
            if web.view.url == nil, let u = URL(string: initialURL) { web.view.load(URLRequest(url: u)) }
        }
    }
}

@MainActor @Observable
private final class WebController {
    let view = WKWebView()
}

#if os(macOS)
private struct WebContainer: NSViewRepresentable {
    let controller: WebController
    func makeNSView(context: Context) -> WKWebView { controller.view }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
private struct WebContainer: UIViewRepresentable {
    let controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.view }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

private struct SetupLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let setup: WorktreeSetup

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(setup.branchName.map { String(localized: "worktree 初始化 · \($0)") } ?? String(localized: "worktree 初始化")).font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(setup.commands) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: c.status == "completed" ? "checkmark.circle.fill" : c.status == "failed" ? "xmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(c.status == "completed" ? Theme.dotSuccess : c.status == "failed" ? Theme.destructive : Theme.muted)
                                    .accessibilityLabel(c.status == "completed" ? "完成" : c.status == "failed" ? "失败" : "未完成")
                                Text("$ " + c.command).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                if let ms = c.durationMs { Text(formatDuration(ms / 1000)).font(.caption).foregroundStyle(Theme.muted) }
                                if let code = c.exitCode, code != 0 { Text("退出码 \(code)").font(.caption).foregroundStyle(Theme.destructive) }
                            }
                            if !c.log.isEmpty { CodeBlock(code: String(c.log.suffix(8000))) }
                        }
                    }
                    if setup.commands.isEmpty && !setup.log.isEmpty { CodeBlock(code: String(setup.log.suffix(8000))) }
                    if let e = setup.error { Banner(level: "error", message: e) }
                }
                .padding(14)
            }
        }
        .macOnly { $0.frame(minWidth: 640, minHeight: 460) }
    }
}

/// Drag to resize the explorer column (it grows to the left).
private struct ResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    #if os(macOS)
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    #endif
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            let base = start ?? width
                            start = base
                            width = min(max(base - g.translation.width, 280), 720)
                        }
                        .onEnded { _ in start = nil })
            }
    }
}

private struct TabChip<Icon: View>: View {
    @ViewBuilder let icon: Icon
    let title: String
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false
    #if os(iOS)
    private static var maxTitleWidth: CGFloat { 140 }
    #else
    private static var maxTitleWidth: CGFloat { 180 }
    #endif

    var body: some View {
        HStack(spacing: 6) {
            icon.font(.system(size: 11)).frame(width: 14, height: 14)
            Text(title).lineLimit(1).frame(maxWidth: Self.maxTitleWidth, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(selected || hovering ? 1 : 0)
            .help("关闭标签")
            .accessibilityLabel("关闭标签")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(selected ? Theme.foreground : Theme.muted)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 30)
        .background(selected ? Theme.surface2 : (hovering ? Theme.surface2.opacity(0.5) : .clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// "project · machine" under the title, like the agent tab.
private struct WorkspaceSubtitle: ViewModifier {
    let host: HostStore
    let workspace: Workspace?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationSubtitle([workspace?.projectDisplayName, host.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        #else
        content
        #endif
    }
}

/// New agent in this workspace, composed inside a tab.
private struct DraftTabView: View {
    let host: HostStore
    let workspace: Workspace
    let onCreated: (String) -> Void
    /// Start a terminal (optionally a profile like `claude` or `codex`) instead of a chat.
    let onTerminal: (String) -> Void
    @State private var error: String?
    @State private var pending: PendingStart?

    var body: some View {
        VStack(spacing: 0) {
            if let pending {
                PendingStartView(pending: pending)
            } else {
                intro
            }
            DraftComposerView(host: host, workspace: workspace, onCreated: onCreated, onPending: { pending = $0 })
        }
        .background(Theme.surface0)
    }

    @ViewBuilder private var intro: some View {
        Spacer()
        Text("要做点什么？").font(.system(size: 26, weight: .semibold))
        Text(workspace.name.isEmpty ? workspace.directory : workspace.name)
            .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 6)
        Menu {
            Button("终端") { start(nil) }
            ForEach(Array(host.terminalProfiles.enumerated()), id: \.offset) { _, p in
                Button(p["name"]?.stringValue ?? "") { start(p) }
            }
        } label: {
            Label("或者直接开终端", systemImage: "apple.terminal").font(.system(size: 12))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Theme.muted)
        .padding(.top, 10)
        if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
        Spacer()
    }

    private func start(_ profile: JSONValue?) {
        Task {
            do {
                let t: TerminalInfo
                if let p = profile, let command = p["command"]?.stringValue {
                    let args = (p["args"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.contains("{{{prompt}}}") }
                    t = try await host.createTerminal(workspace: workspace, name: p["name"]?.stringValue, command: command, args: args)
                } else {
                    t = try await host.createTerminal(workspace: workspace)
                }
                onTerminal(t.id)
            } catch { self.error = "\(error)" }
        }
    }
}
