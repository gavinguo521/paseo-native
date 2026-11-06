// Workspace tab contents: files, git changes, terminals, scripts.
// Official: explorer sidebar (Files/Changes), terminal tabs, workspace scripts.

import PaseoKit
#if os(macOS)
import QuickLook
#endif
import SwiftTerm
import SwiftUI
import WebKit

/// Resizable split on macOS; side by side on iOS until the iPhone layout is done.
struct SplitPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        HSplitView { content }
        #else
        HStack(spacing: 0) { content }
        #endif
    }
}

/// Side by side when there is room; in the narrow explorer column the detail replaces the list, with a back button.
struct ListDetail<List: View, Detail: View>: View {
    let compact: Bool
    let showDetail: Bool
    let onBack: () -> Void
    @ViewBuilder let list: List
    @ViewBuilder let detail: Detail
    #if os(iOS)
    /// iPad split view / Slide Over: 280 + 380 side by side would not fit.
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var stacked: Bool {
        #if os(iOS)
        compact || sizeClass == .compact
        #else
        compact
        #endif
    }

    var body: some View {
        if stacked {
            if showDetail {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: onBack) { Label("返回", systemImage: "chevron.left") }.buttonStyle(.plain)
                        Spacer()
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12).frame(height: 32)
                    Divider()
                    detail
                }
            } else {
                list
            }
        } else {
            SplitPane {
                list.frame(minWidth: 280, idealWidth: 340)
                if showDetail { detail.frame(minWidth: 380) }
            }
        }
    }
}

// MARK: Files

struct FilesView: View {
    let host: HostStore
    let workspace: Workspace
    var compact = false
    /// Loaded directory listings by relative path ("." is the root).
    @State private var children: [String: [FileEntry]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loadingDirs: Set<String> = []
    @State private var error: String?
    @State private var opened: FileEntry?
    @State private var quickLook: URL?
    @AppStorage("files.showHidden") private var showHidden = false
    @AppStorage("files.sort") private var sort = "name"

    private struct Row: Identifiable { let entry: FileEntry; let depth: Int; var id: String { entry.id } }

    /// Expanded directories flattened into indented rows (official file tree).
    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in sorted(children[dir] ?? []) {
                out.append(Row(entry: e, depth: depth))
                if e.isDirectory, expanded.contains(e.path) { walk(e.path, depth + 1) }
            }
        }
        walk(".", 0)
        return out
    }

    var body: some View {
        ListDetail(compact: compact, showDetail: opened.map { !$0.isDirectory } ?? false, onBack: { opened = nil }) {
            VStack(spacing: 0) {
                header
                Divider()
                List(rows, selection: Binding(get: { opened?.id }, set: { id in open(rows.first { $0.id == id }?.entry) })) { row in
                    let e = row.entry
                    HStack(spacing: 6) {
                        Group {
                            if e.isDirectory {
                                if loadingDirs.contains(e.path) { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "chevron.right").rotationEffect(.degrees(expanded.contains(e.path) ? 90 : 0)) }
                            } else { Color.clear }
                        }
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.extraMuted).frame(width: 10)
                        Image(systemName: e.isDirectory ? (expanded.contains(e.path) ? "folder" : "folder.fill") : icon(for: e.name))
                            .foregroundStyle(e.isDirectory ? Theme.dotRunning.opacity(0.8) : Theme.muted)
                            .frame(width: 18)
                        Text(e.name).lineLimit(1).foregroundStyle(e.name.hasPrefix(".") ? Theme.muted : Theme.foreground)
                        Spacer()
                        if !e.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                .font(.system(size: 10)).foregroundStyle(Theme.extraMuted)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .tag(e.id)
                    #if os(macOS)
                    .if(!e.isDirectory) { $0.hostFileDrag(host: host, path: workspace.directory + "/" + e.path) }
                    #endif
                    .contextMenu {
                        #if os(macOS)
                        if !e.isDirectory {
                            HostFileMenuItems(host: host, path: workspace.directory + "/" + e.path, quickLook: $quickLook)
                            Divider()
                        }
                        #endif
                        Button("添加到聊天", systemImage: "text.bubble") { NotificationCenter.default.post(name: .appendToComposer, object: "@" + e.path) }
                        Button("复制相对路径", systemImage: "doc.on.doc") { Pasteboard.copy(e.path) }
                        Button("复制完整路径", systemImage: "link") { Pasteboard.copy(workspace.directory + "/" + e.path) }
                        if !e.isDirectory, let ref = Optional(WorkspaceRef(serverId: host.id, workspaceId: workspace.id)) {
                            Button("在标签中打开", systemImage: "doc.text") {
                                NotificationCenter.default.post(name: .openFileTab, object: (ref, workspace.directory + "/" + e.path))
                            }
                        }
                    }
                }
                #if os(macOS)
                // Space previews the selected file, as in Finder.
                .onKeyPress(.space) {
                    guard let f = opened, !f.isDirectory else { return .ignored }
                    preview(host: host, path: workspace.directory + "/" + f.path, into: $quickLook)
                    return .handled
                }
                .quickLookPreview($quickLook)
                #endif
                .overlay {
                    if children["."] == nil && error == nil { ProgressView() }
                    else if let error { Text(error).foregroundStyle(Theme.destructive).padding() }
                }
            }
        } detail: {
            if let opened, !opened.isDirectory {
                FileViewer(host: host, cwd: workspace.directory, path: opened.path).id(opened.id)
            }
        }
        .task { await load(".") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(workspace.directory)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.head)
            Spacer()
            Button { expanded = [] } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.buttonStyle(.plain)
                .help("全部折叠").disabled(expanded.isEmpty)
            Menu {
                Toggle("显示隐藏文件", isOn: $showHidden)
                Picker("排序", selection: $sort) { Text("名称").tag("name"); Text("修改时间").tag("modified"); Text("大小").tag("size") }
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { Task { await reloadAll() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新")
        }
        .padding(.horizontal, 14).frame(height: 40)
    }

    /// Directories first, then the chosen order; dotfiles hidden unless enabled (client-side, like the official app).
    private func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { showHidden || !$0.name.hasPrefix(".") }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort {
            case "modified": return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
            case "size": return a.size > b.size
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private func open(_ e: FileEntry?) {
        guard let e else { return }
        if e.isDirectory {
            if expanded.contains(e.path) { expanded.remove(e.path) } else {
                expanded.insert(e.path)
                if children[e.path] == nil { Task { await load(e.path) } }
            }
        } else {
            opened = e
        }
    }

    private func load(_ dir: String) async {
        loadingDirs.insert(dir)
        defer { loadingDirs.remove(dir) }
        do { children[dir] = try await host.listDirectory(cwd: workspace.directory, path: dir); error = nil }
        catch { if dir == "." { self.error = "\(error)" } }
    }

    private func reloadAll() async {
        await load(".")
        for d in expanded { await load(d) }
    }

    private func meta(_ e: FileEntry) -> String {
        let date = e.modifiedAt.map { $0.formatted(date: .numeric, time: .omitted) } ?? ""
        return e.isDirectory ? date : date + " · " + ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file)
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": "photo"
        case "md", "txt": "doc.text"
        case "json", "yml", "yaml", "toml", "plist": "curlybraces"
        case "swift", "ts", "tsx", "js", "py", "go", "rs", "java", "kt", "c", "h", "m", "rb", "sh": "chevron.left.forwardslash.chevron.right"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar": "archivebox"
        default: "doc"
        }
    }
}

struct FileViewer: View {
    let host: HostStore
    let cwd: String
    /// Relative to `cwd`.
    let path: String
    /// 1-based line to scroll to and highlight (links like `Foo.swift:42`).
    var line: Int? = nil
    @State private var content: FileContent?
    @State private var error: String?
    @State private var creationError: String?
    @State private var creating = false
    /// Markdown and HTML: rendered (true) or source.
    @State private var preview = true
    @State private var finding = false
    @State private var query = ""
    @State private var matchIndex = 0

    @State private var searchIndex = FileSearchIndex()
    @State private var foundLines: [Int] = []
    @State private var completedQuery = ""
    @State private var fileRevision = UUID()
    @State private var lineCount = 0
    private struct SearchRequest: Equatable { let file: UUID; let query: String }
    private var matchLines: [Int] { completedQuery == query ? foundLines : [] }
    private var currentMatch: Int? { matchLines.isEmpty ? nil : matchLines[min(matchIndex, matchLines.count - 1)] }

    private var name: String { (path as NSString).lastPathComponent }
    private var ext: String { (name as NSString).pathExtension.lowercased() }
    private var previewable: Bool { ["md", "markdown", "html", "htm"].contains(ext) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.system(size: 13, weight: .semibold))
                if let line { Text("第 \(line) 行").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                if let c = content, c.kind == .text, c.text != nil {
                    Text(String(localized: "\(lineCount) 行 · \(ByteCountFormatter.string(fromByteCount: Int64(c.size), countStyle: .file))"))
                        .font(.system(size: 11)).foregroundStyle(Theme.extraMuted)
                }
                Spacer()
                if previewable, content?.kind == .text {
                    Picker("", selection: $preview) { Text("预览").tag(true); Text("源码").tag(false) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if content?.kind == .text {
                    Button { finding.toggle(); if !finding { query = "" } } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).help("在文件中查找（⌘F）").keyboardShortcut("f", modifiers: .command)
                }
                if let c = content, let text = c.text { Button { Pasteboard.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制内容") }
                #if os(macOS)
                if let c = content { Button { download(c) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.plain).help("下载到本机") }
                #endif
                Button { Pasteboard.copy(cwd + "/" + path) } label: { Image(systemName: "link") }.buttonStyle(.plain).help("复制路径")
            }
            .padding(.horizontal, 14).frame(height: 40)
            if finding {
                HStack(spacing: 8) {
                    TextField("查找", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .onSubmit { matchIndex = matchLines.isEmpty ? 0 : (matchIndex + 1) % matchLines.count }
                    Text(matchLines.isEmpty ? (query.isEmpty ? "" : completedQuery != query ? "查找中…" : "无结果") : "\(min(matchIndex, matchLines.count - 1) + 1)/\(matchLines.count) 行")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    Button { matchIndex = (matchIndex - 1 + max(matchLines.count, 1)) % max(matchLines.count, 1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).disabled(matchLines.isEmpty)
                    Button { matchIndex = (matchIndex + 1) % max(matchLines.count, 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).disabled(matchLines.isEmpty)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
                .onChange(of: query) { matchIndex = 0 }
            }
            Divider()
            Group {
                if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).foregroundStyle(Theme.destructive).textSelection(.enabled)
                        if EmptyFileCreation.isMissing(error) {
                            Text("将在 \(host.label) 创建空文件：\(cwd)/\(path)")
                                .font(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                            if host.serverInfo?.hasFeature("fsEntryOps") == true {
                                Button(creating ? "正在创建…" : "创建此文件") { Task { await createFile() } }
                                    .disabled(creating)
                            } else {
                                Text("当前服务端不支持创建文件").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        if let creationError { Text(creationError).foregroundStyle(Theme.destructive).textSelection(.enabled) }
                        Button("重新加载") { Task { await loadFile() } }.disabled(creating)
                    }.padding()
                } else if let c = content {
                    switch c.kind {
                    case .text:
                        if ["md", "markdown"].contains(ext) && line == nil && preview {
                            ScrollView { MarkdownView(text: c.text ?? "").padding(20) }
                        } else if ["html", "htm"].contains(ext) && line == nil && preview {
                            HTMLPreview(html: c.text ?? "")
                        } else {
                            FileSourceView(text: c.text ?? "", language: name, target: currentMatch ?? line)
                        }
                    case .image:
                        ScrollView {
                            #if os(macOS)
                            if let img = NSImage(data: c.data) { Image(nsImage: img).resizable().scaledToFit().padding(20) }
                            #else
                            if let img = UIImage(data: c.data) { Image(uiImage: img).resizable().scaledToFit().padding(20) }
                            #endif
                        }
                    case .binary:
                        ContentUnavailableView("二进制文件", systemImage: "doc", description: Text(ByteCountFormatter.string(fromByteCount: Int64(c.size), countStyle: .file)))
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: SearchRequest(file: fileRevision, query: query)) {
            let requested = query
            guard let text = content?.text else { return }
            do {
                let found = try await searchIndex.matches(in: text, query: requested)
                guard !Task.isCancelled else { return }
                foundLines = found; completedQuery = requested; matchIndex = 0
            } catch is CancellationError { }
            catch { assertionFailure("文件搜索失败：\(error)") }
        }
        .task { await loadFile() }
    }

    private func loadFile() async {
        do {
            let loaded = try await host.readFile(cwd: cwd, path: path, maxBytes: 16 * 1024 * 1024)
            let count = await Task.detached { loaded.text?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0 }.value
            guard !Task.isCancelled else { return }
            lineCount = count; content = loaded; fileRevision = UUID()
            error = nil; creationError = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "\(error)"
        }
    }

    private func createFile() async {
        guard !creating, let error, EmptyFileCreation.isMissing(error) else { return }
        creating = true; creationError = nil
        defer { creating = false }
        do {
            try await host.createEmptyFile(cwd: cwd, path: path)
            await loadFile()
        } catch { creationError = "\(error)" }
    }

    #if os(macOS)
    private func download(_ c: FileContent) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? c.data.write(to: url)
    }
    #endif


}

/// Static HTML file preview (no network base, so relative assets will not load).
#if os(macOS)
private struct HTMLPreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView { let v = WKWebView(); v.loadHTMLString(html, baseURL: nil); return v }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
private struct HTMLPreview: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView { let v = WKWebView(); v.loadHTMLString(html, baseURL: nil); return v }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

// MARK: Changes

struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let host: HostStore
    let workspace: Workspace
    var compact = false
    @State private var mode = "uncommitted"
    @State private var selected: String?
    @State private var message = ""
    @State private var busy: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmDiscard: DiffFile?
    @State private var quickLook: URL?
    @State private var confirmMergeToBase = false
    @State private var creatingPR = false
    @State private var showChecks = false
    @AppStorage("git.mergeMethod") private var mergeMethod = "squash"
    @AppStorage("diff.ignoreWhitespace") private var ignoreWhitespace = false
    @AppStorage("diff.split") private var splitDiff = false

    private var cwd: String { workspace.directory }
    private var diff: CheckoutDiff? { host.diffs[cwd] }
    private var status: CheckoutStatus? { host.checkoutStatus[cwd] }
    private var pr: PrStatus? { host.prStatus[cwd] }
    private var pullRequest: PullRequestInfo? { pr?.pullRequest ?? workspace.pullRequest }
    private var baseName: String { status?.baseRef ?? pullRequest?.baseRefName ?? "base" }

    private var selectedFile: DiffFile? { selected.flatMap { id in diff?.files.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if workspace.isGit { prBar }
            Divider()
            HStack {
                Picker("", selection: $mode) {
                    Text("未提交").tag("uncommitted")
                    Text("本分支").tag("base")
                    if host.serverInfo?.hasFeature("checkoutDiffAll") == true { Text("全部").tag("all") }
                    Text("提交历史").tag("history")
                }
                .pickerStyle(.segmented).labelsHidden()
                Menu {
                    Toggle("忽略空白改动", isOn: $ignoreWhitespace)
                    Picker("显示方式", selection: $splitDiff) {
                        Text("统一视图").tag(false)
                        Text("并排视图").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("diff 选项")
            }
            .padding(10)
            if let error { Banner(level: "error", message: error).padding(.horizontal, 10).padding(.bottom, 6) }
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.dotSuccess)
                    .padding(.horizontal, 12).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if mode == "history" {
                CommitHistoryView(host: host, cwd: cwd, compact: compact)
            } else {
                ListDetail(compact: compact, showDetail: selectedFile != nil, onBack: { selected = nil }) {
                    fileList
                } detail: {
                    if let f = selectedFile {
                        if splitDiff { SplitDiffView(file: f) } else {
                            StructuredDiffView(file: f, reviewCwd: cwd, openFile: {
                                NotificationCenter.default.post(name: .openFileTab, object: (WorkspaceRef(serverId: host.id, workspaceId: workspace.id), cwd + "/" + f.path))
                            })
                        }
                    }
                }
            }
            ReviewFeedbackBar(host: host, workspace: workspace)
        }
        .task(id: mode + (ignoreWhitespace ? "+ws" : "")) {
            if mode != "history" { await host.subscribeDiff(cwd: cwd, mode: mode, ignoreWhitespace: ignoreWhitespace) }
        }
        .task {
            #if DEBUG
            if let m = ProcessInfo.processInfo.environment["PASEO_GIT_MODE"] { mode = m }
            if ProcessInfo.processInfo.environment["PASEO_REVIEW_DEMO"] != nil {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if let f = diff?.files.first {
                        selected = f.id
                        if let l = f.lines.first(where: { $0.kind == .add }), let n = l.newNumber {
                            model.reviewComments[cwd] = [ReviewComment(path: f.path, line: n, removed: false, snippet: l.content, text: "这里的命名不够清楚，改成更具体的名字")]
                        }
                    }
                }
            }
            #endif
            await host.refreshCheckoutStatus(cwd: cwd)
            if workspace.isGit { await host.loadPrStatus(cwd: cwd) }
        }
        .onDisappear { Task { await host.unsubscribeDiff(cwd: cwd) } }
        .confirmationDialog("丢弃「\(confirmDiscard?.path ?? "")」的改动？", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } })) {
            Button("丢弃", role: .destructive) { if let f = confirmDiscard { run("discard", paths: [f.path]) } }
        } message: { Text("未跟踪的新文件会被删除，无法恢复。") }
        .confirmationDialog("把「\(status?.currentBranch ?? String(localized: "当前分支"))」合并到 \(baseName)？", isPresented: $confirmMergeToBase) {
            Button("合并") { run("mergeToBase") }
        } message: { Text("在本地把这个分支合并进 \(baseName)，不会推送。") }
        .sheet(isPresented: $creatingPR) {
            CreatePullRequestSheet(forge: pr?.forgeName ?? "GitHub", branch: status?.currentBranch ?? "", base: baseName) { title, body in
                perform(String(localized: "创建 PR 中"), done: String(localized: "PR 已创建")) { try await host.createPullRequest(cwd: cwd, title: title, body: body) }
            }
        }
    }

    private func fileRow(_ f: DiffFile) -> some View {
        HStack(spacing: 8) {
            Text(f.letter).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(f.letter == "A" ? Theme.diffAdd : f.letter == "D" ? Theme.diffRemove : Theme.dotWarning)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text((f.path as NSString).lastPathComponent).lineLimit(1)
                Text((f.path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(Theme.extraMuted).lineLimit(1)
            }
            Spacer()
            Text("+\(f.additions)").foregroundStyle(Theme.diffAdd).font(.system(size: 11, design: .monospaced))
            Text("−\(f.deletions)").foregroundStyle(Theme.diffRemove).font(.system(size: 11, design: .monospaced))
        }
        .tag(f.id)
        #if os(macOS)
        .if(f.letter != "D") { $0.hostFileDrag(host: host, path: workspace.directory + "/" + f.path) }
        #endif
        .contextMenu { fileMenu(f) }
    }

    @ViewBuilder private func fileMenu(_ f: DiffFile) -> some View {
        #if os(macOS)
        if f.letter != "D" {
            HostFileMenuItems(host: host, path: workspace.directory + "/" + f.path, quickLook: $quickLook)
            Divider()
        }
        #endif
        if mode == "uncommitted", host.serverInfo?.hasFeature("checkoutDiscardChanges") == true {
            Button("丢弃这个文件的改动…", role: .destructive) { confirmDiscard = f }
        }
        Button("添加到聊天") { NotificationCenter.default.post(name: .appendToComposer, object: "@" + f.path) }
        Button("复制路径") { Pasteboard.copy(f.path) }
    }

    @ViewBuilder private var fileList: some View {
        VStack(spacing: 0) {
            if let d = diff {
                if d.tooLarge { Text("改动太大，无法显示").foregroundStyle(Theme.muted).padding() }
                else if d.files.isEmpty { Text(mode == "uncommitted" ? "没有未提交的改动" : "本分支还没有提交").foregroundStyle(Theme.muted).padding() }
                List(selection: $selected) {
                  ForEach(groupedFiles(d.files), id: \.0) { dir, files in
                   Section(dir.isEmpty ? String(localized: "根目录") : dir) {
                    ForEach(files) { f in fileRow(f) }
                   }
                  }
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
            if mode == "uncommitted", !(diff?.files.isEmpty ?? true) { commitBar }
        }
        #if os(macOS)
        .quickLookPreview($quickLook)
        #endif
    }

    /// Changed files grouped under their directory (official file-tree grouping, one level).
    private func groupedFiles(_ files: [DiffFile]) -> [(String, [DiffFile])] {
        Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value.sorted { $0.path < $1.path }) }
    }

    // MARK: Branch bar

    private var statusBar: some View {
        let hasRemote = status?.hasRemote ?? false
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.muted)
            Text(status?.currentBranch ?? workspace.currentBranch ?? "—").font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let s = status, s.hasRemote {
                Text("↑\(s.aheadOfOrigin) ↓\(s.behindOfOrigin)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                    .help("相对远程分支：待推送 \(s.aheadOfOrigin) 个提交，待拉取 \(s.behindOfOrigin) 个")
            }
            Spacer()
            if let busy { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
            Button { run("pull") } label: { Image(systemName: "arrow.down") }.buttonStyle(.plain)
                .disabled(!hasRemote).help(hasRemote ? "拉取" : "没有远程分支，无法拉取")
            Button { run("push") } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain)
                .help(hasRemote ? (status?.aheadOfOrigin == 0 ? "推送（没有待推送的提交）" : "推送") : "推送并建立远程分支")
            Button { run("refresh") } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新")
            moreMenu
        }
        .padding(.horizontal, 14).frame(height: 40)
        .disabled(busy != nil)
    }

    private var moreMenu: some View {
        Menu {
            Button("拉取后推送", systemImage: "arrow.up.arrow.down") { run("pullPush") }.disabled(!(status?.hasRemote ?? false))
            if status?.baseRef != nil {
                Button("从 \(baseName) 合并", systemImage: "arrow.triangle.merge") { run("mergeFromBase") }
                Button("合并到 \(baseName)…", systemImage: "arrow.triangle.pull") { confirmMergeToBase = true }
            }
            if workspace.isGit {
                Divider()
                if let p = pullRequest {
                    if let u = URL(string: p.url) { Link(destination: u) { Label("在浏览器打开 PR", systemImage: "safari") } }
                    if p.isOpen {
                        Menu("合并 PR") {
                            ForEach([("squash", String(localized: "Squash 合并")), ("merge", String(localized: "创建合并提交")), ("rebase", String(localized: "Rebase 合并"))], id: \.0) { m, label in
                                Button(label) { mergeMethod = m; mergePR(m) }
                            }
                        }
                        Button("开启自动合并（\(methodLabel(mergeMethod))）") {
                            perform(String(localized: "设置中"), done: String(localized: "已开启自动合并")) { try await host.setAutoMerge(cwd: cwd, enabled: true, method: mergeMethod) }
                        }
                        Button("关闭自动合并") {
                            perform(String(localized: "设置中"), done: String(localized: "已关闭自动合并")) { try await host.setAutoMerge(cwd: cwd, enabled: false) }
                        }
                    }
                } else {
                    Button("创建 PR…", systemImage: "plus.square.on.square") { creatingPR = true }.disabled(pr?.unavailableReason != nil)
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("更多 Git 操作")
    }

    // MARK: PR bar

    @ViewBuilder private var prBar: some View {
        if let p = pullRequest {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PRStateBadge(pr: p)
                    Button { if let u = URL(string: p.url) { openURL(u) } } label: {
                        Text((p.number.map { "#\($0) " } ?? "") + p.title).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(p.url)
                    Spacer(minLength: 4)
                    if !p.checks.isEmpty {
                        Button { showChecks.toggle() } label: {
                            HStack(spacing: 4) {
                                ChecksDot(status: p.checksStatus)
                                Text(checksSummary(p)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                Image(systemName: showChecks ? "chevron.up" : "chevron.down").font(.system(size: 9))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if p.isOpen {
                        Button("合并") { mergePR(mergeMethod) }
                            .controlSize(.small).buttonStyle(.bordered)
                            .disabled(p.mergeable == "CONFLICTING" || busy != nil)
                            .help(p.mergeable == "CONFLICTING" ? "有冲突，先解决冲突再合并" : "用「\(methodLabel(mergeMethod))」合并，更多方式在 ⋯ 菜单里")
                    }
                }
                .font(.system(size: 12))
                if showChecks {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(p.checks) { c in
                            HStack(spacing: 6) {
                                ChecksDot(status: c.status)
                                Text(c.name).lineLimit(1)
                                Spacer()
                                if let d = c.duration { Text(d).foregroundStyle(Theme.extraMuted) }
                                if let u = c.url.flatMap(URL.init(string:)) {
                                    Link(destination: u) { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain)
                                }
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        } else if let reason = pr?.unavailableReason {
            Text(reason).font(.system(size: 11)).foregroundStyle(Theme.extraMuted)
                .padding(.horizontal, 14).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
        } else if pr != nil, (status?.ahead ?? 0) > 0 {
            HStack {
                Text("本分支领先 \(baseName) \(status?.ahead ?? 0) 个提交，还没有 PR").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("创建 PR…") { creatingPR = true }.controlSize(.small).buttonStyle(.bordered)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    @Environment(\.openURL) private var openURL

    private func checksSummary(_ p: PullRequestInfo) -> String {
        let failed = p.checks.filter { $0.status == "failure" }.count
        let pending = p.checks.filter { $0.status == "pending" }.count
        if failed > 0 { return String(localized: "\(failed) 项失败") }
        if pending > 0 { return String(localized: "\(pending) 项进行中") }
        return String(localized: "检查通过")
    }

    private func methodLabel(_ m: String) -> String {
        switch m { case "merge": String(localized: "合并提交"); case "rebase": "Rebase"; default: "Squash" }
    }

    private func mergePR(_ method: String) {
        perform(String(localized: "合并中"), done: String(localized: "PR 已合并")) { try await host.mergePullRequest(cwd: cwd, method: method) }
    }

    private var commitBar: some View {
        HStack(spacing: 8) {
            TextField("提交说明（留空由 AI 生成）", text: $message).textFieldStyle(.plain)
                .padding(.horizontal, 12).frame(height: 34)
                .compatibleGlassEffect(in: Capsule())
            Button("提交全部") { run("commit", message: message) }
                .compatibleGlassButtonStyle(prominent: true).tint(Theme.accent).disabled(busy != nil)
        }
        .padding(10)
    }

    private func run(_ action: String, message: String? = nil, paths: [String] = []) {
        let labels = ["pull": String(localized: "拉取中"), "push": String(localized: "推送中"), "refresh": String(localized: "刷新中"), "commit": String(localized: "提交中"), "discard": String(localized: "丢弃中"),
                      "pullPush": String(localized: "拉取并推送中"), "mergeFromBase": String(localized: "从 \(baseName) 合并中"), "mergeToBase": String(localized: "合并到 \(baseName) 中")]
        let done = ["pull": String(localized: "已拉取"), "push": String(localized: "已推送"), "commit": String(localized: "已提交"), "discard": String(localized: "已丢弃"),
                    "pullPush": String(localized: "已拉取并推送"), "mergeFromBase": String(localized: "已从 \(baseName) 合并"), "mergeToBase": String(localized: "已合并到 \(baseName)")]
        perform(labels[action] ?? String(localized: "处理中"), done: done[action]) {
            try await host.gitAction(action, cwd: cwd, message: message, paths: paths)
            if action == "commit" { self.message = "" }
        }
    }

    private func perform(_ label: String, done: String?, _ work: @escaping () async throws -> Void) {
        busy = label
        error = nil
        notice = nil
        Task {
            do {
                try await work()
                if let done {
                    notice = done
                    Task { try? await Task.sleep(for: .seconds(4)); if notice == done { notice = nil } }
                }
            } catch { self.error = "\(error)" }
            busy = nil
        }
    }
}

private struct PRStateBadge: View {
    let pr: PullRequestInfo

    var body: some View {
        let (label, color): (String, SwiftUI.Color) = pr.isMerged ? (String(localized: "已合并"), .purple)
            : pr.isDraft ? (String(localized: "草稿"), Theme.muted)
            : pr.isOpen ? (pr.mergeable == "CONFLICTING" ? String(localized: "有冲突") : pr.reviewDecision == "approved" ? String(localized: "已批准") : pr.reviewDecision == "changes_requested" ? String(localized: "需修改") : String(localized: "打开"), pr.mergeable == "CONFLICTING" ? Theme.destructive : Theme.dotSuccess)
            : (String(localized: "已关闭"), Theme.destructive)
        Text(label).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// CI state: green / red / amber (pending) / grey.
struct ChecksDot: View {
    let status: String?

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: SwiftUI.Color {
        switch status {
        case "success": Theme.dotSuccess
        case "failure": Theme.dotDanger
        case "pending": Theme.dotWarning
        default: Theme.extraMuted
        }
    }
}

private struct CreatePullRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let forge: String
    let branch: String
    let base: String
    let onCreate: (String, String) -> Void
    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在 \(forge) 上创建 PR").font(.headline)
            Text("\(branch) → \(base)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
            TextField("标题（留空用最近一次提交的说明）", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText).font(.system(size: 13)).frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建") { onCreate(title, bodyText); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .macOnly { $0.frame(width: 480) }
    }
}

/// Branch commits since base; pick one to see its files, then a file's diff.
private struct CommitHistoryView: View {
    let host: HostStore
    let cwd: String
    let compact: Bool
    @State private var commits: [CommitInfo]?
    @State private var error: String?
    @State private var selectedCommit: String?
    @State private var selectedFile: String?
    @State private var fileDiff: DiffFile?
    @State private var loadingDiff = false

    private var commit: CommitInfo? { commits?.first { $0.sha == selectedCommit } }

    var body: some View {
        ListDetail(compact: compact, showDetail: commit != nil, onBack: { selectedCommit = nil; selectedFile = nil }) {
            Group {
                if let error { Text(error).foregroundStyle(Theme.destructive).padding() }
                else if let commits {
                    if commits.isEmpty { Text("本分支还没有提交").foregroundStyle(Theme.muted).padding() }
                    List(commits, selection: $selectedCommit) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.subject).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(c.shortSha).font(.system(size: 11, design: .monospaced))
                                Text(c.authorName)
                                if let d = c.authorDate { Text(formatTimestamp(d)) }
                                if !c.isOnRemote { Text("未推送").foregroundStyle(Theme.dotWarning) }
                            }
                            .font(.system(size: 11)).foregroundStyle(Theme.extraMuted)
                        }
                        .tag(c.sha)
                        .contextMenu { Button("复制提交号") { Pasteboard.copy(c.sha) } }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } detail: {
            if let commit { commitDetail(commit) }
        }
        .task { await load() }
        .onChange(of: selectedCommit) { selectedFile = nil; fileDiff = nil }
    }

    @ViewBuilder private func commitDetail(_ c: CommitInfo) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.subject).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                Text("\(c.shortSha) · \(c.authorName) · \(c.files.count) 个文件").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if let f = selectedFile {
                HStack {
                    Button { selectedFile = nil; fileDiff = nil } label: { Label("文件列表", systemImage: "chevron.left") }.buttonStyle(.plain)
                    Text(f).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 12).frame(height: 30)
                Divider()
                if let d = fileDiff { StructuredDiffView(file: d, reviewCwd: cwd) }
                else if loadingDiff { ProgressView().frame(maxHeight: .infinity) }
                else { Text("这个文件没有文本改动").foregroundStyle(Theme.muted).frame(maxHeight: .infinity) }
            } else {
                List(c.files) { f in
                    Button { open(c, f.path) } label: {
                        HStack(spacing: 8) {
                            Text(f.letter).font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(f.letter == "A" ? Theme.diffAdd : f.letter == "D" ? Theme.diffRemove : Theme.dotWarning)
                                .frame(width: 14)
                            Text(f.path).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("+\(f.additions)").foregroundStyle(Theme.diffAdd).font(.system(size: 11, design: .monospaced))
                            Text("−\(f.deletions)").foregroundStyle(Theme.diffRemove).font(.system(size: 11, design: .monospaced))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func open(_ c: CommitInfo, _ path: String) {
        selectedFile = path
        fileDiff = nil
        loadingDiff = true
        Task {
            fileDiff = try? await host.commitFileDiff(cwd: cwd, sha: c.sha, path: path)
            loadingDiff = false
        }
    }

    private func load() async {
        do { commits = try await host.commits(cwd: cwd) } catch { self.error = "\(error)" }
    }
}

/// Structured hunks with client-counted line numbers (the protocol sends no unified text).
struct StructuredDiffView: View {
    let file: DiffFile
    /// Set to allow review comments on lines (collected per checkout in AppModel).
    var reviewCwd: String? = nil
    /// Opens the changed file in a file tab.
    var openFile: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @State private var hovered: Int?
    @State private var editing: Int?
    @State private var draft = ""

    private var comments: [ReviewComment] {
        guard let reviewCwd else { return [] }
        return (model.reviewComments[reviewCwd] ?? []).filter { $0.path == file.path }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                if let old = file.oldPath { Text("← " + old).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
                Spacer()
                if reviewCwd != nil { Text("点行号左侧的 + 写审查意见").font(.system(size: 11)).foregroundStyle(Theme.extraMuted) }
                if let openFile, !file.isDeleted {
                    Button { openFile() } label: { Image(systemName: "doc.text") }.buttonStyle(.plain).help("打开文件")
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            if file.status != "ok" {
                ContentUnavailableView(file.status == "binary" ? "二进制文件" : "单个文件改动太大", systemImage: "doc")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.lines.enumerated()), id: \.offset) { i, l in
                            lineRow(i, l)
                            ForEach(comments.filter { matches($0, l) }) { c in commentBox(c) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .textSelection(.enabled)
            }
        }
    }

    private func lineRow(_ i: Int, _ l: DiffLine) -> some View {
        HStack(spacing: 0) {
            if reviewCwd != nil {
                Button { draft = ""; editing = i } label: {
                    Image(systemName: "plus.square.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .opacity(hovered == i && l.kind != .header ? 1 : 0)
                .disabled(l.kind == .header)
                .popover(isPresented: Binding(get: { editing == i }, set: { if !$0 { editing = nil } }), arrowEdge: .trailing) {
                    commentEditor(l).presentationDetents([.medium])
                }
            }
            Text(l.oldNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(Theme.extraMuted)
            Text(l.newNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(Theme.extraMuted)
            Text(l.kind == .add ? "+" : l.kind == .remove ? "−" : " ").foregroundStyle(color(l)).frame(width: 22)
            diffContent(l)
                .fixedSize()
                .padding(.trailing, 16)
        }
        // Never squeeze the gutter: long lines scroll sideways instead.
        .fixedSize(horizontal: true, vertical: false)
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(l))
        .onHover { if $0 { hovered = i } else if hovered == i { hovered = nil } }
        #if os(iOS)
        // The 「+」 only shows on hover; on a touch screen long-press the line instead.
        .contextMenu {
            if reviewCwd != nil, l.kind != .header {
                Button("添加审查意见", systemImage: "text.bubble") { draft = ""; editing = i }
            }
        }
        #endif
    }

    private func commentEditor(_ l: DiffLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 \((l.newNumber ?? l.oldNumber).map(String.init) ?? "") 行的审查意见").font(.system(size: 12, weight: .semibold))
            TextEditor(text: $draft).font(.system(size: 13))
                .macOnly { $0.frame(width: 320, height: 90) }
                #if os(iOS)
                .frame(minHeight: 120)
                #endif
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            HStack {
                Spacer()
                Button("取消") { editing = nil }
                Button("添加") { add(l) }.buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func commentBox(_ c: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(Theme.dotWarning)
            Text(c.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.reviewComments[reviewCwd ?? ""]?.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).help("删除这条意见")
        }
        .padding(8)
        .frame(width: 440, alignment: .leading)
        .background(Theme.dotWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 110).padding(.vertical, 4)
    }

    private var language: SyntaxHighlight.Language? { SyntaxHighlight.language(for: file.path) }

    private func diffContent(_ l: DiffLine) -> Text {
        if l.content.isEmpty { return Text(" ") }
        if l.kind == .header { return Text(l.content).foregroundStyle(Theme.muted) }
        guard let language else { return Text(l.content).foregroundStyle(Theme.foreground) }
        var block = false
        return Text(SyntaxHighlight.line(l.content, language, inBlock: &block))
    }

    private func matches(_ c: ReviewComment, _ l: DiffLine) -> Bool {
        c.removed ? (l.kind == .remove && l.oldNumber == c.line) : (l.kind != .remove && l.newNumber == c.line)
    }

    private func add(_ l: DiffLine) {
        guard let reviewCwd, let line = l.newNumber ?? l.oldNumber else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.reviewComments[reviewCwd, default: []].append(
            ReviewComment(path: file.path, line: line, removed: l.kind == .remove, snippet: l.content, text: text))
        editing = nil
        draft = ""
    }

    private func color(_ l: DiffLine) -> SwiftUI.Color { l.kind == .add ? Theme.diffAdd : l.kind == .remove ? Theme.diffRemove : Theme.muted }
    private func background(_ l: DiffLine) -> SwiftUI.Color {
        switch l.kind {
        case .add: Theme.diffAdd.opacity(0.1)
        case .remove: Theme.diffRemove.opacity(0.1)
        case .header: Theme.surface2
        case .context: .clear
        }
    }
}

/// Side-by-side diff: removed lines on the left, added on the right, paired in order within each change block.
struct SplitDiffView: View {
    let file: DiffFile

    private struct Pair: Identifiable { let id: Int; let old: DiffLine?; let new: DiffLine?; let header: String? }

    private var pairs: [Pair] {
        var out: [Pair] = []
        var removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                out.append(Pair(id: out.count, old: i < removed.count ? removed[i] : nil, new: i < added.count ? added[i] : nil, header: nil))
            }
            removed = []; added = []
        }
        for l in file.lines {
            switch l.kind {
            case .remove: removed.append(l)
            case .add: added.append(l)
            case .context: flush(); out.append(Pair(id: out.count, old: l, new: l, header: nil))
            case .header: flush(); out.append(Pair(id: out.count, old: nil, new: nil, header: l.content))
            }
        }
        flush()
        return out
    }

    private var language: SyntaxHighlight.Language? { SyntaxHighlight.language(for: file.path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("并排视图（审查意见请切回统一视图）").font(.system(size: 11)).foregroundStyle(Theme.extraMuted)
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            if file.status != "ok" {
                ContentUnavailableView(file.status == "binary" ? "二进制文件" : "单个文件改动太大", systemImage: "doc")
            } else {
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(pairs) { p in
                                if let h = p.header {
                                    Text(h).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).background(Theme.surface2)
                                } else {
                                    HStack(spacing: 0) {
                                        side(p.old, number: p.old?.oldNumber, width: geo.size.width / 2)
                                        Rectangle().fill(Theme.border).frame(width: 1)
                                        side(p.new, number: p.new?.newNumber, width: geo.size.width / 2)
                                    }
                                }
                            }
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func side(_ l: DiffLine?, number: Int?, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(Theme.extraMuted)
            content(l).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(width: max(width - 1, 0), alignment: .leading)
        .frame(minHeight: 20)
        .background(l?.kind == .add ? Theme.diffAdd.opacity(0.1) : l?.kind == .remove ? Theme.diffRemove.opacity(0.1) : l == nil ? Theme.surface1 : .clear)
    }

    private func content(_ l: DiffLine?) -> Text {
        guard let l, !l.content.isEmpty else { return Text(" ") }
        guard let language else { return Text(l.content) }
        var block = false
        return Text(SyntaxHighlight.line(l.content, language, inBlock: &block))
    }
}

/// Collected review comments for a checkout, sent to one of the workspace's agents as one message.
/// Official: review comments → "Send feedback".
struct ReviewFeedbackBar: View {
    @Environment(AppModel.self) private var model
    let host: HostStore
    let workspace: Workspace
    @State private var error: String?

    private var comments: [ReviewComment] { model.reviewComments[workspace.directory] ?? [] }
    private var agents: [Agent] {
        host.agents.values.filter { $0.workspaceId == workspace.id && $0.archivedAt == nil }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    var body: some View {
        if !comments.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Theme.dotWarning)
                Text("\(comments.count) 条审查意见").font(.system(size: 12, weight: .medium))
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.destructive).lineLimit(1) }
                Spacer()
                Button("清空") { model.reviewComments[workspace.directory] = nil }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                Menu {
                    ForEach(agents) { a in Button(a.displayTitle) { send(to: a) } }
                    if agents.isEmpty { Text("这个工作区没有会话") }
                } label: {
                    Label("发送反馈", systemImage: "paperplane")
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.surface1)
        }
    }

    private func message() -> String {
        var out = "请根据下面的代码审查意见修改：\n"
        for (i, c) in comments.enumerated() {
            out += "\n\(i + 1). `\(c.location)`\n"
            let snippet = c.snippet.trimmingCharacters(in: .whitespaces)
            if !snippet.isEmpty { out += "   > \(snippet)\n" }
            out += "   \(c.text.replacingOccurrences(of: "\n", with: "\n   "))\n"
        }
        return out
    }

    private func send(to agent: Agent) {
        let text = message()
        Task {
            do {
                try await host.send(text, to: agent.id, steer: agent.status == .running)
                model.reviewComments[workspace.directory] = nil
                model.open(AgentRef(serverId: host.id, agentId: agent.id))
            } catch { self.error = String(localized: "发送失败：\(String(describing: error))") }
        }
    }
}

// MARK: Terminals

#if os(macOS)
struct TerminalHost: NSViewRepresentable {
    let host: HostStore
    let terminalId: String

    func makeCoordinator() -> TerminalBridge { TerminalBridge(host: host, terminalId: terminalId) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        let size = UserDefaults.standard.double(forKey: "terminal.fontSize")
        view.font = NSFont.monospacedSystemFont(ofSize: size > 0 ? size : 12, weight: .regular)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalBridge) { coordinator.detach() }
}
#else
struct TerminalHost: UIViewRepresentable {
    let host: HostStore
    let terminalId: String

    func makeCoordinator() -> TerminalBridge { TerminalBridge(host: host, terminalId: terminalId) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        let size = UserDefaults.standard.double(forKey: "terminal.fontSize")
        view.font = UIFont.monospacedSystemFont(ofSize: size > 0 ? size : 12, weight: .regular)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}

    static func dismantleUIView(_ view: TerminalView, coordinator: TerminalBridge) { coordinator.detach() }
}
#endif

/// SwiftTerm ↔ daemon: output/restore frames in, key bytes and size changes out.
@MainActor
final class TerminalBridge: NSObject, TerminalViewDelegate {
    let host: HostStore
    let terminalId: String
    private weak var view: TerminalView?
    /// While replaying a restore, the emulator's replies (cursor reports etc.) must not reach the PTY.
    private var suppressInput = false
    private var attached = false
    /// Last size SwiftTerm reported; the attach claims it.
    private var size = (cols: 100, rows: 30)

    init(host: HostStore, terminalId: String) {
        self.host = host
        self.terminalId = terminalId
    }

    func attach(_ view: TerminalView) {
        self.view = view
        view.terminalDelegate = self
        Task {
            // Let layout report the real size before claiming it.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                try await host.attachTerminal(terminalId, cols: max(size.cols, 20), rows: max(size.rows, 5)) { [weak self] e in self?.handle(e) }
                attached = true
            } catch {
                view.feed(text: "\r\n[" + String(localized: "无法附着终端：\(String(describing: error))") + "]\r\n")
            }
        }
    }

    func detach() { host.detachTerminal(terminalId) }

    private func handle(_ e: TerminalEvent) {
        guard let view else { return }
        switch e {
        case .output(let d):
            view.feed(byteArray: ArraySlice([UInt8](d)))
        case .restore(let d):
            suppressInput = true
            view.resetToInitialState()
            view.feed(byteArray: ArraySlice([UInt8](d)))
            suppressInput = false
        case .exited(let error):
            view.feed(text: "\r\n\u{1b}[2m[" + (error.map { String(localized: "终端流中断：\($0)") } ?? String(localized: "进程已退出")) + "]\u{1b}[0m\r\n")
        }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated {
            guard !suppressInput else { return }
            host.sendTerminalInput(terminalId, bytes)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            size = (newCols, newRows)
            guard attached else { return }
            Task { try? await host.resizeTerminal(terminalId, cols: newCols, rows: newRows, claim: false) }
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // 终端输出来自远程机器，只打开网页和邮件链接，不打开 file:// 或其他 App 的自定义协议
        if let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }
}

// MARK: Scripts

struct ScriptsView: View {
    let host: HostStore
    let workspace: Workspace
    let openLog: (String) -> Void
    var openInTab: ((String) -> Void)? = nil
    @State private var error: String?

    private var list: [WorkspaceScript] { host.scripts[workspace.id] ?? [] }

    var body: some View {
        List {
            if let error { Banner(level: "error", message: error) }
            if list.isEmpty {
                Text("这个工作区没有配置脚本（仓库根的 paseo.json 里的 scripts）").foregroundStyle(Theme.muted)
            }
            ForEach(list) { s in
                HStack(spacing: 10) {
                    Circle().fill(s.isRunning ? (s.health == "unhealthy" ? Theme.dotWarning : Theme.dotSuccess) : Theme.extraMuted).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.system(size: 14, weight: .medium))
                        Text([s.type == "service" ? String(localized: "服务") : String(localized: "脚本"), s.isRunning ? String(localized: "运行中") : String(localized: "已停止"),
                              s.port.map { String(localized: "端口 \($0)") }, s.exitCode.map { String(localized: "退出码 \($0)") }].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if s.isRunning, !s.urls.isEmpty {
                        Menu {
                            ForEach(s.urls, id: \.url) { u in
                                Section(u.label) {
                                    if let openInTab { Button(String(localized: "在标签中打开 \(u.url)")) { openInTab(u.url) } }
                                    if let url = URL(string: u.url) { Link("在系统浏览器打开", destination: url) }
                                    Button("复制地址") { Pasteboard.copy(u.url) }
                                }
                            }
                        } label: { Image(systemName: "safari") }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            .help("服务地址")
                    }
                    if let t = s.terminalId { Button("日志") { openLog(t) }.compatibleGlassButtonStyle() }
                    if s.isRunning { Button("重启") { restart(s.name) }.compatibleGlassButtonStyle() }
                    Button(s.isRunning ? "停止" : "启动") { act(s.isRunning ? "stop" : "start", s.name) }
                        .compatibleGlassButtonStyle(prominent: true).tint(s.isRunning ? Theme.destructive : Theme.accent)
                }
                .padding(.vertical, 4)
                if s.isRunning, let u = s.urls.first {
                    Text(u.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        .padding(.leading, 18)
                }
            }
        }
        .task { await host.loadScripts(workspaceId: workspace.id) }
    }

    private func restart(_ name: String) {
        Task {
            do {
                try await host.scriptAction("stop", workspaceId: workspace.id, name: name)
                try await host.scriptAction("start", workspaceId: workspace.id, name: name)
                error = nil
            } catch { self.error = "\(error)" }
        }
    }

    private func act(_ action: String, _ name: String) {
        Task {
            do { try await host.scriptAction(action, workspaceId: workspace.id, name: name); error = nil }
            catch { self.error = "\(error)" }
        }
    }
}
