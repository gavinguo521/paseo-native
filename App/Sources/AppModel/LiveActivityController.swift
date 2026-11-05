// iOS 实时活动（灵动岛 / 锁屏）：所有机器的会话合成一个活动。
// - App 在前台时由这里按本地数据启动、更新、结束。
// - App 不在前台时靠 daemon 插件 live-activity 经 APNs 推送（插件仓库 paseo-plugins/live-activity）：
//   这里把「远程启动令牌」和当前活动的推送令牌交给其中一台装了插件的机器（推送机器），
//   它合并自己和已关联机器（connected hosts）的会话，状态变了就推。其他装了插件的机器会被注销，免得几台一起推、互相覆盖。
// - 后台没人更新时，过了 staleDate 系统会把活动标成「可能不是最新」，不会一直假装在跑。

#if os(iOS)
import ActivityKit
import Foundation
import Observation
import PaseoKit
import UIKit
import UserNotifications

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    typealias State = PaseoActivityAttributes.ContentState
    typealias Row = PaseoActivityAttributes.Row

    static let pluginId = "live-activity"
    static let enabledKey = "liveActivity"
    /// 用户在设置里指定的推送机器（serverId）；没指定或那台没装插件时用列表里第一台装了插件的。
    static let pusherKey = "liveActivity.pusher"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 每次更新后多久算过时；App 在前台时每隔 refreshInterval 续一次。
    private let staleAfter: TimeInterval = 15 * 60
    private let refreshInterval: TimeInterval = 5 * 60
    /// 全部结束后锁屏上「全部完成」留多久。
    private let dismissAfter: TimeInterval = 5 * 60

    private weak var model: AppModel?
    private var applyTask: Task<Void, Never>?
    private var lastApplied: (state: State, at: Date)?

    // 推送令牌（小写 hex）。
    private var pushToStartToken: String?
    /// 普通推送的设备令牌（registerForRemoteNotifications）。
    private var alertToken: String?
    /// 插件已收下普通推送令牌、且那个环境配了密钥：App 不在前台时就不再自己弹本地通知，免得和插件推来的重复。
    private(set) var remoteAlertsReady = false
    private var activityToken: String?
    private var activityTokenOwner: String?
    private var watched: Set<String> = []
    /// 上次成功交给插件的内容，没变就不再发。
    private var lastRegistration: String?
    /// 已确认注销本设备的机器；推送机器或开关变了就重新来（上次没注销成功的，下次连上再发）。
    private var unregistered: Set<String> = []
    private var unregisterEpoch = ""
    private var lastPusherId: String?
    private var registering = false
    private var registerAgain = false

    /// 每台设备一个，插件按它区分 iPhone / iPad。
    static let deviceId: String = {
        if let id = UserDefaults.standard.string(forKey: "liveActivity.deviceId") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "liveActivity.deviceId")
        return id
    }()

    /// APNs 环境：看描述文件里的 aps-environment（Xcode 直装是 development，TestFlight / Ad Hoc 是 production）。
    static let apsEnvironment: String = {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
           let key = text.range(of: "<key>aps-environment</key>") {
            let rest = text[key.upperBound...]
            if let a = rest.range(of: "<string>"), let b = rest.range(of: "</string>", range: a.upperBound..<rest.endIndex) {
                return String(rest[a.upperBound..<b.lowerBound])
            }
        }
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }()

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        observe()
        observeTokens()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                self?.refreshIfDue()
                await self?.register()
            }
        }
    }

    func setAlertToken(_ token: String) {
        guard token != alertToken else { return }
        alertToken = token
        print("live-activity alert token", token.prefix(8))
        Task { await register() }
    }

    /// 用户关了「通知我」时不把普通推送令牌交给插件（发 null 清掉）。
    private static var notificationsEnabled: Bool { UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true }

    /// 设置里开关变化或回到前台时调用。
    func sync() {
        guard let model else { return }
        schedule(Self.snapshot(model))
        lastRegistration = nil
        Task { await register() }
    }

    // MARK: 本地更新

    private func observe() {
        guard let model else { return }
        let (state, pusherId) = withObservationTracking { (Self.snapshot(model), Self.pusher(model)?.id) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        schedule(state)
        if pusherId != lastPusherId {
            lastPusherId = pusherId
            Task { await register() }
        }
    }

    /// 会话状态常常一秒内连着变几次，攒一下再更新。
    private func schedule(_ state: State) {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.apply(state)
        }
    }

    private func refreshIfDue() {
        guard let model, Self.isForeground, let last = lastApplied, last.state.isActive,
              Date().timeIntervalSince(last.at) >= refreshInterval else { return }
        Task { await apply(Self.snapshot(model), force: true) }
    }

    private func apply(_ state: State, force: Bool = false) async {
        // 只拿 id，每次操作前重新取活动对象（Swift 6 不允许同一个活动对象跨多次 await 传递）。
        let all = Activity<PaseoActivityAttributes>.activities
        // 已结束的（锁屏上还留着「全部完成」）不算当前活动；否则它排在前面时，新启动的活动会被当成多余的关掉。
        let liveIds = all.filter { $0.activityState == .active || $0.activityState == .stale }.map(\.id)
        let endedIds = all.filter { $0.activityState == .ended }.map(\.id)
        // 只留一个进行中的活动；多出来的（本地和插件各启动了一个）直接结束。
        for id in liveIds.dropFirst() { await Self.end(id) }
        let currentId = liveIds.first
        // 有新活动了，就把旧的「全部完成」卡片撤掉。
        if currentId != nil { for id in endedIds { await Self.end(id) } }
        // 留下的那个要是令牌没登记过（本地和插件各启动了一个，结束的正好是登记过的），改登记它的。
        if let currentId, activityTokenOwner != currentId, let token = Self.activity(currentId)?.pushToken {
            activityToken = Self.hex(token)
            activityTokenOwner = currentId
            Task { await register() }
        }

        guard Self.enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for id in all.map(\.id) { await Self.end(id) }
            lastApplied = nil
            return
        }
        // 只在前台本地更新：后台时 App 的数据会停在挂起那一刻，交给插件推送。
        // 机器都还没连上时数据是空的，不能据此结束活动。
        // 被推送从后台唤醒时也不动：手机这边可能只连上了部分机器，会把插件推来的完整状态覆盖掉甚至结束活动。
        guard let model, Self.isForeground, model.hosts.contains(where: { $0.state == .connected }) else { return }

        let now = Date()
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(staleAfter))
        if state.isActive {
            if let currentId {
                if !force, let last = lastApplied, last.state.sameContent(as: state),
                   Self.activity(currentId)?.activityState == .active { return }
                await Self.update(currentId, content)
            } else {
                for id in endedIds { await Self.end(id) }
                // 要推送令牌，插件才能在后台更新；没开推送能力时退回纯本地活动。
                let started = (try? Activity.request(attributes: PaseoActivityAttributes(), content: content, pushType: .token))
                    ?? (try? Activity.request(attributes: PaseoActivityAttributes(), content: content, pushType: nil))
                if let started { watch(started) }
            }
            lastApplied = (state, now)
        } else if let currentId {
            await Self.end(currentId, final: state, dismissAt: now.addingTimeInterval(dismissAfter))
            lastApplied = nil
        }
    }

    private static func activity(_ id: String) -> Activity<PaseoActivityAttributes>? {
        Activity<PaseoActivityAttributes>.activities.first { $0.id == id }
    }

    // 下面几个在 nonisolated 里取活动对象并直接操作，活动对象不跨隔离域传递。
    /// final 为 nil：立即撤掉；否则以 final 结束并留到 dismissAt。
    nonisolated private static func end(_ id: String, final: State? = nil, dismissAt: Date? = nil) async {
        guard let activity = Activity<PaseoActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if let final, let dismissAt {
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(dismissAt))
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func update(_ id: String, _ content: ActivityContent<State>) async {
        await Activity<PaseoActivityAttributes>.activities.first(where: { $0.id == id })?.update(content)
    }

    // MARK: 推送令牌

    private func observeTokens() {
        Task { [weak self] in
            for await data in Activity<PaseoActivityAttributes>.pushToStartTokenUpdates {
                self?.pushToStartToken = Self.hex(data)
                print("live-activity push-to-start token", Self.hex(data).prefix(8))
                await self?.register()
            }
        }
        // 插件远程启动的活动也从这里来（系统会在后台唤醒 App 一会儿）。
        Task { [weak self] in
            for await activity in Activity<PaseoActivityAttributes>.activityUpdates { self?.watch(activity) }
        }
        Activity<PaseoActivityAttributes>.activities.forEach(watch)
    }

    private func watch(_ activity: Activity<PaseoActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                self?.activityToken = Self.hex(data)
                print("live-activity activity token", Self.hex(data).prefix(8))
                self?.activityTokenOwner = activity.id
                await self?.register()
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, self.activityTokenOwner == activity.id else { continue }
                // 还有别的活动在（例如插件刚远程启动的）就改登记它的令牌，否则告诉插件没有活动了。
                if let other = Activity<PaseoActivityAttributes>.activities.first(where: { $0.id != activity.id && $0.activityState == .active }),
                   let token = other.pushToken {
                    self.activityToken = Self.hex(token)
                    self.activityTokenOwner = other.id
                } else {
                    self.activityToken = nil
                    self.activityTokenOwner = nil
                }
                await self.register()
            }
        }
    }

    /// 选推送机器：用户指定的那台（装了插件且在线），否则列表里第一台装了插件的。
    static func pusher(_ model: AppModel) -> HostStore? {
        let candidates = model.hosts.filter { $0.state == .connected && $0.isPluginRunning(pluginId) }
        if let chosen = UserDefaults.standard.string(forKey: pusherKey), let h = candidates.first(where: { $0.id == chosen }) { return h }
        return candidates.first
    }

    /// 把令牌和要合并的机器交给推送机器；其他装了插件的机器注销本设备。
    func register() async {
        guard let model else { return }
        if registering { registerAgain = true; return }
        registering = true
        defer { registering = false }
        repeat {
            registerAgain = false
            await registerOnce(model)
        } while registerAgain
    }

    private func registerOnce(_ model: AppModel) async {
        // 被推送令牌从后台唤醒时窗口还没出来，先连机器，等推送机器上线（最多 20 秒）。
        model.start()
        var pusher = Self.pusher(model)
        if pusher == nil, !Self.isForeground, pushToStartToken != nil || activityToken != nil {
            for _ in 0..<20 where pusher == nil {
                try? await Task.sleep(for: .seconds(1))
                pusher = Self.pusher(model)
            }
        }
        let withPlugin = model.hosts.filter { $0.state == .connected && $0.isPluginRunning(Self.pluginId) }
        let epoch = Self.enabled ? "on:" + (pusher?.id ?? "") : "off"
        if epoch != unregisterEpoch { unregisterEpoch = epoch; unregistered = [] }

        // 系统设置里没允许 Paseo 通知时不交普通推送令牌：远程通知会被系统丢掉，
        // 插件还会因此去掉灵动岛的提醒声，等批准就彻底没声了。
        let authorized: Bool = await {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: true
            default: false
            }
        }()
        let sentAlert = Self.notificationsEnabled && authorized ? alertToken : nil
        if Self.enabled, let pusher {
            let hosts: [JSONValue] = model.hosts.map { ["serverId": .string($0.id), "label": .string($0.label)] }
            let input: JSONValue = [
                "deviceId": .string(Self.deviceId),
                "bundleId": .string(Bundle.main.bundleIdentifier ?? ""),
                "environment": .string(Self.apsEnvironment),
                "pushToStartToken": pushToStartToken.map { .string($0) } ?? .null,
                "activityToken": activityToken.map { .string($0) } ?? .null,
                "alertToken": sentAlert.map { .string($0) } ?? .null,
                "hosts": .array(hosts),
            ]
            let signature = [pusher.id, Self.apsEnvironment, pushToStartToken ?? "-", activityToken ?? "-", sentAlert ?? "-",
                             model.hosts.map { $0.id + "=" + $0.label }.joined(separator: ",")].joined(separator: "|")
            if signature != lastRegistration {
                do {
                    let out = try await pusher.invokePlugin(Self.pluginId, "activity.register", input, timeout: .seconds(30))
                    lastRegistration = signature
                    // alerts：插件确实会给这台设备发普通通知（旧版插件没有这个字段 → false，照旧本地弹）。
                    remoteAlertsReady = sentAlert != nil && out["alerts"]?.boolValue == true
                    print("live-activity registered with", pusher.label)
                } catch {
                    print("live-activity register failed:", error)
                }
            }
        } else {
            lastRegistration = nil
            remoteAlertsReady = false
        }
        // 推送机器以外装了插件的机器都注销本设备（关掉开关时全部注销），免得几台一起推；失败的下次连上再发。
        let unregister: JSONValue = ["deviceId": .string(Self.deviceId)]
        for h in withPlugin where h.id != (Self.enabled ? pusher?.id : nil) && !unregistered.contains(h.id) {
            if (try? await h.invokePlugin(Self.pluginId, "activity.unregister", unregister, timeout: .seconds(15))) != nil {
                unregistered.insert(h.id)
            }
        }
    }

    /// 用户看得到 App（不是被推送从后台唤醒）。拉下控制中心、弹系统对话框时是 inactive，也算。
    static var isForeground: Bool { UIApplication.shared.applicationState != .background }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: 汇总

    /// 把各机器的会话汇成一份状态，**按工作区合并**，规则同侧栏（AppModel.groupBucket）：一个工作区一行，
    /// 状态取其中顶层会话最紧急的，主会话空闲而子会话（嵌套 Paseo 会话、Claude Task 之类内置子代理）在跑或等批准时
    /// 也算在跑或等批准。计数按工作区。点开的是决定这个状态的那个会话（可以是子会话）。插件按同样规则汇总。
    static func snapshot(_ model: AppModel) -> State {
        struct Group { var row: Row; var rank: Int; var recent: Date }
        var groups: [Group] = []
        var offline: [String] = []
        let rankOf: [StatusBucket: Int] = [.needsInput: 0, .failed: 1, .running: 2]
        let statusOf: [StatusBucket: String] = [.needsInput: "waiting", .failed: "failed", .running: "running"]
        for h in model.hosts {
            if h.state != .connected { offline.append(h.label) }
            let roots = h.agents.values.filter { $0.archivedAt == nil && !h.isNested($0) }
            let live = h.agents.values.filter { $0.archivedAt == nil && $0.parentAgentId != nil }
            let children = Dictionary(grouping: live) { $0.parentAgentId! }
            for (_, list) in Dictionary(grouping: roots, by: { $0.workspaceId ?? "agent:" + $0.id }) {
                let bucket = model.groupBucket(list, in: h)
                guard let rank = rankOf[bucket], let status = statusOf[bucket] else { continue }
                // 顶层会话加上它们的嵌套子会话（递归）。
                var members = list
                var stack = list.map(\.id)
                var seen = Set(stack)
                while let id = stack.popLast() {
                    for c in children[id] ?? [] where seen.insert(c.id).inserted { members.append(c); stack.append(c.id) }
                }
                let recentOf = { (a: Agent) in a.updatedAt ?? .distantPast }
                let root = list.max { recentOf($0) < recentOf($1) }!
                // 决定这个状态的会话；只因内置子代理在跑而算运行中时没有对应会话，就点开最近的顶层会话。
                let pick = members.filter { $0.bucket == bucket }.max { recentOf($0) < recentOf($1) } ?? root
                let workspace = root.workspaceId.flatMap { h.workspaces[$0] }
                // 行名同侧栏：工作区标题，没有就用顶层会话的标题。
                let title = workspace?.title.flatMap { $0.isEmpty ? nil : $0 } ?? root.displayTitle
                let since = bucket == .running
                    ? members.filter { $0.bucket == .running }.compactMap { $0.activeTurnStartedAt?.timeIntervalSince1970 }.min()
                    : nil
                let row = Row(serverId: h.id, agentId: pick.id, host: h.label, title: title,
                              project: model.projectName(of: root, in: h), status: status, since: since)
                groups.append(Group(row: row, rank: rank, recent: members.map(recentOf).max() ?? .distantPast))
            }
        }
        let waiting = groups.filter { $0.rank == 0 }.count
        let failed = groups.filter { $0.rank == 1 }.count
        let running = groups.filter { $0.rank == 2 }.count
        // 只有出错、没有在跑或等你的：不显示出错行（活动反正要结束了）。
        let sorted = groups.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.recent > $1.recent }.prefix(4).map(\.row)
        return State(updatedAt: Date().timeIntervalSince1970, running: running, waiting: waiting, failed: failed,
                     rows: running + waiting > 0 ? Array(sorted) : [], offline: offline)
    }
}
#endif
