// Local notifications for agent attention (finished / needs permission / error).
// The daemon's `shouldNotify` picks one present client; when this app isn't frontmost we notify anyway,
// since the Mac app stays connected in the background.

import Foundation
import PaseoKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    var onOpen: ((AgentRef) -> Void)?
    /// A button or the reply field of a notification; the app may be in the background.
    /// 做完（或失败）才返回：App 可能是被通知按钮从后台唤醒的，要等批准真正发到机器再让系统挂起。
    var onAction: ((AgentRef, NotificationAction) async -> Void)?
    /// 这台设备是否直连着某台机器（直连的机器有本地通知；没直连的只能靠插件推来的远程通知）。
    var isHostConnected: ((String) -> Bool)?

    /// allow / deny 带通知对应的待批准请求 id：只批准用户在通知上看到的那个请求，
    /// 它已处理过就不批（不能退而批准当时正好在等的别的请求）。
    enum NotificationAction { case reply(String), allow(requestId: String?), deny(requestId: String?) }

    private enum Category {
        static let finished = "paseo.finished", permission = "paseo.permission"
        static let reply = "paseo.reply", allow = "paseo.allow", deny = "paseo.deny"
    }

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 回复会给会话发消息（可能让它去执行命令），和「允许」一样要先解锁。
        let reply = UNTextInputNotificationAction(identifier: Category.reply, title: "回复", options: [.authenticationRequired],
                                                  textInputButtonTitle: "发送", textInputPlaceholder: "回复这个会话…")
        let allow = UNNotificationAction(identifier: Category.allow, title: "允许", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Category.deny, title: "拒绝", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.finished, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.permission, actions: [allow, deny], intentIdentifiers: []),
        ])
        #if DEBUG
        // PASEO_NO_NOTIFY=1: no permission prompt (simulator screenshots, where nobody can tap it).
        if ProcessInfo.processInfo.environment["PASEO_NO_NOTIFY"] == "1" { return }
        #endif
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// requestId：permission 时这条通知对应的待批准请求（只有一个时才有），按钮只处理它。
    /// 主标题用侧栏的行名（workspaceTitle：工作区标题，没有就是会话标题）；不要副标题；正文是 daemon 给的摘要
    /// （完成时是会话最后一条回复，需要批准时是请求内容，同官方 App）。与 live-activity 插件推来的远程通知同一规则。
    func post(_ e: AttentionEvent, hostLabel: String, workspaceTitle: String, agentTitle: String, requestId: String? = nil) {
        guard UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        switch e.reason {
        case "permission": content.title = "需要你批准 · \(workspaceTitle)"
        case "error": content.title = "出错了 · \(workspaceTitle)"
        default: content.title = "完成 · \(workspaceTitle)"
        }
        content.body = e.body
        content.sound = UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true ? .default : nil
        content.categoryIdentifier = e.reason == "permission" ? Category.permission : Category.finished
        content.threadIdentifier = e.serverId + ":" + e.agentId
        var info: [String: Any] = ["serverId": e.serverId, "agentId": e.agentId]
        if let requestId { info["requestId"] = requestId }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Something done from a notification went wrong; say so instead of failing silently.
    func postFailure(_ title: String, body: String, ref: AgentRef) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = ref.serverId + ":" + ref.agentId
        content.userInfo = ["serverId": ref.serverId, "agentId": ref.agentId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func test() {
        let content = UNMutableNotificationContent()
        content.title = "测试通知"
        content.body = "会话完成、需要批准或出错时会这样提醒你。"
        content.sound = UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func permissionLabel() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: "已允许"
        case .denied: "已拒绝（到系统设置里打开）"
        default: "未决定"
        }
    }

    // 用完成回调的写法并在主线程回调：async 写法的完成回调落在后台线程，iOS 的 UIKit 会断言失败直接闪退
    // （点通知打开 App 时崩在 _updateSnapshotAndStateRestorationWithAction）。macOS 不检查，所以以前没发现。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let s = info["serverId"] as? String, a = info["agentId"] as? String
        let requestId = info["requestId"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = response.actionIdentifier
        Task { @MainActor in
            if let s, let a {
                let ref = AgentRef(serverId: s, agentId: a)
                switch action {
                case Category.reply: if let text, !text.isEmpty { await self.onAction?(ref, .reply(text)) }
                case Category.allow: await self.onAction?(ref, .allow(requestId: requestId))
                case Category.deny: await self.onAction?(ref, .deny(requestId: requestId))
                default: self.onOpen?(ref)
                }
            }
            // 主线程上回调（见上面的说明）。
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        // 插件推来的远程通知：App 在前台、且直连着那台机器时，本地通知已经弹过了，不再重复显示；
        // 没直连那台机器（只经推送机器的关联看到它）时没有本地通知，照常显示。
        let remote = notification.request.trigger is UNPushNotificationTrigger
        let serverId = notification.request.content.userInfo["serverId"] as? String
        DispatchQueue.main.async {
            let covered = MainActor.assumeIsolated { serverId.map { self.isHostConnected?($0) ?? false } ?? false }
            completionHandler(remote && covered ? [] : [.banner, .sound])
        }
    }
}
