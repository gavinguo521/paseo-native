// New worktree "start from" picker, add-project flow, workspace actions menu.
// Official: screens/new-workspace-screen.tsx, components/add-project-flow.tsx, sidebar-workspace-menu.tsx.

import PaseoKit
import SwiftUI

/// Where a new chat runs inside a git project: the workspace itself, or a fresh worktree from a ref / PR.
struct WorktreeChoice: Equatable {
    var label: String
    var source: [String: JSONValue]
}

struct IsolationPicker: View {
    let host: HostStore
    let workspace: Workspace
    @Binding var choice: WorktreeChoice?
    /// Open the base-branch picker right away (fork into a new workspace).
    var pickOnAppear = false
    @State private var picking = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button { choice = nil } label: { if choice == nil { Label("在项目目录新建工作区", systemImage: "checkmark") } else { Text("在项目目录新建工作区") } }
                Button { picking = true } label: {
                    if choice != nil { Label("新建 worktree…", systemImage: "checkmark") } else { Text("新建 worktree…") }
                }
            } label: {
                Chip {
                    Image(systemName: choice == nil ? "folder" : "arrow.triangle.branch")
                    Text(choice.map { String(localized: "worktree · 从 \($0.label)") } ?? String(localized: "项目目录"))
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            StartFromPicker(host: host, workspace: workspace) { choice = $0; picking = false }
        }
        .task { if pickOnAppear && choice == nil { try? await Task.sleep(for: .milliseconds(300)); picking = true } }
    }
}

private struct StartFromPicker: View {
    let host: HostStore
    let workspace: Workspace
    let onPick: (WorktreeChoice) -> Void
    @State private var query = ""
    @State private var branches: [HostStore.BranchOption] = []
    @State private var prs: [HostStore.ChangeRequest] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("搜索分支或 PR", text: $query).textFieldStyle(.roundedBorder).padding(12)
            List {
                if !branches.isEmpty {
                    Section("分支") {
                        ForEach(branches) { b in
                            Button {
                                onPick(WorktreeChoice(label: b.label, source: base(["action": "branch-off", "refName": .string(b.refName)])))
                            } label: {
                                HStack { Image(systemName: "arrow.triangle.branch"); Text(b.label); Spacer(); Text(b.detail).foregroundStyle(Theme.muted) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !prs.isEmpty {
                    Section("Pull Request") {
                        ForEach(prs) { pr in
                            Button {
                                var checkout: [String: JSONValue] = ["kind": "change_request", "number": .number(Double(pr.number))]
                                if let f = pr.forge { checkout["forge"] = .string(f) }
                                if let p = pr.projectPath { checkout["projectPath"] = .string(p) }
                                var src = base(["action": "checkout", "refName": .string(pr.headRefName), "checkoutSource": .object(checkout)])
                                if pr.forge == "github" { src["githubPrNumber"] = .number(Double(pr.number)) }
                                onPick(WorktreeChoice(label: "#\(pr.number)", source: src))
                            } label: {
                                HStack { Text("#\(pr.number)").foregroundStyle(Theme.muted).monospacedDigit(); Text(pr.title).lineLimit(1) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .pickerSheet(width: 380, height: 420)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            async let b = host.branchSuggestions(cwd: workspace.directory, query: query)
            async let p = host.searchChangeRequests(cwd: workspace.directory, query: query)
            (branches, prs) = await (b, p)
        }
    }

    private func base(_ extra: [String: JSONValue]) -> [String: JSONValue] {
        var s: [String: JSONValue] = ["kind": "worktree", "cwd": .string(workspace.directory),
                                      "worktreeSlug": .string("paseo-" + String(UUID().uuidString.prefix(6)).lowercased())]
        if !workspace.projectId.isEmpty { s["projectId"] = .string(workspace.projectId) }
        return s.merging(extra) { $1 }
    }
}

// MARK: Add project

/// Add a project the way the official app does: machine → method (search a directory, choose in Finder,
/// clone from GitHub, new directory) → open a new chat in it. Native sheet with a back stack.
struct AddProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Page: Hashable {
        case host, method, directory, githubSearch, githubLocation(repo: String, name: String, proto: String?), newParent, newName(parent: String)
    }

    @State private var serverId: String?
    @State private var stack: [Page] = []
    @State private var query = ""
    @State private var suggestions: [String] = []
    /// Folders recent provider sessions ran in, on the method page.
    @State private var recentFolders: [ProjectSuggestion] = []
    @State private var loadingRecentFolders = false
    /// Clone targets found on the host (marked "已经存在").
    @State private var existingTargets: Set<String> = []
    @State private var repos: [HostStore.GitHubRepo] = []
    @State private var repoNote: String?
    @State private var newName = ""
    @State private var busy: String?
    @State private var error: String?
    /// Last parent used for cloning, per machine (official keeps it in memory too).
    @AppStorage("addProject.lastCloneParent", store: AppDefaults.store) private var lastCloneParent = ""

    private var host: HostStore? { serverId.flatMap { model.host($0) } }
    private var page: Page { stack.last ?? .host }
    private var onlineHosts: [HostStore] { model.hosts.filter { $0.state == .connected } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive).padding(10) }
        }
        .macOnly { $0.frame(width: 560, height: 520) }
        .onAppear(perform: start)
        .onChange(of: page) { query = ""; suggestions = []; error = nil }
        .task(id: "\(page)|\(query)") { await refresh() }
        .task(id: "\(serverId ?? "")|\(host?.providers.count ?? 0)") { await loadRecentFolders() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if stack.count > 1 {
                Button { stack.removeLast() } label: { Image(systemName: "chevron.left").mobileTouchTarget() }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("返回")
            }
            Text(title).font(.headline)
            if let host, page != .host { Text(host.label).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            Spacer()
            if let busy { ProgressView().controlSize(.small); Text(busy).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            Button { dismiss() } label: { Text("关闭").mobileTouchTarget() }
        }
        .padding(14)
    }

    private var title: String {
        switch page {
        case .host: String(localized: "选择机器")
        case .method: String(localized: "添加项目")
        case .directory: String(localized: "搜索目录")
        case .githubSearch: String(localized: "从 GitHub 克隆")
        case .githubLocation: String(localized: "克隆到哪里")
        case .newParent: String(localized: "选择父目录")
        case .newName: String(localized: "目录名")
        }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .host:
            if onlineHosts.isEmpty {
                ContentUnavailableView("没有在线的机器", systemImage: "server.rack")
            } else {
                List(onlineHosts) { h in
                    row(h.label, subtitle: h.serverInfo?.hostname, icon: "server.rack") { serverId = h.id; stack.append(.method) }
                }
            }
        case .method:
            List {
                row(String(localized: "搜索目录"), subtitle: String(localized: "在「\(host?.label ?? "")」上找一个已有的目录"), icon: "magnifyingglass") { stack.append(.directory) }
                #if os(macOS)
                if isLocalHost {
                    row(String(localized: "在访达中选择"), subtitle: String(localized: "用系统的文件夹选择器，也可以在里面新建文件夹"), icon: "folder") { browse() }
                }
                #endif
                row(String(localized: "从 GitHub 克隆"), subtitle: can("projectGithubClone") ? (can("workspaceGithubRepositorySearch") ? String(localized: "搜索你 GitHub 账号能访问的仓库") : String(localized: "填写 GitHub 地址或 owner/repo")) : String(localized: "先升级这台机器上的 Paseo"),
                    icon: "arrow.down.circle", disabled: !can("projectGithubClone")) { stack.append(.githubSearch) }
                row(String(localized: "新建目录"), subtitle: can("projectCreateDirectory") ? String(localized: "在「\(host?.label ?? "")」上建一个空目录") : String(localized: "先升级这台机器上的 Paseo"),
                    icon: "folder.badge.plus", disabled: !can("projectCreateDirectory")) { stack.append(.newParent) }
                if loadingRecentFolders || !recentFolders.isEmpty {
                    Section {
                        ForEach(recentFolders) { s in
                            row(s.displayName, subtitle: recentFolderSubtitle(s), icon: "clock.arrow.circlepath") { add(s.rootPath) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("最近用过的目录")
                            if loadingRecentFolders { ProgressView().controlSize(.mini) }
                        }
                    }
                }
            }
        case .directory:
            searchField(String(localized: "搜索目录或输入路径"))
            List {
                if isPath(query) { row(query, subtitle: String(localized: "打开这个路径"), icon: "arrow.right.circle") { add(query) } }
                ForEach(directoryCandidates, id: \.self) { p in row(abbreviate(p), subtitle: nil, icon: "folder") { add(p) } }
            }
        case .githubSearch:
            searchField(String(localized: "搜索或填写 GitHub 仓库（地址或 owner/repo）"))
            List {
                ForEach(manualRepoChoices, id: \.0) { label, repo, name, proto, sub in
                    row(label, subtitle: sub, icon: "link") { stack.append(.githubLocation(repo: repo, name: name, proto: proto)) }
                }
                ForEach(repos) { r in
                    row(r.nameWithOwner, subtitle: r.description, icon: r.isPrivate ? "lock" : "book.closed") {
                        stack.append(.githubLocation(repo: r.cloneUrl, name: r.name, proto: nil))
                    }
                }
                if let repoNote { Text(repoNote).font(.caption).foregroundStyle(Theme.muted) }
                if repos.isEmpty && manualRepoChoices.isEmpty && repoNote == nil {
                    Text("填写 GitHub 地址或 owner/repo").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        case .githubLocation(let repo, let name, let proto):
            searchField(String(localized: "搜索父目录或输入路径"))
            List {
                ForEach(parentCandidates, id: \.self) { parent in
                    let target = (parent as NSString).appendingPathComponent(name)
                    let exists = existingTargets.contains((target as NSString).standardizingPath)
                    row(abbreviate(target), subtitle: exists ? String(localized: "已经存在") : String(localized: "父目录：\(abbreviate(parent))"), icon: "folder", disabled: exists) {
                        clone(repo, proto: proto, parent: parent)
                    }
                }
            }
        case .newParent:
            searchField(String(localized: "搜索父目录或输入路径"))
            List {
                if isPath(query) { row(query, subtitle: String(localized: "用这个目录作父目录"), icon: "arrow.right.circle") { newName = ""; stack.append(.newName(parent: query)) } }
                ForEach(directoryCandidates, id: \.self) { p in
                    row(abbreviate(p), subtitle: nil, icon: "folder") { newName = ""; stack.append(.newName(parent: p)) }
                }
            }
        case .newName(let parent):
            VStack(alignment: .leading, spacing: 10) {
                TextField("目录名", text: $newName).textFieldStyle(.roundedBorder).onSubmit { create(parent) }
                Text(abbreviate((parent as NSString).appendingPathComponent(newName.isEmpty ? "…" : newName)))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                HStack { Spacer(); Button("新建") { create(parent) }.buttonStyle(.borderedProminent).disabled(!validName) }
            }
            .padding(14)
        }
    }

    private func searchField(_ prompt: String) -> some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(prompt, text: $query).textFieldStyle(.plain)
        }
        .padding(10)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14).padding(.top, 10)
    }

    private func row(_ title: String, subtitle: String?, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.extraMuted)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy != nil)
        .opacity(disabled ? 0.45 : 1)
    }

    // MARK: Data

    private func start() {
        let preferred = model.currentWorkspace?.serverId
        if let p = preferred, onlineHosts.contains(where: { $0.id == p }) { serverId = p; stack = [.method] }
        else if onlineHosts.count == 1 { serverId = onlineHosts[0].id; stack = [.method] }
        else { stack = [.host] }
    }

    private func can(_ feature: String) -> Bool { host?.serverInfo?.hasFeature(feature) == true }

    /// The daemon runs on this Mac when a known project directory exists here.
    private var isLocalHost: Bool {
        guard let host else { return false }
        return host.projects.values.contains { FileManager.default.fileExists(atPath: $0.rootPath) }
            || host.workspaces.values.contains { FileManager.default.fileExists(atPath: $0.directory) }
    }

    /// Existing project roots on this machine (official "recommended paths").
    private var recommended: [String] {
        guard let host else { return [] }
        let roots = Set(host.projects.values.map(\.rootPath) + host.workspaces.values.map(\.projectRootPath)).filter { !$0.isEmpty }
        return roots.sorted()
    }

    private var directoryCandidates: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rec = q.isEmpty ? recommended : recommended.filter { $0.lowercased().contains(q) || abbreviate($0).lowercased().contains(q) }
        var seen = Set<String>()
        return (rec + suggestions).filter { seen.insert($0).inserted }
    }

    private var parentCandidates: [String] {
        let home = host?.homeDirectory ?? "~"
        let fallback = ["dev", "Developer", "src", "projects", "workspace"].map { home + "/" + $0 } + [home]
        let parents = recommended.map { ($0 as NSString).deletingLastPathComponent }
        var base = (lastCloneParent.isEmpty ? [] : [lastCloneParent]) + parents + fallback
        let q = query.trimmingCharacters(in: .whitespaces)
        if isPath(q) { base.insert(expand(q), at: 0) }
        base += suggestions
        if !q.isEmpty && !isPath(q) { base = base.filter { $0.lowercased().contains(q.lowercased()) } }
        var seen = Set<String>()
        return base.filter { seen.insert(($0 as NSString).standardizingPath).inserted }
    }

    /// Typed URL or owner/repo turned into clone choices (official manual rows).
    private var manualRepoChoices: [(String, String, String, String?, String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        if q.contains("://") || q.hasPrefix("git@") {
            var name = (q as NSString).lastPathComponent
            if name.hasSuffix(".git") { name.removeLast(4) }
            guard !repos.contains(where: { $0.cloneUrl == q }) else { return [] }
            return [(q, q, name, nil, String(localized: "克隆这个仓库地址"))]
        }
        let parts = q.split(separator: "/")
        guard parts.count == 2, !repos.contains(where: { $0.nameWithOwner.lowercased() == q.lowercased() }) else { return [] }
        let name = String(parts[1])
        return [(String(localized: "\(q)（HTTPS）"), q, name, "https", String(localized: "用 HTTPS 克隆 \(q)")), (String(localized: "\(q)（SSH）"), q, name, "ssh", String(localized: "用 SSH 克隆 \(q)"))]
    }

    private func recentFolderSubtitle(_ s: ProjectSuggestion) -> String {
        [s.lastActivityAt?.formatted(.relative(presentation: .named)), abbreviate(s.rootPath)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Asks each enabled provider separately and shows rows as they answer; one that fails adds nothing.
    private func loadRecentFolders() async {
        recentFolders = []
        guard let host, can("projectSuggestions") else { return }
        let providers = host.providers.filter { $0["enabled"]?.boolValue != false }.compactMap { $0["provider"]?.stringValue }
        guard !providers.isEmpty else { return }
        loadingRecentFolders = true
        defer { loadingRecentFolders = false }
        var answers: [[ProjectSuggestion]] = []
        await withTaskGroup(of: [ProjectSuggestion].self) { group in
            for provider in providers {
                group.addTask { (try? await host.projectSuggestions(provider: provider)) ?? [] }
            }
            for await answer in group {
                answers.append(answer)
                recentFolders = ProjectSuggestion.merge(answers)
            }
        }
    }

    private func refresh() async {
        guard let host else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        switch page {
        case .directory, .newParent, .githubLocation:
            let q = query.trimmingCharacters(in: .whitespaces)
            if case .githubLocation(_, let name, _) = page, q.isEmpty {
                // Mark destinations that already exist: look each likely target up on the host.
                var found = Set<String>()
                suggestions = []
                for parent in parentCandidates.prefix(8) {
                    let target = ((parent as NSString).appendingPathComponent(name) as NSString).standardizingPath
                    let hits = await host.pathSuggestions(cwd: nil, query: target, includeFiles: false).filter(\.isDirectory)
                    if hits.contains(where: { ($0.path as NSString).standardizingPath == target }) { found.insert(target) }
                }
                existingTargets = found
                return
            }
            suggestions = q.isEmpty ? [] : await host.pathSuggestions(cwd: nil, query: q, includeFiles: false).filter(\.isDirectory).map(\.path)
        case .githubSearch:
            guard can("workspaceGithubRepositorySearch") else { repos = []; repoNote = nil; return }
            do { (repos, repoNote) = try await host.searchGitHubRepositories(query) }
            catch { repos = []; repoNote = String(localized: "搜索 GitHub 仓库失败：\(error)") }
        default: break
        }
    }

    private func isPath(_ s: String) -> Bool { s.hasPrefix("/") || s.hasPrefix("~") }

    private func expand(_ s: String) -> String {
        guard s.hasPrefix("~"), let home = host?.homeDirectory else { return s }
        return home + s.dropFirst()
    }

    private func abbreviate(_ path: String) -> String {
        guard let home = host?.homeDirectory, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private var validName: Bool {
        let n = newName.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != "." && n != ".." && !n.contains("/") && !n.contains("\\")
    }

    // MARK: Actions

    #if os(macOS)
    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "添加")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url.path)
    }
    #endif

    private func add(_ path: String) {
        run(String(localized: "正在添加项目…")) { try await $0.addProject(cwd: expand(path)) }
    }

    private func create(_ parent: String) {
        guard validName else { error = String(localized: "请输入目录名"); return }
        run(String(localized: "正在新建目录…")) { try await $0.createProjectDirectory(parent: expand(parent), name: newName.trimmingCharacters(in: .whitespaces)) }
    }

    private func clone(_ repo: String, proto: String?, parent: String) {
        lastCloneParent = parent
        run(String(localized: "正在克隆，可能要几分钟…")) { try await $0.cloneGitHubRepository(repo, protocol: proto, parent: expand(parent)) }
    }

    /// Runs the step, then opens a new chat in the project (official: new-workspace page for it).
    private func run(_ label: String, _ work: @escaping (HostStore) async throws -> Project?) {
        guard let host else { return }
        busy = label
        error = nil
        Task {
            do {
                let project = try await work(host)
                guard let project else { throw HostStore.ActionError.rejected(String(localized: "没有拿到项目信息")) }
                let existing = host.workspaces.values.first { $0.projectId == project.id && $0.directory == project.rootPath }
                var wsId = existing?.id
                if wsId == nil {
                    (wsId, _) = try await host.createWorkspace(source: ["kind": "directory", "path": .string(project.rootPath), "projectId": .string(project.id)])
                }
                if let wsId { model.draftWorkspace = WorkspaceRef(serverId: host.id, workspaceId: wsId) }
                model.destination = .newChat
                dismiss()
            } catch { self.error = "\(error)" }
            busy = nil
        }
    }
}

// MARK: Workspace actions

struct WorkspaceMenuItems: View {
    let host: HostStore
    let workspace: Workspace
    @Binding var renaming: Workspace?
    @Binding var archiving: Workspace?
    var labeling: Binding<Workspace?>? = nil

    var body: some View {
        Button("复制路径", systemImage: "doc.on.doc") { Pasteboard.copy(workspace.directory) }
        if let u = workspace.branchWebURL { Link(destination: u) { Label("在网页上打开分支", systemImage: "safari") } }
        #if os(macOS)
        // Only when the daemon runs on this Mac (the directory exists here).
        if FileManager.default.fileExists(atPath: workspace.directory) {
            Button("在 Finder 中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.directory)])
            }
            let editors = LocalEditors.installed
            if !editors.isEmpty {
                Menu("在编辑器中打开", systemImage: "chevron.left.forwardslash.chevron.right") {
                    ForEach(editors, id: \.url) { e in
                        Button(e.name) {
                            NSWorkspace.shared.open([URL(fileURLWithPath: workspace.directory)], withApplicationAt: e.url,
                                                    configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
        }
        #endif
        if let b = workspace.currentBranch { Button("复制分支名", systemImage: "arrow.triangle.branch") { Pasteboard.copy(b) } }
        Button("重命名…", systemImage: "pencil") { renaming = workspace }
        Button("导入外部会话…", systemImage: "square.and.arrow.down") {
            NotificationCenter.default.post(name: .importSessions, object: WorkspaceRef(serverId: host.id, workspaceId: workspace.id))
        }
        if workspace.status == .attention || workspace.status == .failed {
            Button("标为已读", systemImage: "envelope.open") { Task { try? await host.markWorkspaceRead(workspace.id) } }
        }
        if workspace.status == .done, host.serverInfo?.hasFeature("workspaceMarkUnread") == true {
            Button("标为未读", systemImage: "envelope.badge") { Task { try? await host.markWorkspaceUnread(workspace.id) } }
        }
        Button(workspace.pinnedAt == nil ? "置顶" : "取消置顶", systemImage: "pin") {
            Task { try? await host.pinWorkspace(workspace.id, pinned: workspace.pinnedAt == nil) }
        }
        if host.serverInfo?.hasFeature("workspaceLabels") == true {
            Menu("标签", systemImage: "tag") {
                ForEach(host.labels.sorted { $0.name < $1.name }) { l in
                    let on = workspace.labels.contains { $0.lowercased() == l.name.lowercased() }
                    Button { Task { try? await host.setLabel(l.name, color: l.color, on: workspace.id, assigned: !on) } } label: {
                        if on { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                    }
                }
                if let labeling {
                    Divider()
                    Button("新标签…") { labeling.wrappedValue = workspace }
                }
            }
        }
        Divider()
        Button("归档工作区", systemImage: "archivebox", role: .destructive) { archiving = workspace }
    }
}

/// Rename / archive dialogs shared by every place that shows WorkspaceMenuItems.
struct WorkspaceDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var renaming: Workspace?
    @Binding var archiving: Workspace?
    var labeling: Binding<Workspace?>? = nil
    @State private var title = ""
    @State private var labelName = ""

    func body(content: Content) -> some View {
        content
            .alert("新标签", isPresented: Binding(get: { labeling?.wrappedValue != nil }, set: { if !$0 { labeling?.wrappedValue = nil } })) {
                TextField("标签名", text: $labelName)
                Button("取消", role: .cancel) {}
                Button("添加") {
                    guard let w = labeling?.wrappedValue, let h = host(of: w) else { return }
                    let name = labelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    labelName = ""
                    guard !name.isEmpty else { return }
                    let color = WorkspaceLabel.colors[abs(name.hashValue) % WorkspaceLabel.colors.count]
                    Task { try? await h.setLabel(name, color: color, on: w.id, assigned: true) }
                }
            }
            .alert("重命名工作区", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名字（留空恢复默认）", text: $title)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    guard let w = renaming, let h = host(of: w) else { return }
                    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { try? await h.renameWorkspace(w.id, title: t.isEmpty ? nil : t) }
                }
            }
            .onChange(of: renaming?.id) { title = renaming?.title ?? renaming?.name ?? "" }
            // 用工作区标题（如「项目开源的风险评估」）：同一个项目里的本地工作区 name 都是分支名「main」，只显示 name 分不清归档的是哪个
            .confirmationDialog("归档「\(archiving.map(Self.displayName) ?? "")」？", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } })) {
                Button("归档", role: .destructive) {
                    guard let w = archiving, let h = host(of: w) else { return }
                    Task { try? await h.archiveWorkspace(w.id) }
                }
            } message: {
                Text(archiveWarning)
            }
    }

    static func displayName(_ w: Workspace) -> String {
        if let t = w.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return w.name
    }

    private var archiveWarning: String {
        guard let w = archiving else { return "" }
        let dirty = (w.additions ?? 0) + (w.deletions ?? 0) > 0
        let base = w.kind == "worktree" && dirty
            ? String(localized: "这个 worktree 还有未提交的改动，归档会删除它。里面的会话也会一起归档。")
            : String(localized: "里面的会话会一起归档，正在运行的会被停止。")
        // 列出会被归档的会话，正在运行的标出来，防止点错行
        guard let h = host(of: w) else { return base }
        let agents = h.agents.values.filter { $0.workspaceId == w.id && $0.archivedAt == nil && $0.parentAgentId == nil }
            .sorted { ($0.status == .running ? 0 : 1) < ($1.status == .running ? 0 : 1) }
        guard !agents.isEmpty else { return base }
        let names = agents.prefix(5).map { $0.status == .running ? String(localized: "「\($0.displayTitle)」（运行中）") : String(localized: "「\($0.displayTitle)」") }
        let more = agents.count > 5 ? String(localized: "等 \(agents.count) 个会话") : ""
        return base + "\n" + String(localized: "包括：\(names.joined(separator: String(localized: "、", comment: "列举时的分隔符（顿号）")))\(more)")
    }

    private func host(of w: Workspace) -> HostStore? { model.hosts.first { $0.workspaces[w.id] != nil } }
}

extension View {
    func workspaceDialogs(renaming: Binding<Workspace?>, archiving: Binding<Workspace?>, labeling: Binding<Workspace?>? = nil) -> some View {
        modifier(WorkspaceDialogs(renaming: renaming, archiving: archiving, labeling: labeling))
    }
}

/// Label catalog management for one host. Official: workspace-labels/manager-modal.tsx.
struct LabelsManager: View {
    let host: HostStore
    @State private var renaming: WorkspaceLabel?
    @State private var newName = ""
    @State private var deleting: (WorkspaceLabel, Int)?
    @State private var error: String?

    var body: some View {
        Section {
            if host.labels.isEmpty { Text("还没有标签。在工作区的右键菜单里添加。").foregroundStyle(Theme.muted) }
            ForEach(host.labels.sorted { $0.name < $1.name }) { l in
                HStack {
                    Circle().fill(labelColor(l.color)).frame(width: 10, height: 10)
                    Text(l.name)
                    Spacer()
                    Menu {
                        ForEach(WorkspaceLabel.colors, id: \.self) { c in
                            Button { Task { try? await host.updateLabel(l.name, newName: nil, color: c) } } label: {
                                if c == l.color { Label(c, systemImage: "checkmark") } else { Text(c) }
                            }
                        }
                    } label: { Image(systemName: "paintpalette") }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("标签颜色")
                    Button { newName = l.name; renaming = l } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                        .accessibilityLabel("重命名标签")
                    Button { Task { deleting = (l, await host.labelUsage(l.name)) } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        .accessibilityLabel("删除标签")
                }
            }
            if let error { Text(error).foregroundStyle(Theme.destructive) }
        } header: {
            Text("工作区标签")
        }
        .alert("重命名标签", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                guard let l = renaming else { return }
                Task { do { try await host.updateLabel(l.name, newName: newName, color: nil) } catch { self.error = "\(error)" } }
            }
        }
        .confirmationDialog("删除标签「\(deleting?.0.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let (l, _) = deleting { Task { try? await host.deleteLabel(l.name) } } }
        } message: {
            Text("会从 \(deleting?.1 ?? 0) 个工作区上移除。")
        }
    }
}

#if os(macOS)
/// Code editors installed on this Mac (official: "Open in editor").
enum LocalEditors {
    static let installed: [(name: String, url: URL)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Visual Studio Code", "com.microsoft.VSCode"), ("Zed", "dev.zed.Zed"),
        ("Windsurf", "com.exafunction.windsurf"), ("Xcode", "com.apple.dt.Xcode"), ("Sublime Text", "com.sublimetext.4"),
        ("IntelliJ IDEA", "com.jetbrains.intellij"), ("WebStorm", "com.jetbrains.WebStorm"),
    ].compactMap { name, id in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (name, $0) } }
}
#endif

/// Sessions started in Claude Code, Codex… on the host, imported into Paseo (official "Import session").
struct ImportSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    /// Limit to this directory (the current workspace) unless "all" is chosen.
    let cwd: String?
    @State private var onlyHere = true
    @State private var query = ""
    @State private var items: [HostStore.RecentSession]?
    @State private var error: String?
    @State private var importing: String?

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("导入会话").font(.headline)
                    Spacer()
                    Button { dismiss() } label: { Text("关闭").mobileTouchTarget() }
                }
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder)
                if cwd != nil { Toggle("只看当前目录", isOn: $onlyHere) }
            }
            .padding(12)
            #else
            HStack(spacing: 10) {
                Text("导入会话").font(.headline)
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                if cwd != nil { Toggle("只看当前目录", isOn: $onlyHere).checkboxOnMac() }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            #endif
            Divider()
            Group {
                if let error { Text(error).foregroundStyle(Theme.destructive).padding() }
                else if let items {
                    if items.isEmpty { ContentUnavailableView("没有可导入的会话", systemImage: "tray") }
                    else {
                        List(items) { s in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title ?? s.firstPrompt ?? s.handleId).lineLimit(2)
                                    if let last = s.lastPrompt, last != s.title { Text(last).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                                    Text([s.providerLabel, s.cwd, s.lastActivityAt.map(formatTimestamp)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(Theme.extraMuted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if importing == s.id { ProgressView().controlSize(.small) }
                                else { Button("导入") { importSession(s) }.disabled(importing != nil) }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .macOnly { $0.frame(minWidth: 640, minHeight: 480) }
        .task(id: "\(onlyHere)|\(query)") {
            try? await Task.sleep(for: .milliseconds(250))
            do { items = try await host.recentProviderSessions(cwd: onlyHere ? cwd : nil, query: query); error = nil }
            catch { self.error = "\(error)" }
        }
    }

    private func importSession(_ s: HostStore.RecentSession) {
        importing = s.id
        Task {
            do {
                let id = try await host.importSession(s)
                dismiss()
                try? await Task.sleep(for: .milliseconds(300))
                model.open(AgentRef(serverId: host.id, agentId: id))
            } catch { self.error = String(localized: "导入失败：\(error)") }
            importing = nil
        }
    }
}

extension View {
    /// Checkbox on the Mac; the platform switch elsewhere (there is no checkbox style on iOS).
    @ViewBuilder func checkboxOnMac() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
