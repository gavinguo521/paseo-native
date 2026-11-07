import UIKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

/// 默认使用测试样本渲染真实页面；显式开启 PASEO_LAYOUT_LIVE 后补充本机只读页面检查。
@Suite(.serialized) @MainActor struct PageLayoutTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LAYOUT_LIVE"] == "1"))
    func liveReadOnlyPages() async throws {
        let host = HostStore(offer: .direct(serverId: "", endpoint: "127.0.0.1:6767", useTls: false, password: nil),
                             label: "本机", clientId: "layout-audit-1589", appVersion: "test")
        defer { host.stop() }
        host.start()
        try await host.prepareForCompanionRequest()
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil
        try await capture(NavigationStack { HistoryView() }.environment(model), name: "history-live", scroll: false, waitForRows: true)
        try await capture(NavigationStack { SchedulesView() }.environment(model), name: "schedules-live", scroll: false, waitForSpinner: true)
        try await capture(NavigationStack { ProjectsView() }.environment(model), name: "projects-live", scroll: false, waitForRows: true)
    }

    @Test func pageLayoutGallery() async throws {
        let model = try SidebarTestFixture.model(projects: 2)
        let host = try #require(model.hosts.first)
        host.label = "用于检查长名字布局的开发机器"
        host.plugins = [try #require(PluginInfo(["id": "agent-taskboard", "status": "running", "enabled": true]))]
        let other = HostStore(offer: .direct(serverId: "layout-second", endpoint: "localhost:1", useTls: false, password: nil),
                              label: "第二台开发机器", clientId: "layout", appVersion: "test")
        let multi = AppModel(testHosts: [host, other])
        let workspace = try #require(Workspace(["id": "layout-workspace", "projectId": "layout-project",
            "projectDisplayName": "用于检查窄屏按钮的项目", "projectRootPath": "/test/layout", "workspaceDirectory": "/test/layout",
            "name": "主工作区", "projectKind": "git"]))
        let project = try #require(Project(["projectId": "layout-project", "projectDisplayName": "用于检查窄屏按钮的项目", "projectRootPath": "/test/layout"]))
        host.scripts[workspace.id] = [try #require(WorkspaceScript(["scriptName": "名字比较长的开发服务器", "type": "service", "lifecycle": "running", "terminalId": "layout-terminal", "port": 3000]))]
        let schedule = try #require(Schedule(["id": "layout-schedule", "name": "每个工作日整理项目中所有待处理的 issue", "prompt": "检查任务并汇总结果",
            "cadence": ["expression": "0 9 * * 1-5", "timezone": "Asia/Taipei"], "target": ["type": "new-agent", "config": ["cwd": "/test/layout"]]]))
        let permission = try #require(PermissionRequest(["id": "layout-permission", "kind": "tool", "title": "需要批准执行命令",
            "actions": [["id": "deny", "label": "拒绝", "behavior": "deny"],
                        ["id": "once", "label": "允许一次", "behavior": "allow"],
                        ["id": "session", "label": "本会话始终允许", "behavior": "allow"]]]))
        let pages: [(String, AnyView)] = [
            ("sidebar", AnyView(NavigationStack { SidebarView(showSettings: .constant(false), showAddHost: .constant(false)) })),
            ("schedules", AnyView(NavigationStack(path: .constant([true])) {
                Text("首页").navigationDestination(for: Bool.self) { _ in SchedulesView() }
            })),
            ("overview", AnyView(NavigationStack { SessionOverview() })),
            ("usage", AnyView(NavigationStack { UsageView() })),
            ("settings", AnyView(SettingsView(showAddHost: .constant(false)))),
            ("hosts", AnyView(HostsView(showAddHost: .constant(false), tabPicker: .constant(1)))),
            ("host-detail", AnyView(NavigationStack { HostDetailView(host: host) })),
            ("daemon-settings", AnyView(NavigationStack { DaemonSettingsView(host: host) })),
            ("push-key", AnyView(APNsKeySheet(host: host, perEnvironment: true, onSaved: {}))),
            ("permission", AnyView(ScrollView { PermissionCard(host: host, agentId: "layout-agent", request: permission).padding() })),
            ("add-host", AnyView(AddHostView())),
            ("add-project", AnyView(AddProjectView())),
            ("projects", AnyView(NavigationStack { ProjectsView() })),
            ("new-chat", AnyView(NavigationStack { NewChatView() })),
            ("commands", AnyView(CommandPalette(showSettings: .constant(false)))),
            ("import", AnyView(ImportSessionView(host: host, cwd: workspace.directory))),
            ("schedule-form", AnyView(ScheduleForm(target: .edit(host.id, schedule), onDone: {}))),
            ("schedule-row", AnyView(List { ScheduleRow(item: ScheduleListItem(host: host, schedule: schedule), gone: true, showHost: true) })),
            ("archived-badge", AnyView(List { HStack { Text("一条用于检查归档标签高度的长会话标题").lineLimit(1); Spacer(); ArchivedSessionBadge() } })),
            ("edit-project", AnyView(ProjectEditSheet(host: host, project: project))),
            ("files", AnyView(FilesView(host: host, workspace: workspace, compact: true))),
            ("changes", AnyView(ChangesView(host: host, workspace: workspace, compact: true))),
            ("scripts", AnyView(ScriptsView(host: host, workspace: workspace, openLog: { _ in }))),
            ("source", AnyView(FileSourceView(text: "let title = \"检查文件查看器\"\nprint(title)", language: "swift"))),
            ("subagent", AnyView(ProviderSubagentTab(host: host, workspace: workspace, parentAgentId: "p0-w0-s0", subagentId: "layout-child"))),
            ("select-text", AnyView(SelectTextSheet(text: String(repeating: "用于检查窄屏下的文字选择和复制按钮。\n\n", count: 20)))),
            ("report", AnyView(TextReportSheet(title: "诊断报告", text: "用于检查诊断报告的复制和完成按钮。"))),
            ("board", AnyView(NavigationStack { BoardView(workspace: nil) })),
            ("tools", AnyView(ToolDetailsPanel(rows: [], selectedID: .constant(nil))))
        ]
        for (name, page) in pages {
            try await capture(page.environment(multi), name: name, scroll: ["settings", "host-detail", "daemon-settings", "schedule-form"].contains(name))
        }
        try await capture(NavigationStack { SidebarView(showSettings: .constant(false), showAddHost: .constant(false)) }
            .frame(width: 320).frame(maxWidth: .infinity, alignment: .leading).environment(multi),
            name: "sidebar-compact", scroll: false)
        multi.destination = .history
        try await capture(NavigationStack { SidebarView(showSettings: .constant(false), showAddHost: .constant(false)) }
            .environment(multi), name: "sidebar-return-history", scroll: false)
    }

    @Test func workspaceHierarchyGallery() async throws {
        let model = try SidebarTestFixture.model(projects: 1)
        let host = try #require(model.hosts.first)
        // 即使残留旧版本的展开状态，单会话工作区也只显示一行。
        host.agents = host.agents.filter { $0.key.hasSuffix("s0") }
        let children = model.sidebarSessionIndex()
        #expect(children.count == 8)
        #expect(children.values.allSatisfy { $0.count == 1 })
        let groups = model.groups
        model.expandedSessionRows = Set(groups.flatMap(\.rows).map {
            AppModel.rowKey(serverId: $0.serverId, agent: $0.agent)
        })
        try await capture(NavigationStack { SidebarView(showSettings: .constant(false), showAddHost: .constant(false)) }
            .environment(model), name: "sidebar-single-session-direct", scroll: false)
    }

    @Test func workspaceNameIsDistinctFromSessionTitle() async throws {
        let agent = try #require(Agent(["id": "title-session", "workspaceId": "title-workspace",
            "cwd": "/test/project/main", "title": "讨论跨段复制", "status": "idle"]))
        let workspace = try #require(Workspace(["id": "title-workspace", "name": "主工作区",
            "title": "讨论跨段复制", "workspaceDirectory": "/test/project/main"]))
        let parent = SessionRow(agent: agent, bucket: agent.bucket, selected: false,
            workspace: workspace, childCount: 2, expanded: true, action: {})
        let single = SessionRow(agent: agent, bucket: agent.bucket, selected: true,
            workspace: workspace, action: {})
        let child = SessionRow(agent: agent, bucket: agent.bucket, selected: true,
            useAgentTitle: true, depth: 1, action: {})
        #expect(parent.title == "主工作区")
        #expect(single.title == "主工作区")
        #expect(child.title == "讨论跨段复制")
        #expect(SessionRow(agent: agent, bucket: agent.bucket, selected: false, action: {}).title == "main")
        try await capture(VStack(spacing: 0) { parent; child }.padding(),
            name: "workspace-and-session-titles", scroll: false)
        try await capture(single.padding(), name: "single-workspace-title", scroll: false)
    }

    @Test func suggestionPlaceholderGallery() async throws {
        try await capture(SuggestionComposerFixture(), name: "suggestion-composer", scroll: false)
    }

    @Test func compactControlsRetainReadableSize() throws {
        let badge = UIHostingController(rootView: ArchivedSessionBadge())
        let size = badge.sizeThatFits(in: CGSize(width: 390, height: 100))
        #expect(size.height >= 26)
        let button = UIHostingController(rootView: Image(systemName: "xmark").mobileTouchTarget())
        let target = button.sizeThatFits(in: CGSize(width: 390, height: 100))
        #expect(target.width >= 44)
        #expect(target.height >= 44)
        let model = try SidebarTestFixture.model(projects: 0)
        let host = try #require(model.hosts.first)
        let sheet = UIHostingController(rootView: APNsKeySheet(host: host, perEnvironment: true, onSaved: {}))
        let sheetSize = sheet.sizeThatFits(in: CGSize(width: 375, height: 812))
        #expect(sheetSize.width <= 375, "配置弹窗不能沿用桌面的最小宽度")
    }

    private func capture<V: View>(_ content: V, name: String, scroll: Bool, waitForRows: Bool = false, waitForSpinner: Bool = false) async throws {
        let scene = try await layoutTestScene()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let controller = UIHostingController(rootView: content.environment(\.colorScheme, .light))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let animations = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animations) }
        defer { window.isHidden = true; window.rootViewController = nil }
        // 让 SwiftUI 的任务、列表和导航栏完成本轮布局，不靠固定延时取图。
        for _ in 0..<12 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            controller.view.layoutIfNeeded()
        }
        if name == "suggestion-composer" {
            func inspect(_ view: UIView) {
                if let editor = view as? ComposerUITextView {
                    #expect(editor.placeholderLabel.superview === editor)
                    #expect(editor.placeholderLabel.text?.contains("请继续检查") == true)
                    #expect(!editor.placeholderLabel.isHidden)
                    #expect(editor.placeholderLabel.frame.width > 100)
                    #expect(editor.placeholderLabel.frame.height > 0)
                }
                view.subviews.forEach(inspect)
            }
            inspect(controller.view)
        }
        if waitForRows {
            func hasRows(_ view: UIView) -> Bool {
                if let list = view as? UICollectionView, list.visibleCells.count > 1 { return true }
                return view.subviews.contains(where: hasRows)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !hasRows(controller.view), ContinuousClock.now < deadline {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                controller.view.layoutIfNeeded()
            }
            #expect(hasRows(controller.view), "真实页面须加载出列表内容后才能取图")
        }
        if waitForSpinner {
            func spinning(_ view: UIView) -> Bool {
                if let spinner = view as? UIActivityIndicatorView, spinner.isAnimating { return true }
                return view.subviews.contains(where: spinning)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while spinning(controller.view), ContinuousClock.now < deadline {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                controller.view.layoutIfNeeded()
            }
            #expect(!spinning(controller.view), "加载结束后再检查空状态操作按钮")
        }
        #expect(controller.view.bounds.width == window.bounds.width)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        func save(_ suffix: String) throws {
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image {
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                _ = $0
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("layout-1589-\(name)-\(device)\(suffix).png")
            try #require(image.pngData()).write(to: url)
            print("LAYOUT_SCREENSHOT \(url.path)")
        }
        try save("")
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        if scroll, let list = scrollViews(controller.view).first(where: { $0.contentSize.height > $0.bounds.height }) {
            var page = 0
            while page < 8 {
                let bottom = max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                let next = min(bottom, list.contentOffset.y + list.bounds.height * 0.75)
                if next <= list.contentOffset.y + 1 { break }
                list.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                controller.view.layoutIfNeeded()
                await Task.yield()
                page += 1
                try save("-\(page)")
            }
        }
    }
}

/// 测试宿主的场景连接与 Swift Testing 启动可能先后交错；等待实际场景，不固定 sleep。
@MainActor func layoutTestScene() async throws -> UIWindowScene {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first == nil,
          ContinuousClock.now < deadline {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    return try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
}

private struct SuggestionComposerFixture: View {
    @State private var text = ""
    @State private var images: [ImageAttachment] = []
    @State private var placeholder = "发送消息"
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            Spacer()
            ComposerShell(text: $text, images: $images, focused: $focused, error: nil, placeholder: placeholder) {
                Button("用这句") { text = placeholder }
            } controls: { Text("模型") } trailing: { Image(systemName: "paperplane.fill") } onSubmit: {}
        }.padding()
        .task { placeholder = "请继续检查输入栏的显示效果，并确认 iPhone、iPad 和 Mac 上都能看到下一句建议。" }
    }
}
