// 告诉装了 live-activity 插件的机器「这台设备刚刚有人在用」，插件据此按 daemon 的官方规则决定推不推普通通知：
// 3 分钟内有设备在用就不推，由 daemon 选中的那台在应用内弹（正看着那个会话时谁都不弹）；都不在用才推到手机。
// 只在用过后的 3 分钟内每 15 秒报一次，之后停报；插件那边超过 45 秒没收到就当不在用（挂起、退出同理）。
// Mac 和 iOS 都报：插件推的是 iPhone / iPad，但要知道你是不是正坐在 Mac 前面。

import Foundation
import PaseoKit

@MainActor
final class PresenceReporter {
    static let shared = PresenceReporter()

    static let pluginId = "live-activity"
    private static let interval: Duration = .seconds(15)
    /// 同 daemon 的 PRESENCE_THRESHOLD_MS。
    private static let window: TimeInterval = 180

    static let deviceId: String = {
        if let id = AppDefaults.store.string(forKey: "presence.deviceId") { return id }
        let id = UUID().uuidString.lowercased()
        AppDefaults.store.set(id, forKey: "presence.deviceId")
        return id
    }()

    private weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    func start(model: AppModel) {
        guard loop == nil else { return }
        self.model = model
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.report()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// 刚操作过（发消息、切回 App）：合并一下连续的触发后马上报，不等下一轮。
    func reportSoon() {
        guard model != nil, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.pending = nil
            self?.report()
        }
    }

    private func report() {
        guard let model else { return }
        let connected = model.hosts.filter { $0.state == .connected }
        let targets = connected.filter { $0.isPluginRunning(Self.pluginId) }
        guard !targets.isEmpty else { return }
        let idle = max(0, Date().timeIntervalSince(model.hosts.map(\.userActivityAt).max() ?? .distantPast))
        guard idle <= Self.window else { return }
        let input: JSONValue = [
            "deviceId": .string(Self.deviceId),
            // 整数毫秒：插件按整数校验。
            "idleMs": .number((idle * 1000).rounded()),
            "servers": .array(connected.map { .string($0.id) }),
        ]
        // 旧版插件没有这个方法，报错忽略（它本来就不看在用状态）。
        for host in targets {
            Task { _ = try? await host.invokePlugin(Self.pluginId, "presence.report", input, timeout: .seconds(10)) }
        }
    }
}
