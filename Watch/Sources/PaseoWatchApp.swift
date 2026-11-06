import PaseoWatchBridge
import SwiftUI
import UserNotifications
import WatchKit

@main
struct PaseoWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var client = WatchClient.shared

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(client)
                .tint(WatchTheme.accent)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // iPhone forwards existing completion/permission notifications. Open the exact session to
        // review a request or dictate a reply; no independent APNs registration is required.
        let open = UNNotificationAction(identifier: "paseo.watch.open", title: String(localized: "查看会话"), options: .foreground)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "paseo.finished", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "paseo.permission", actions: [open], intentIdentifiers: []),
        ])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let hostID = info["serverId"] as? String, agentID = info["agentId"] as? String
        Task { @MainActor in
            if let hostID, let agentID { WatchClient.shared.pendingRoute = .init(hostID: hostID, agentID: agentID) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
