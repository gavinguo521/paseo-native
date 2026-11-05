import PaseoKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    /// iPhone: the split view collapses to one column; choosing something shows the content column.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showSettings = false
    @State private var showAddHost = false
    @State private var showPalette = false
    @State private var showFileSearch = false
    @State private var importTarget: WorkspaceRef?
    @State private var importing = false
    @State private var addingProject = false
    @State private var showShortcuts = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("fontStep") private var fontStep = 0
    @AppStorage("contentWidth") private var contentWidth = 820
    @AppStorage("dockBadge") private var dockBadge = true
    /// Machines already asked about companion plugins (comma-separated server ids).
    @AppStorage("companions.asked") private var companionsAsked = ""
    @State private var companionPrompt: CompanionPrompt?

    private var companionKey: String {
        model.hosts.map { "\($0.id):\($0.state == .connected):\($0.pluginsLoaded)" }.joined(separator: ",")
    }

    /// First connection to a machine without the companion plugins: offer them once.
    private func checkCompanions() {
        guard companionPrompt == nil else { return }
        #if DEBUG
        // PASEO_OPEN=<page>:companions previews the prompt with every companion listed.
        if model.debugSheet == "companions", let h = model.hosts.first(where: { $0.pluginsLoaded }) {
            model.debugSheet = nil
            companionPrompt = CompanionPrompt(host: h, plugins: CompanionPlugins.all)
            return
        }
        #endif
        var asked = Set(companionsAsked.split(separator: ",").map(String.init))
        for h in model.hosts where !asked.contains(h.id) && h.pluginsLoaded && h.state == .connected {
            asked.insert(h.id)
            companionsAsked = asked.sorted().joined(separator: ",")
            let missing = CompanionPlugins.missing(on: h)
            // Only recommended plugins are worth interrupting for; optional ones wait on the plugin page.
            if missing.contains(where: \.recommended) { companionPrompt = CompanionPrompt(host: h, plugins: missing); return }
        }
    }

    struct CompanionPrompt: Identifiable {
        let host: HostStore
        let plugins: [CompanionPlugin]
        var id: String { host.id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            SidebarView(showSettings: $showSettings, showAddHost: $showAddHost)
        } detail: {
            // Theme sizes are read statically; rebuilding on change applies them.
            detail.id("\(fontStep)-\(contentWidth)")
        }
        .modifier(CompactColumnFollower(destination: model.destination, reveal: model.revealDetail, column: $compactColumn))
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .onReceive(NotificationCenter.default.publisher(for: .cycleAppearance)) { _ in
            appearance = appearance == "system" ? "light" : appearance == "light" ? "dark" : "system"
        }
        #if os(macOS)
        .onChange(of: attentionCount, initial: true) { _, n in NSApp.dockTile.badgeLabel = dockBadge && n > 0 ? "\(n)" : nil }
        .onChange(of: dockBadge) { _, on in NSApp.dockTile.badgeLabel = on && attentionCount > 0 ? "\(attentionCount)" : nil }
        #endif
        .tint(Theme.accent)
        .sheet(isPresented: $showAddHost) { AddHostView() }
        .sheet(isPresented: $showSettings) { SettingsView(showAddHost: $showAddHost) }
        .sheet(isPresented: $showPalette) { CommandPalette(showSettings: $showSettings) }
        .sheet(isPresented: $showFileSearch) { CommandPalette(showSettings: $showSettings, filesMode: true) }
        .onReceive(NotificationCenter.default.publisher(for: .searchFiles)) { _ in showFileSearch = true }
        .onReceive(NotificationCenter.default.publisher(for: .addProject)) { _ in addingProject = true }
        .sheet(isPresented: $addingProject) { AddProjectView() }
        .onReceive(NotificationCenter.default.publisher(for: .openFileTab)) { n in
            if let (ref, path) = n.object as? (WorkspaceRef, String) { model.openFile(path, line: nil, in: ref) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSessions)) { n in
            importTarget = (n.object as? WorkspaceRef) ?? model.currentWorkspace
            importing = true
        }
        .sheet(isPresented: $importing) {
            if let host = (importTarget.flatMap { model.host($0.serverId) } ?? model.visibleHosts.first) {
                ImportSessionView(host: host, cwd: importTarget.flatMap { model.workspace($0)?.directory })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in showPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { _ in showShortcuts = true }
        .sheet(isPresented: $showShortcuts) { ShortcutsHelpView() }
        .modifier(CompanionPromptModifier(prompt: $companionPrompt, key: companionKey, check: checkCompanions))
        .task {
            #if DEBUG && os(iOS)
            // PASEO_QR_IMAGE=<png>: run the photo QR reader on that file and log whether it is a pairing link.
            if let path = ProcessInfo.processInfo.environment["PASEO_QR_IMAGE"], let data = FileManager.default.contents(atPath: path) {
                let codes = await QRScannerSheet.qrCodes(in: data)
                print("PASEO_QR_IMAGE codes:", codes.count, "pairing:", codes.contains { (try? PairingOffer.parse($0)) != nil })
            }
            // PASEO_ORIENTATION=landscape: rotate the simulator's window (its rotation is only in the Simulator menu).
            if ProcessInfo.processInfo.environment["PASEO_ORIENTATION"] == "landscape" {
                try? await Task.sleep(for: .seconds(1))
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { print("PASEO_ORIENTATION failed:", $0) }
                }
            }
            // PASEO_RENDER_ACTIVITY=<目录>：连上机器后用真实数据渲染灵动岛（收起 / 展开）和锁屏实时活动的大致样子，写成 PNG 后退出。
            // 模拟器截图不画灵动岛区域，靠它核对排版；圆角黑底只是近似系统外框。
            if let dir = ProcessInfo.processInfo.environment["PASEO_RENDER_ACTIVITY"] {
                try? await Task.sleep(for: .seconds(8))
                let s = ProcessInfo.processInfo.environment["PASEO_ACTIVITY_DEMO"] == "1" ? .preview : LiveActivityController.snapshot(model)
                let compact = HStack(spacing: 0) {
                    HStack(spacing: 3) { ActivityStatusIcon(state: s); Text("\(s.running + s.waiting)").monospacedDigit() }
                    Spacer(minLength: 126)
                    ActivityCompactTrailing(state: s)
                }
                .padding(.horizontal, 14).frame(width: 250, height: 37)
                .background(Capsule().fill(.black)).foregroundStyle(.white).environment(\.colorScheme, .dark)
                let expanded = VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label { Text("Paseo").font(.headline) } icon: { ActivityStatusIcon(state: s) }
                        Spacer()
                        ActivitySummary(state: s).font(.subheadline)
                    }
                    ActivityRows(state: s, limit: 3)
                    ActivityFootnote(state: s, isStale: false)
                }
                .padding(18).frame(width: 371)
                .background(RoundedRectangle(cornerRadius: 44).fill(.black)).foregroundStyle(.white).environment(\.colorScheme, .dark)
                let lock = ActivityLockScreen(state: s, isStale: false).frame(width: 360)
                    .background(RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)).padding(20)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
                for (name, view) in [("compact", AnyView(compact)), ("expanded", AnyView(expanded)), ("lock", AnyView(lock))] {
                    let r = ImageRenderer(content: view.padding(10))
                    r.scale = 3
                    try? r.uiImage?.pngData()?.write(to: URL(fileURLWithPath: dir + "/activity-" + name + ".png"))
                }
                print("PASEO_RENDER_ACTIVITY", s.running, s.waiting, s.failed, s.rows.map(\.title))
                exit(0)
            }
            #endif
            #if DEBUG && os(macOS)
            // Development: PASEO_RENDER_MD=<file.md> renders that Markdown to <file.md>.png at reply width and quits.
            if let path = ProcessInfo.processInfo.environment["PASEO_RENDER_MD"],
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let renderer = ImageRenderer(content: MarkdownView(text: text).frame(width: 760).padding(20).background(Theme.surface0)
                    .environment(\.findQuery, ProcessInfo.processInfo.environment["PASEO_FIND"] ?? ""))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path + ".png"))
                }
                exit(0)
            }
            // PASEO_RENDER_QUESTION=<request.json> [PASEO_RENDER_WIDTH=402]: renders a permission / question card to
            // <request.json>.png at that width (phone by default) and quits; needs a saved machine for the card's host.
            if let path = ProcessInfo.processInfo.environment["PASEO_RENDER_QUESTION"], let host = model.hosts.first {
                renderQuestionCard(path, host: host)
            }
            if let path = ProcessInfo.processInfo.environment["PASEO_RENDER_LEGEND"] {
                let renderer = ImageRenderer(content: MarkerLegend())
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            // PASEO_RENDER_MENUBAR=<png> renders the menu bar panel once the hosts have loaded, then quits.
            if let path = ProcessInfo.processInfo.environment["PASEO_RENDER_MENUBAR"] {
                try? await Task.sleep(for: .seconds(6))
                let renderer = ImageRenderer(content: MenuBarContent().environment(model).padding(8)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            // PASEO_DUMP_PROVIDERS=<file>: after 15 s writes each host's provider entries, then quits.
            if let path = ProcessInfo.processInfo.environment["PASEO_DUMP_PROVIDERS"] { await model.dumpProviders(to: path) }
            // PASEO_DUMP_DOCK_MENU=<file> writes the Dock menu's items (asked through NSApp.delegate), then quits.
            if let path = ProcessInfo.processInfo.environment["PASEO_DUMP_DOCK_MENU"] { await AppDelegate.dumpDockMenu(to: path) }
            // PASEO_WINDOW_WIDTH=<points> resizes the window, to check layouts at other widths.
            if let w = ProcessInfo.processInfo.environment["PASEO_WINDOW_WIDTH"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(1))
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                    var f = win.frame
                    f.size.width = w
                    win.setFrame(f, display: true)
                }
            }
            #endif
            try? await Task.sleep(for: .seconds(2))
            if model.debugPane == "palette" { showPalette = true }
            if model.debugPane == "fileSearch" { showFileSearch = true }
            switch model.debugSheet {
            case "settings": showSettings = true
            case "hosts": model.settingsTab = 1; showSettings = true
            case "palette": showPalette = true
            case "addHost": showAddHost = true
            case "shortcuts": showShortcuts = true
            case "addProject": addingProject = true
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
    }

    /// Sessions waiting on the user (needs input, failed, finished unread).
    private var attentionCount: Int {
        model.hosts.reduce(0) { n, h in
            n + h.agents.values.filter { $0.archivedAt == nil && !h.isNested($0) && ($0.bucket == .needsInput || $0.bucket == .failed || $0.bucket == .attention) }.count
        }
    }

    @ViewBuilder private var detail: some View {
        // One view per workspace, so switching tabs inside it keeps the tab bar in place.
        if let ws = model.currentWorkspace, let host = model.host(ws.serverId) {
            WorkspaceTabsView(host: host, ref: ws).id(ws)
        } else {
            destinationView
        }
    }

    @ViewBuilder private var destinationView: some View {
        switch model.destination {
        case .workspace:
            missing
        case .agent(let ref):
            if let host = model.host(ref.serverId) {
                AgentDetailView(host: host, ref: ref).id(ref)
            } else {
                missing
            }
        case .newChat:
            NewChatView()
        case .projects:
            ProjectsView()
        case .history:
            HistoryView()
        case .schedules:
            SchedulesView()
        case .usage:
            UsageView()
        case .board:
            BoardView(workspace: model.boardWorkspace).id(model.boardWorkspace)
        case nil:
            missing
        }
    }

    /// Start page with the common first steps (official welcome / open-project screen).
    private var missing: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.muted)
            Text(model.hosts.isEmpty ? "先添加一台机器" : "从左侧选一个会话，或者开始新的").font(.system(size: 17, weight: .medium))
            HStack(spacing: 10) {
                if model.hosts.isEmpty {
                    Button("添加机器…") { showAddHost = true }.buttonStyle(.glassProminent).tint(Theme.accent)
                } else {
                    Button("新聊天") { model.destination = .newChat }.buttonStyle(.glassProminent).tint(Theme.accent)
                    Button("导入外部会话…") { NotificationCenter.default.post(name: .importSessions, object: nil) }.buttonStyle(.glass)
                    Button("项目") { model.destination = .projects }.buttonStyle(.glass)
                }
            }
            Text("⌘K 命令面板 · ⌘/ 快捷键").font(.system(size: 12)).foregroundStyle(Theme.extraMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompanionPromptModifier: ViewModifier {
    @Binding var prompt: RootView.CompanionPrompt?
    let key: String
    let check: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $prompt) { CompanionPluginsSheet(host: $0.host, plugins: $0.plugins) }
            .onChange(of: key, initial: true) { check() }
    }
}

/// iPhone: show the content column whenever something is chosen in the sidebar.
private struct CompactColumnFollower: ViewModifier {
    let destination: Destination?
    /// Tapping the row already shown changes no destination; this still brings the content page back.
    let reveal: Int
    @Binding var column: NavigationSplitViewColumn

    func body(content: Content) -> some View {
        content
            .onChange(of: destination, initial: true) { _, d in column = d == nil ? .sidebar : .detail }
            .onChange(of: reveal) { if destination != nil { column = .detail } }
    }
}

#if DEBUG && os(macOS)
/// PASEO_RENDER_QUESTION: renders the permission / question card in `<path>` (a request JSON) to `<path>.png`, then quits.
@MainActor private func renderQuestionCard(_ path: String, host: HostStore) {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONDecoder().decode(JSONValue.self, from: data), let request = PermissionRequest(json) else { exit(1) }
    let widthText: String = ProcessInfo.processInfo.environment["PASEO_RENDER_WIDTH"] ?? "402"
    let width: CGFloat = CGFloat(Double(widthText) ?? 402)
    let card = PermissionCard(host: host, agentId: "preview", request: request)
        .frame(width: width - 32).padding(16).background(Theme.surface0).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: card)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path + ".png"))
    }
    exit(0)
}
#endif
