import Foundation

// 官方「后台任务」列表（0.16.0 起）：agent 在后台跑的 shell 命令、监控等，daemon 直接给出列表并可单独停止。
// 协议见 vendor/paseo/packages/protocol/src/messages.ts 的 AgentBackgroundWork*；
// 官方界面 vendor/paseo/packages/app/src/background-work/。
//   能力位 features.agentBackgroundWork（列表 + 推送）、features.agentBackgroundWorkStop（停止）。
//   agent.background_work.list.request {agentId} → {items, error}
//   agent.background_work.stop.request {agentId, itemId, stopToken} → {error}
//   推送 agent.background_work.update {agentId, items}：每次替换该 agent 的整个列表。

/// 一条后台任务。
public struct BackgroundWorkItem: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case shell, monitor
        /// 协议是开放字符串，未知值一律当「其他」。
        case other
    }

    public let id: String
    public let kind: Kind
    public let description: String?
    public let command: String?
    public let startedAt: Date?
    public let canStop: Bool
    public let stopToken: String?

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        switch v["kind"]?.stringValue {
        case "shell": kind = .shell
        case "monitor": kind = .monitor
        default: kind = .other
        }
        description = v["description"]?.stringValue
        command = v["command"]?.stringValue
        startedAt = v["startedAt"]?.dateValue
        canStop = v["canStop"]?.boolValue ?? false
        stopToken = v["stopToken"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 列表里的标题：说明优先，其次命令；都没有时由界面用种类名代替（官方 backgroundWorkText）。
    public var title: String? { description ?? command }
    /// 标题下面的命令行：和标题相同就不重复显示。
    public var commandDetail: String? {
        guard let command, command != title else { return nil }
        return command
    }

    /// 解析列表响应或推送里的 items。
    public static func list(_ items: JSONValue?) -> [BackgroundWorkItem] {
        (items?.arrayValue ?? []).compactMap(BackgroundWorkItem.init)
    }
}

/// 一个会话的后台任务状态（打开会话时拉一次，之后靠推送替换）。
public struct BackgroundWorkState: Sendable, Equatable {
    public enum Stop: Sendable, Equatable {
        case pending
        case failed(String)
    }

    /// nil = 还没拿到列表。
    public var items: [BackgroundWorkItem]?
    /// 最近一次拉取列表失败的原因；拿到列表或推送后清空。
    public var error: String?
    /// 停止请求的状态，按 stopToken。
    public var stops: [String: Stop] = [:]
    /// 每次推送加一：比推送晚回来的列表响应已经过时，丢掉。
    var revision = 0
    /// 正在看这个会话后台任务的界面数。
    var watchers = 0

    public init(items: [BackgroundWorkItem]? = nil, error: String? = nil) {
        self.items = items
        self.error = error
    }
}

extension HostStore {
    /// daemon 提供后台任务列表（没有这个能力位时整个功能不显示）。
    public var supportsBackgroundWork: Bool { serverInfo?.hasFeature("agentBackgroundWork") == true }
    /// daemon 支持单独停止后台任务。
    public var supportsBackgroundWorkStop: Bool { serverInfo?.hasFeature("agentBackgroundWorkStop") == true }

    /// 加进 session.events 订阅的事件：旧 daemon 的事件名是枚举校验，不认识的名字会让整个订阅请求失败，所以按能力位加。
    var backgroundWorkEvents: [JSONValue] { supportsBackgroundWork ? ["agent.background_work.update"] : [] }

    /// 这一条能不能显示停止按钮：条目可停、带 stopToken、daemon 支持停止，且列表已就绪（不是旧列表）。
    public func canStopBackgroundWork(_ item: BackgroundWorkItem) -> Bool {
        supportsBackgroundWorkStop && item.canStop && item.stopToken != nil
    }

    /// 会话界面出现时调用（`.task(id: host.state == .connected)`）：拉一次列表，之后靠推送更新，界面消失时清掉。
    public func watchBackgroundWork(_ agentId: String) async {
        guard state == .connected, supportsBackgroundWork else { return }
        backgroundWork[agentId, default: BackgroundWorkState()].watchers += 1
        defer {
            if var s = backgroundWork[agentId] {
                s.watchers -= 1
                backgroundWork[agentId] = s.watchers > 0 ? s : nil
            }
        }
        await loadBackgroundWork(agentId)
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// 拉取列表（打开会话、重连后、出错重试）。
    public func loadBackgroundWork(_ agentId: String) async {
        guard supportsBackgroundWork, let revision = backgroundWork[agentId]?.revision else { return }
        do {
            let r = try await conn().request("agent.background_work.list.request", ["agentId": .string(agentId)])
            guard backgroundWork[agentId]?.revision == revision else { return }
            let p = r["payload"]
            if let e = p?["error"]?.stringValue {
                backgroundWork[agentId]?.error = e.isEmpty ? String(localized: "无法加载后台任务", bundle: .module) : e
                return
            }
            setBackgroundWork(agentId, BackgroundWorkItem.list(p?["items"]))
        } catch {
            guard backgroundWork[agentId]?.revision == revision else { return }
            backgroundWork[agentId]?.error = "\(error)"
        }
    }

    /// 停止一条后台任务。成功后条目由随后的推送移除；失败时把原因记在这一条上。
    public func stopBackgroundWork(_ agentId: String, _ item: BackgroundWorkItem) async {
        guard canStopBackgroundWork(item), let token = item.stopToken,
              backgroundWork[agentId]?.stops[token] != .pending else { return }
        backgroundWork[agentId]?.stops[token] = .pending
        do {
            let r = try await conn().request("agent.background_work.stop.request", [
                "agentId": .string(agentId), "itemId": .string(item.id), "stopToken": .string(token),
            ], timeout: .seconds(30))
            if let e = r["payload"]?["error"]?.stringValue {
                backgroundWork[agentId]?.stops[token] = .failed(e)
            } else {
                backgroundWork[agentId]?.stops[token] = nil
            }
        } catch {
            backgroundWork[agentId]?.stops[token] = .failed("\(error)")
        }
    }

    /// 关掉某条停止失败的提示。
    public func dismissBackgroundWorkStop(_ agentId: String, token: String) {
        backgroundWork[agentId]?.stops[token] = nil
    }

    /// `agent.background_work.update` 推送：只记正在看的会话（没人看的会话重连后不会刷新，记了反而会过时）。
    func applyBackgroundWorkUpdate(_ p: JSONValue) {
        guard let agentId = p["agentId"]?.stringValue, backgroundWork[agentId] != nil else { return }
        backgroundWork[agentId]?.revision += 1
        setBackgroundWork(agentId, BackgroundWorkItem.list(p["items"]))
    }

    private func setBackgroundWork(_ agentId: String, _ items: [BackgroundWorkItem]) {
        guard var s = backgroundWork[agentId] else { return }
        s.items = items
        s.error = nil
        // 已经不在列表里的条目：停止失败的提示也没意义了。
        let tokens = Set(items.compactMap(\.stopToken))
        s.stops = s.stops.filter { tokens.contains($0.key) }
        backgroundWork[agentId] = s
    }
}
