import SwiftUI

@main
struct PaseoApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @AppStorage("menuBarExtra") private var menuBarExtra = true
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var pushDelegate: PushDelegate
    #endif

    static let mainWindowId = "main"

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        #if os(iOS)
        // 在这里而不是窗口出现后启动：实时活动的推送令牌可能在后台把 App 唤醒，要能马上交给插件。
        LiveActivityController.shared.start(model: model)
        #endif
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowId) {
            RootView()
                .environment(model)
                .task {
                    #if os(macOS)
                    appDelegate.model = model
                    UpdateChecker.shared.startAutomaticChecks()
                    #endif
                    model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setAppVisible(phase == .active)
                    #if os(macOS)
                    if phase == .active { UpdateChecker.shared.checkOnActivation() }
                    #endif
                    #if os(iOS)
                    if phase == .active { LiveActivityController.shared.sync() }
                    #endif
                }
                // 点灵动岛 / 锁屏实时活动里的会话；Mac 上从终端或别的 App 打开 paseonative:// 链接也走这里。
                .onOpenURL { url in
                    if let (s, a) = PaseoActivityLink.parse(url) {
                        model.revealDetail += 1
                        model.open(AgentRef(serverId: s, agentId: a))
                    }
                }
                #if os(macOS)
                // 链接交给已打开的窗口处理。不写这句的话，SwiftUI 每收到一个链接就新开一个窗口，而且新窗口什么都没选中。
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 880)
        #endif
        .commands { AppCommands(model: model) }
        #if os(macOS)
        MenuBarExtra(isInserted: $menuBarExtra) {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

/// Menu bar and shortcuts. Official: keyboard/keyboard-shortcuts.ts.
struct AppCommands: Commands {
    let model: AppModel

    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }
    private func tab(_ command: WorkspaceTabCommand) { NotificationCenter.default.post(name: .workspaceTabCommand, object: command) }

    private func togglePin() {
        guard let ref = model.currentWorkspace, let host = model.host(ref.serverId), let w = host.workspaces[ref.workspaceId] else { return }
        Task { try? await host.pinWorkspace(w.id, pinned: w.pinnedAt == nil) }
    }

    private func closeWindow() {
        #if os(macOS)
        NSApp.keyWindow?.performClose(nil)
        #endif
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新聊天") { model.destination = .newChat }.keyboardShortcut("n", modifiers: .command)
        }
        #if os(macOS)
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { Task { await UpdateChecker.shared.check(manual: true) } }
        }
        #endif
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { post(.openSettings) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("显示/隐藏侧栏") { post(.toggleSidebar) }.keyboardShortcut("b", modifiers: .command)
            Button("显示/隐藏右栏") { tab(.toggleExplorer) }.keyboardShortcut("e", modifiers: .command)
            Button("切换主题（跟随系统 / 浅色 / 深色）") { post(.cycleAppearance) }.keyboardShortcut("t", modifiers: [.command, .option])
        }
        CommandMenu("前往") {
            Button("命令面板…") { post(.openCommandPalette) }.keyboardShortcut("k", modifiers: .command)
            Button("搜索文件…") { post(.searchFiles) }.keyboardShortcut("p", modifiers: .command)
            Button("会话历史") { model.destination = .history }.keyboardShortcut("y", modifiers: .command)
            Button("项目") { model.destination = .projects }.keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("上一个会话") { model.step(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("下一个会话") { model.step(1) }.keyboardShortcut("]", modifiers: .command)
            ForEach(1..<10) { n in
                Button("第 \(n) 个会话") {
                    let list = model.orderedSessions
                    if list.indices.contains(n - 1) { model.open(list[n - 1]) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("关闭标签") {
                if model.currentWorkspace != nil { tab(.closeCurrent) } else { closeWindow() }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("键盘快捷键") { post(.showShortcuts) }.keyboardShortcut("/", modifiers: .command)
        }
        CommandMenu("标签") {
            Button("新会话标签") { tab(.newAgent) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("在当前工作区新建会话") { tab(.newAgent) }.keyboardShortcut("o", modifiers: .command)
            Button("新终端") { tab(.newTerminal) }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("改动") { tab(.changes) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("文件") { tab(.files) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("浏览器…") { tab(.browser) }.keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("上一个标签") { tab(.step(-1)) }.keyboardShortcut("[", modifiers: [.option, .shift])
            Button("下一个标签") { tab(.step(1)) }.keyboardShortcut("]", modifiers: [.option, .shift])
            ForEach(1..<10) { n in
                Button("第 \(n) 个标签") { tab(.index(n - 1)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
            }
        }
        CommandMenu("会话") {
            Button("聚焦输入框") { post(.focusComposer) }.keyboardShortcut("l", modifiers: .command)
            Button("在会话中查找") { post(.findInSession) }.keyboardShortcut("f", modifiers: .command)
            Button("提问大纲") { post(.showOutline) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("重命名…") { post(.renameCurrent) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("归档") { post(.archiveCurrent) }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            Button("置顶/取消置顶工作区") { togglePin() }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

#if os(iOS)
/// 普通推送（完成 / 需要批准 / 出错）的设备令牌：交给 live-activity 插件，App 被挂起后由它经 APNs 发通知。
final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        LiveActivityController.shared.setAlertToken(LiveActivityController.hex(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("remote notifications register failed:", error)
    }
}
#endif
