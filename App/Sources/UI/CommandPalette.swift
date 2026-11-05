// ⌘K command center: actions, sessions, workspaces, workspace and agent commands; ⌘P searches files.
// Official: command-center/ (sections, fuzzy match, nested pages).

import PaseoKit
import SwiftUI

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var showSettings: Bool
    /// Start in file search (⌘P).
    var filesMode = false
    @State private var query = ""
    @State private var index = 0
    @State private var page: Page?
    @State private var files: [HostStore.PathSuggestion] = []
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let section: String
        let title: String
        var subtitle: String = ""
        let systemImage: String
        var bucket: StatusBucket? = nil
        var date: Date = .distantPast
        var run: () -> Void = {}
        /// Opens a nested list instead of running.
        var page: (() -> Page)? = nil
    }

    struct Page {
        let title: String
        let items: [Item]
    }

    private var workspaceRef: WorkspaceRef? { model.currentWorkspace }
    private var host: HostStore? { workspaceRef.flatMap { model.host($0.serverId) } }
    private var workspace: Workspace? { workspaceRef.flatMap { model.workspace($0) } }
    private var currentAgent: (HostStore, Agent)? {
        if case .agent(let r) = model.destination, let h = model.host(r.serverId), let a = h.agents[r.agentId] { return (h, a) }
        return nil
    }

    // MARK: Items

    private var allItems: [Item] {
        if let page { return page.items }
        if filesMode { return fileItems }
        var out = globalActions + workspaceActions + agentActions
        for h in model.hosts {
            for a in h.agents.values where a.archivedAt == nil && !h.isNested(a) {
                out.append(Item(id: "a" + h.id + a.id, section: "会话", title: a.displayTitle,
                                subtitle: model.projectName(of: a, in: h) + " · " + h.label, systemImage: "bubble.left",
                                bucket: a.bucket, date: a.lastUserMessageAt ?? a.updatedAt ?? .distantPast) {
                    model.open(AgentRef(serverId: h.id, agentId: a.id))
                })
            }
            for w in h.workspaces.values {
                out.append(Item(id: "w" + h.id + w.id, section: "工作区", title: w.name.isEmpty ? w.projectDisplayName : w.name,
                                subtitle: [w.projectDisplayName, w.currentBranch, h.label].compactMap { $0 }.joined(separator: " · "),
                                systemImage: w.pinnedAt != nil ? "pin" : "folder", date: w.activityAt ?? .distantPast) {
                    let ref = WorkspaceRef(serverId: h.id, workspaceId: w.id)
                    if let t = model.selectedTab(ref) { model.select(t, in: ref) } else { model.select(.draft(UUID().uuidString), in: ref) }
                })
            }
        }
        return out
    }

    private var globalActions: [Item] {
        [
            Item(id: "new", section: "操作", title: "新聊天", subtitle: "⌘N", systemImage: "square.and.pencil") { model.destination = .newChat },
            Item(id: "files", section: "操作", title: "搜索文件…", subtitle: "⌘P", systemImage: "doc.text.magnifyingglass",
                 page: { Page(title: "搜索文件", items: []) }),
            Item(id: "addProject", section: "操作", title: "添加项目…", systemImage: "folder.badge.plus") { post(.addProject) },
            Item(id: "import", section: "操作", title: "导入外部会话…", systemImage: "square.and.arrow.down") { post(.importSessions) },
            Item(id: "history", section: "操作", title: "会话历史", subtitle: "⌘Y", systemImage: "clock.arrow.circlepath") { model.destination = .history },
            Item(id: "projects", section: "操作", title: "项目", subtitle: "⌥⌘P", systemImage: "folder") { model.destination = .projects },
            Item(id: "schedules", section: "操作", title: "计划任务", systemImage: "calendar") { model.destination = .schedules },
            Item(id: "usage", section: "操作", title: "用量", systemImage: "chart.bar") { model.destination = .usage },
            Item(id: "settings", section: "操作", title: "设置", subtitle: "⌘,", systemImage: "gearshape") { showSettings = true },
            Item(id: "sidebar", section: "操作", title: "显示/隐藏侧栏", subtitle: "⌘B", systemImage: "sidebar.left") { post(.toggleSidebar) },
            Item(id: "theme", section: "操作", title: "切换主题", subtitle: "⌥⌘T", systemImage: "circle.lefthalf.filled") { post(.cycleAppearance) },
            Item(id: "keys", section: "操作", title: "键盘快捷键", subtitle: "⌘/", systemImage: "keyboard") { post(.showShortcuts) },
            Item(id: "groupProject", section: "操作", title: "侧栏按项目分组", systemImage: "folder") { model.grouping = .project },
            Item(id: "groupStatus", section: "操作", title: "侧栏按状态分组", systemImage: "circle.grid.2x1") { model.grouping = .status },
        ]
    }

    private var workspaceActions: [Item] {
        guard let ref = workspaceRef, let host, let w = workspace else { return [] }
        let tab: (WorkspaceTabCommand) -> Void = { c in NotificationCenter.default.post(name: .workspaceTabCommand, object: c) }
        var out: [Item] = [
            Item(id: "wsAgent", section: "当前工作区", title: "新会话标签", subtitle: "⇧⌘A", systemImage: "square.and.pencil") { tab(.newAgent) },
            Item(id: "wsTerm", section: "当前工作区", title: "新终端", subtitle: "⇧⌘T", systemImage: "apple.terminal") { tab(.newTerminal) },
            Item(id: "wsChanges", section: "当前工作区", title: "打开改动", subtitle: "⇧⌘G", systemImage: "plusminus") { model.select(.changes, in: ref) },
            Item(id: "wsFiles", section: "当前工作区", title: "打开文件", subtitle: "⇧⌘E", systemImage: "folder") { model.select(.files, in: ref) },
            Item(id: "wsExplorer", section: "当前工作区", title: "显示/隐藏右栏", subtitle: "⌘E", systemImage: "sidebar.right") { tab(.toggleExplorer) },
            Item(id: "wsPin", section: "当前工作区", title: w.pinnedAt == nil ? "置顶工作区" : "取消置顶工作区", subtitle: "⇧⌘P", systemImage: "pin") {
                Task { try? await host.pinWorkspace(w.id, pinned: w.pinnedAt == nil) }
            },
            Item(id: "wsPath", section: "当前工作区", title: "复制工作区路径", systemImage: "doc.on.doc") { Pasteboard.copy(w.directory) },
        ]
        if let b = w.currentBranch {
            out.append(Item(id: "wsBranch", section: "当前工作区", title: "复制分支名", subtitle: b, systemImage: "arrow.triangle.branch") { Pasteboard.copy(b) })
        }
        if w.isGit {
            for (id, title, icon) in [("pull", "Git：拉取", "arrow.down"), ("push", "Git：推送", "arrow.up"), ("pullPush", "Git：拉取后推送", "arrow.up.arrow.down"),
                                      ("mergeFromBase", "Git：从 base 合并", "arrow.triangle.merge")] {
                out.append(Item(id: "git" + id, section: "当前工作区", title: title, systemImage: icon) {
                    Task { try? await host.gitAction(id, cwd: w.directory) }
                })
            }
            if let pr = w.pullRequest, let u = URL(string: pr.url) {
                out.append(Item(id: "prOpen", section: "当前工作区", title: "在浏览器打开 PR", subtitle: pr.number.map { "#\($0)" } ?? "", systemImage: "safari") {
                    openURL(u)
                })
            }
        }
        return out
    }

    @Environment(\.openURL) private var openURL

    private var agentActions: [Item] {
        guard let (host, a) = currentAgent else { return [] }
        var out: [Item] = []
        let models = host.providers.first { $0["provider"]?.stringValue == a.provider }?["models"]?.arrayValue ?? []
        if !models.isEmpty {
            out.append(Item(id: "agModel", section: "当前会话", title: "切换模型…", subtitle: a.model ?? "", systemImage: "sparkle", page: {
                Page(title: "切换模型", items: models.map { m in
                    let id = m["id"]?.stringValue ?? ""
                    return Item(id: "m" + id, section: "模型", title: m["label"]?.stringValue ?? id, subtitle: id == a.model ? "当前" : "",
                                systemImage: id == a.model ? "checkmark" : "sparkle") { Task { try? await host.setModel(a.id, modelId: id) } }
                })
            }))
            let entry = models.first { $0["id"]?.stringValue == a.model } ?? models.first { $0["isDefault"]?.boolValue == true }
            let thinking = entry?["thinkingOptions"]?.arrayValue ?? []
            if !thinking.isEmpty {
                out.append(Item(id: "agThink", section: "当前会话", title: "切换思考强度…", systemImage: "brain", page: {
                    Page(title: "思考强度", items: thinking.map { o in
                        let id = o["id"]?.stringValue ?? ""
                        return Item(id: "t" + id, section: "思考", title: o["label"]?.stringValue ?? id, systemImage: "brain") {
                            Task { try? await host.setThinking(a.id, optionId: id) }
                        }
                    })
                }))
            }
        }
        if !a.availableModes.isEmpty {
            out.append(Item(id: "agMode", section: "当前会话", title: "切换权限模式…", subtitle: a.currentMode?.label ?? "", systemImage: "shield.lefthalf.filled", page: {
                Page(title: "权限模式", items: a.availableModes.map { m in
                    Item(id: "md" + m.id, section: "模式", title: m.label, subtitle: m.id == a.currentModeId ? "当前" : "",
                         systemImage: m.id == a.currentModeId ? "checkmark" : "shield") { Task { try? await host.setMode(a.id, modeId: m.id) } }
                })
            }))
        }
        for f in a.composerFeatures where f.isToggle {
            let on = f.boolValue
            out.append(Item(id: "ft" + f.id, section: "当前会话", title: (on ? "关闭 " : "打开 ") + f.label, systemImage: "bolt") {
                Task { try? await host.setFeature(a.id, featureId: f.id, value: .bool(!on)) }
            })
        }
        out.append(Item(id: "agFind", section: "当前会话", title: "在会话中查找", subtitle: "⌘F", systemImage: "magnifyingglass") { post(.findInSession) })
        out.append(Item(id: "agOutline", section: "当前会话", title: "提问大纲", subtitle: "⇧⌘O", systemImage: "list.bullet.indent") { post(.showOutline) })
        out.append(Item(id: "agRename", section: "当前会话", title: "重命名会话", subtitle: "⇧⌘R", systemImage: "pencil") { post(.renameCurrent) })
        out.append(Item(id: "agId", section: "当前会话", title: "复制会话 ID", systemImage: "doc.on.doc") { Pasteboard.copy(a.id) })
        out.append(Item(id: "agArchive", section: "当前会话", title: "归档会话", subtitle: "⇧⌘⌫", systemImage: "archivebox") { post(.archiveCurrent) })
        return out
    }

    private var fileItems: [Item] {
        guard let ref = workspaceRef, let w = workspace else { return [] }
        return files.filter { !$0.isDirectory }.map { f in
            let abs = f.path.hasPrefix("/") ? f.path : w.directory + "/" + f.path
            let rel = abs.hasPrefix(w.directory + "/") ? String(abs.dropFirst(w.directory.count + 1)) : abs
            return Item(id: "f" + abs, section: "文件", title: (rel as NSString).lastPathComponent,
                        subtitle: (rel as NSString).deletingLastPathComponent, systemImage: "doc.text") {
                model.openFile(abs, line: nil, in: ref)
            }
        }
    }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = allItems
        if filesMode || page?.title == "搜索文件" { return Array(fileItems.prefix(60)) }
        guard !q.isEmpty else {
            // Recent sessions only when nothing is typed; workspaces and the long tail wait for a query.
            let recent = items.filter { $0.section == "会话" }.sorted { $0.date > $1.date }.prefix(6)
            return Array(recent) + agentActions + workspaceActions + globalActions
        }
        return items.compactMap { item -> (Item, Int)? in
            guard let s = Fuzzy.score(q, item.title + " " + item.subtitle) else { return nil }
            return (item, s)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
        .prefix(60).map(\.0)
    }

    private var searchingFiles: Bool { filesMode || page?.title == "搜索文件" }

    // MARK: View

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let page {
                    Button { self.page = nil; query = "" } label: {
                        Label(page.title, systemImage: "chevron.left").font(.system(size: 12))
                            .padding(.horizontal, 8).frame(height: 24).background(Theme.surface2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: searchingFiles ? "doc.text.magnifyingglass" : "magnifyingglass").foregroundStyle(Theme.muted)
                }
                TextField(searchingFiles ? (workspace == nil ? "先打开一个工作区" : "搜索「\(workspace?.name ?? "")」里的文件") : "搜索会话、工作区或操作",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(list) }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || list[i - 1].section != item.section {
                                Text(item.section).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.extraMuted)
                                    .padding(.horizontal, 12).padding(.top, i == 0 ? 2 : 10).padding(.bottom, 2)
                            }
                            Button { index = i; run(list) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.systemImage).frame(width: 20).foregroundStyle(Theme.muted)
                                    Text(item.title).lineLimit(1)
                                    if let b = item.bucket, b != .done { StatusDot(bucket: b) }
                                    Spacer()
                                    Text(item.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                                    if item.page != nil { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.extraMuted) }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(i == index ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                        if list.isEmpty {
                            Text(searchingFiles && query.isEmpty ? "输入文件名" : "没有结果").foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .macOnly { $0.frame(width: 640, height: 480) }
        .onAppear {
            focused = true
            #if DEBUG
            if let q = ProcessInfo.processInfo.environment["PASEO_PALETTE_QUERY"] { query = q }
            #endif
        }
        .onChange(of: query) { index = 0 }
        .task(id: searchingFiles ? query : nil) {
            guard searchingFiles, let host, let w = workspace, !query.isEmpty else { files = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            files = await host.pathSuggestions(cwd: w.directory, query: query)
        }
        .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) {
            if page != nil { page = nil; query = ""; return .handled }
            dismiss(); return .handled
        }
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        let item = list[index]
        if let p = item.page {
            page = p()
            query = ""
            index = 0
            return
        }
        dismiss()
        item.run()
    }

    private func post(_ name: Notification.Name) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}

/// Subsequence match with bonuses for word starts and runs; nil when the query is not contained.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        if let r = text.lowercased().range(of: query.lowercased()) {
            return 1000 - text.distance(from: text.startIndex, to: r.lowerBound)
        }
        var score = 0, qi = 0, last = -2
        for (ti, c) in t.enumerated() where qi < q.count && c == q[qi] {
            score += ti == last + 1 ? 8 : 1
            if ti == 0 || " /-_·.".contains(t[ti - 1]) { score += 6 }
            last = ti
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}

/// ⌘/ — every shortcut, grouped and searchable. Official: keyboard-shortcuts help dialog.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let groups: [(String, [(String, String)])] = [
        ("全局", [("⌘K", "命令面板"), ("⌘P", "搜索当前工作区的文件"), ("⌘N", "新聊天"), ("⌘O", "在当前工作区新建会话"), ("⌘,", "设置"),
                  ("⌘B", "显示/隐藏侧栏"), ("⌘E", "显示/隐藏右栏（改动与文件）"), ("⌥⌘T", "切换主题"), ("⌘/", "键盘快捷键")]),
        ("前往", [("⌘Y", "会话历史"), ("⌥⌘P", "项目"), ("⌘1…9", "第 N 个会话"), ("⌘[ / ⌘]", "上一个/下一个会话")]),
        ("标签", [("⇧⌘A", "新会话标签"), ("⇧⌘T", "新终端"), ("⇧⌘G", "改动"), ("⇧⌘E", "文件"), ("⇧⌘B", "浏览器"), ("⌘W", "关闭标签"),
                  ("⌥⌘1…9", "第 N 个标签"), ("⌥⇧[ / ⌥⇧]", "上一个/下一个标签")]),
        ("会话", [("⌘L", "聚焦输入框"), ("⌘F", "在会话中查找"), ("⇧⌘O", "提问大纲"), ("⇧⌘R", "重命名"),
                  ("⇧⌘⌫", "归档"), ("⇧⌘P", "置顶/取消置顶工作区")]),
        ("输入框", [("↩", "发送"), ("⇧↩", "换行"), ("⌘↩", "换一种方式发送（排队 ↔ 立即）"), ("↑", "空输入框时调出上一条消息"),
                   ("⇧⇥", "切换权限模式"), ("Esc", "中断当前回合")]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索快捷键", text: $query).textFieldStyle(.plain)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.groups, id: \.0) { title, items in
                        let shown = items.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) || $0.0.contains(query) }
                        if !shown.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                                ForEach(shown, id: \.1) { key, label in
                                    HStack {
                                        Text(label)
                                        Spacer()
                                        Text(key).font(.system(size: 12, design: .monospaced))
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .font(.system(size: 13))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .macOnly { $0.frame(width: 460, height: 520) }
    }
}
