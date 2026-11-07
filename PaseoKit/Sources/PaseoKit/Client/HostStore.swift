// Live state for one daemon (host): connection with reconnect, owned subscriptions, agents, workspaces,
// open timelines, and the actions the UI performs. SwiftUI observes it directly.
// See docs/protocol/02-messages.md §0–§8 and docs/protocol/01-connection.md §5.

import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected
    /// Retrying after `delay`; `message` is the last error.
    case waiting(message: String, retryAt: Date)
    /// Won't retry on its own (wrong password, incompatible daemon).
    case failed(message: String, needsPassword: Bool)
}

public struct ImageAttachment: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    var json: JSONValue { ["data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)] }
}

public struct AttentionEvent: Sendable {
    public let serverId: String
    public let agentId: String
    public let reason: String
    public let title: String
    public let body: String
    public let shouldNotify: Bool
}

@MainActor @Observable
public final class HostStore: Identifiable {
    public nonisolated let id: String
    public private(set) var offer: PairingOffer
    public var label: String
    public private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { AppLog.shared.record("连接", label + "：" + String(describing: state)) } }
    }
    public internal(set) var serverInfo: ServerInfo?
    public internal(set) var agents: [String: Agent] = [:]
    public private(set) var workspaces: [String: Workspace] = [:]
    public private(set) var projects: [String: Project] = [:]
    public internal(set) var timelines: [String: AgentTimeline] = [:]
    public private(set) var timelineLoading: Set<String> = []
    /// Last history-load failure per agent, cleared on the next successful load.
    public private(set) var timelineErrors: [String: String] = [:]
    public private(set) var providers: [JSONValue] = []
    /// The cwd `providers` was loaded for, so a background recheck reloads the same snapshot.
    @ObservationIgnored var providersCwd: String?
    @ObservationIgnored var lastProviderRecheck: ContinuousClock.Instant?
    /// Host pane state, keyed by cwd or workspace id.
    public internal(set) var checkoutStatus: [String: CheckoutStatus] = [:]
    public internal(set) var diffs: [String: CheckoutDiff] = [:]
    public internal(set) var terminals: [String: [TerminalInfo]] = [:]
    /// Worktree setup state per workspace (only worktrees run setup commands).
    public internal(set) var setupStatus: [String: WorktreeSetup] = [:]
    /// PR/forge state per checkout directory.
    public internal(set) var prStatus: [String: PrStatus] = [:]
    public internal(set) var scripts: [String: [WorkspaceScript]] = [:]
    /// Workspace label catalog (name → color) and daemon config.
    public internal(set) var labels: [WorkspaceLabel] = []
    public internal(set) var daemonConfig: JSONValue?
    /// Provider-internal subagents by parent agent id.
    public internal(set) var providerSubagents: [String: [ProviderSubagent]] = [:]
    public internal(set) var backgroundWork: [String: [AgentBackgroundWork]] = [:]
    public internal(set) var backgroundWorkErrors: [String: String] = [:]
    public internal(set) var backgroundWorkLoading: Set<String> = []
    @ObservationIgnored var backgroundWorkRequests: [String: UUID] = [:]
    /// Finished provider subagents the user cleared from the composer pill (this client only, like the official app).
    public internal(set) var hiddenProviderSubagents: Set<String> = []
    /// Timelines of provider subagents open in a tab, keyed "parentAgentId/subagentId".
    public internal(set) var providerSubagentTimelines: [String: AgentTimeline] = [:]
    public internal(set) var providerSubagentTimelineErrors: [String: String] = [:]
    /// Project icons by projectId: image bytes (nil = the project has none) and the revision they belong to.
    public internal(set) var projectIcons: [String: (revision: String?, data: Data?)] = [:]
    /// Installed plugins and a per-settings change counter (bumped by status.plugin_settings_changed).
    public internal(set) var plugins: [PluginInfo] = []
    public internal(set) var pluginSettingsRevision: [String: Int] = [:]
    /// True once the plugin list has been read from this daemon (so an empty list really means none installed).
    public internal(set) var pluginsLoaded = false

    @ObservationIgnored var fileTransfers: [String: FileTransfer] = [:]
    @ObservationIgnored var terminalSlots: [Int: String] = [:]
    @ObservationIgnored var terminalStreamSubs: [String: String] = [:]
    @ObservationIgnored var terminalSinks: [String: (TerminalEvent) -> Void] = [:]
    @ObservationIgnored var terminalListSubs: [String: String] = [:]
    @ObservationIgnored var diffSubs: [String: (id: String, mode: String)] = [:]
    @ObservationIgnored var binaryTask: Task<Void, Never>?
    @ObservationIgnored let messageImageCache = MessageImageCache()
    @ObservationIgnored var messageImageDirectoryTask: Task<Void, Error>?
    /// Views that show a session's provider subagents (composer pill, subagent tab): parent agent id → view count.
    @ObservationIgnored var providerSubagentWatchers: [String: Int] = [:]
    /// Watched parents whose live timeline launched a subagent (`sub_agent` tool call) during the current turn.
    @ObservationIgnored var providerSubagentLaunches: Set<String> = []
    /// The separate `session.events` subscription that carries only `agent.provider_subagents.update`; nil when off.
    @ObservationIgnored var providerSubagentSubscriptionId: String?
    @ObservationIgnored var providerSubagentReconcile: Task<Void, Never>?
    @ObservationIgnored var providerSubagentReconcileAgain = false
    @ObservationIgnored var heartbeatTicks = 0
    /// Server pushes handled since start, by message type (paseo-probe PASEO_PUSH measures traffic with it).
    @ObservationIgnored public private(set) var pushCounts: [String: Int] = [:]

    /// Called for `agent_attention_required`; the app decides whether to show a local notification.
    @ObservationIgnored public var onAttention: (@MainActor (AttentionEvent) -> Void)?

    @ObservationIgnored private let clientId: String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored var connection: DaemonConnection?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var companionConnectionTask: Task<Void, Error>?
    /// Round trip of a session `ping` RPC to this daemon (relay included), measured every heartbeat (15 s).
    /// nil while not connected or before the first answer.
    public private(set) var latencyMs: Int?
    @ObservationIgnored private var timelineWatchers: [String: Int] = [:]
    private var openAgents: [String] { timelineWatchers.keys.sorted() }
    @ObservationIgnored private var timelineSyncTask: Task<Void, Never>?
    @ObservationIgnored private var timelineInterestRevision = 0
    @ObservationIgnored private var recentTimelines: [String] = []
    @ObservationIgnored private var timelineSubscriptionId: String?
    @ObservationIgnored var subscriptionIds: Set<String> = []
    @ObservationIgnored private var streamBuffer: [String: [JSONValue]] = [:]
    @ObservationIgnored private var catchingUp: [String: DaemonConnection] = [:]
    @ObservationIgnored private var focusedAgentId: String?
    @ObservationIgnored var focusedTerminalId: String?
    @ObservationIgnored private var appVisible = true
    @ObservationIgnored private var visibilityChangedAt = Date()
    @ObservationIgnored private var lastActivityAt = Date()

    public init(offer: PairingOffer, label: String, clientId: String, appVersion: String) {
        id = offer.serverId
        self.offer = offer
        self.label = label
        self.clientId = clientId
        self.appVersion = appVersion
    }

    // MARK: Lifecycle

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await runLoop() }
    }

    public func stop() {
        timelineSyncTask?.cancel()
        timelineSyncTask = nil
        runTask?.cancel()
        runTask = nil
        heartbeatTask?.cancel()
        latencyMs = nil
        let c = connection
        connection = nil
        subscriptionIds.removeAll()
        timelineSubscriptionId = nil
        providerSubagentSubscriptionId = nil
        Task { await c?.close() }
        resetBackgroundWork()
        state = .idle
    }

    public func updatePassword(_ password: String?) {
        offer.password = password
        stop()
        start()
    }

    /// Reconnect immediately (e.g. app returned to foreground).
    public func reconnectNow() {
        if case .connected = state { return }
        stop()
        start()
    }

    /// A suspended iPhone can retain `.connected` after its socket has died. Probe the socket
    /// before serving the watch, and share recovery between simultaneous companion reads.
    public func prepareForCompanionRequest() async throws {
        if let task = companionConnectionTask { return try await task.value }
        let task = Task { try await recoverCompanionConnection() }
        companionConnectionTask = task
        defer { companionConnectionTask = nil }
        try await task.value
    }

    private func recoverCompanionConnection() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        if state == .connected, let c = connection {
            do {
                _ = try await c.request("ping", ["clientSentAt": .number((Date().timeIntervalSince1970 * 1000).rounded())], timeout: .seconds(2))
                if connection === c, !(await c.isClosed) { return }
            } catch {
                if error is CancellationError { throw error }
            }
            // Closing this exact socket lets its existing run loop rebuild subscriptions.
            // Do not tear down a replacement that another task has already established.
            if connection === c { await c.close() }
        }
        start()
        switch state {
        case .idle, .waiting: reconnectNow()
        default: break
        }
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if state == .connected, let c = connection, !(await c.isClosed) { return }
            if case .failed(let message, _) = state { throw ActionError.rejected(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DaemonConnectionError.timeout("companion connection")
    }

    /// Retrying a read is safe after a transport loss; RPC/auth failures are not transport losses.
    public nonisolated static func isConnectionLoss(_ error: any Error) -> Bool {
        if case DaemonConnectionError.closed = error { return true }
        if case ActionError.notConnected = error { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain || value.domain == NSPOSIXErrorDomain
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            state = .connecting(attempt: attempt)
            do {
                let c = try await DaemonConnection.connect(offer: offer, hello: HelloOptions(
                    clientId: clientId, password: offer.password, appVersion: appVersion, capabilities: Self.capabilities))
                guard !Task.isCancelled else { await c.close(); return }
                connection = c
                serverInfo = await c.serverInfo
                attempt = 0
                try await bootstrap(c)
                guard !Task.isCancelled, connection === c else { await c.close(); return }
                state = .connected
                scheduleTimelineSync()
                for id in openAgents { Task { await refreshBackgroundWork(id) } }
                startHeartbeat()
                for await message in c.events { handle(message) }
                guard !Task.isCancelled, connection === c else { return }
                // Stream ended: connection closed.
                heartbeatTask?.cancel()
                timelineSyncTask?.cancel()
                timelineSyncTask = nil
                latencyMs = nil
                connection = nil
                resetBackgroundWork()
                subscriptionIds.removeAll()
                timelineSubscriptionId = nil
                providerSubagentSubscriptionId = nil
                if Task.isCancelled { return }
            } catch let error as DaemonConnectionError where error.isAuthFailure {
                state = .failed(message: error.description, needsPassword: true)
                return
            } catch let error as SecureChannelError where error.closeCode == 4002 {
                state = .failed(message: String(localized: "daemon 太旧或握手被拒：\(error.description)", bundle: .module), needsPassword: false)
                return
            } catch {
                if Task.isCancelled { return }
                let delay = min(1.5 * pow(2, Double(attempt)), 30)
                attempt += 1
                state = .waiting(message: "\(error)", retryAt: Date().addingTimeInterval(delay))
                try? await Task.sleep(for: .seconds(delay))
                continue
            }
            // Clean close: retry quickly.
            state = .waiting(message: String(localized: "连接断开，正在重连", bundle: .module), retryAt: Date().addingTimeInterval(1.5))
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    public static let capabilities: [String: JSONValue] = [
        "hello_rejection": true,
        "owned_subscriptions": true,
        "explicit_event_subscriptions": true,
        "selective_agent_timeline": true,
        "timeline_replacement_invalidation": true,
        "timeline_notifications": true,
        "reasoning_merge_enum": true,
        "all_providers": true,
        "custom_mode_icons": true,
        "project_updates": true,
        "terminal_reflowable_snapshot": true,
        "provider_subagents": true,
        "projected_subagent_timeline": true,
        "plugin_timeline_items": true,
        "binary_chunking_v1": true,
    ]

    /// Subscriptions belong to the physical socket: rebuild them all on every connect.
    private func bootstrap(_ c: DaemonConnection) async throws {
        // Binary frames in arrival order (terminal output must not be reordered).
        let (stream, sink) = AsyncStream.makeStream(of: Data.self)
        await c.setBinaryHandler { sink.yield($0) }
        binaryTask?.cancel()
        binaryTask = Task { for await frame in stream { self.handleBinary(frame) } }
        resetHostPaneStreams()
        resetBackgroundWork()
        providerSubagentSubscriptionId = nil
        // `agent.provider_subagents.update` is not here: the daemon sends it for every step of every subagent on the
        // host (~0.9 KB/s with a few running). A separate subscription carries it only while a watched session
        // has live subagents; see HostStore+HostPane.swift "Provider subagent pushes".
        var eventTypes = ["agent_permission_request", "agent_permission_resolved", "agent_attention_required", "project.update",
                          "checkout_status_update", "script_status_update", "terminal_attention_required", "workspace_setup_progress",
                          "status.daemon_config_changed", "status.plugin_catalog_changed", "status.plugin_settings_changed",
                          "providers_snapshot_update"]
        if supportsBackgroundWork { eventTypes.append("agent.background_work.update") }
        let events = try await c.request("session.events.set_subscription.request", [
            "events": .array(eventTypes.map(JSONValue.string)), "notifications": true,
        ])
        track(events)
        // Model names for every session: the composer's model picker used to load these, but on an iPhone the picker
        // only exists inside the settings sheet, so labels fell back to raw ids ("claude-opus-5-5").
        Task {
            await loadProviders(cwd: nil)
            await recheckUnavailableProviders()
        }

        let ws = try await c.request("fetch_workspaces_request", [
            "includeBackground": false,
            "sort": [["key": "activity_at", "direction": "desc"]],
            "page": ["limit": 200],
            "subscribe": [:],
        ])
        track(ws)
        var nextWorkspaces: [String: Workspace] = [:]
        for e in ws["payload"]?["entries"]?.arrayValue ?? [] { if let w = Workspace(e) { nextWorkspaces[w.id] = w } }
        workspaces = nextWorkspaces

        let ag = try await c.request("fetch_agents_request", [
            "scope": "active",
            "sort": [["key": "updated_at", "direction": "desc"]],
            "page": ["limit": 200],
            "subscribe": [:],
        ])
        track(ag)
        var nextAgents: [String: Agent] = [:]
        for e in ag["payload"]?["entries"]?.arrayValue ?? [] { if let a = Agent(e["agent"] ?? e) { nextAgents[a.id] = a } }
        agents = nextAgents
        Task { await loadRecentIdleProviderSubagents() }

        if serverInfo?.hasFeature("workspaceLabels") == true,
           let lr = try? await c.request("workspace.label.list.request", ["subscribe": [:]]) {
            track(lr)
            labels = (lr["payload"]?["labels"]?.arrayValue ?? []).compactMap(WorkspaceLabel.init)
        }
        if let cr = try? await c.request("get_daemon_config_request") { daemonConfig = cr["payload"]?["config"] }
        await loadPlugins()

        if let pl = try? await c.request("project.list.request") {
            var next: [String: Project] = [:]
            for p in pl["payload"]?["projects"]?.arrayValue ?? [] { if let p = Project(p) { next[p.id] = p } }
            projects = next
        }

        // 时间线在进入 connected 后独立补齐，不阻塞全局状态和通知的事件消费。
    }

    func track(_ response: JSONValue) {
        if let id = response["payload"]?["subscriptionId"]?.stringValue { subscriptionIds.insert(id) }
    }

    // MARK: Push handling

    private func handle(_ m: JSONValue) {
        guard let type = m["type"]?.stringValue else { return }
        pushCounts[type, default: 0] += 1
        let p = m["payload"] ?? .null
        if type == "terminals_changed", let ws = p["workspaceId"]?.stringValue, terminalListSubs[ws] != nil,
           let sub = p["subscriptionId"]?.stringValue {
            // The reply to subscribe_terminals_request is the first terminals_changed: adopt its subscription.
            terminalListSubs[ws] = sub
            subscriptionIds.insert(sub)
        }
        if let sub = p["subscriptionId"]?.stringValue, !subscriptionIds.contains(sub), sub != timelineSubscriptionId,
           !terminalStreamSubs.values.contains(sub) { return }
        switch type {
        case "agent.background_work.update":
            receiveBackgroundWork(p)
        case "agent_update":
            if p["kind"]?.stringValue == "remove" {
                if let id = p["agentId"]?.stringValue { agents[id] = nil }
            } else if let a = p["agent"].flatMap(Agent.init) {
                let wasRunning = agents[a.id]?.status == .running
                agents[a.id] = a
                if wasRunning, a.status != .running { providerSubagentTurnEnded(a.id) }
            }
        case "workspace_update":
            if p["kind"]?.stringValue == "remove" {
                if let id = p["id"]?.stringValue { workspaces[id] = nil }
            } else if let w = p["workspace"].flatMap(Workspace.init) {
                workspaces[w.id] = w
            }
        case "providers_snapshot_update":
            // Full entries (we do not advertise the compact snapshot capability).
            if let entries = p["entries"]?.arrayValue, !entries.isEmpty { providers = entries }
        case "project.update":
            if p["kind"]?.stringValue == "remove" {
                if let id = p["projectId"]?.stringValue { projects[id] = nil }
            } else if let pr = p["project"].flatMap(Project.init) {
                projects[pr.id] = pr
            }
        case "agent_stream":
            guard let agentId = p["agentId"]?.stringValue else { return }
            applyStream(agentId, p)
        case "agent.timeline.replacement":
            if let agentId = p["agentId"]?.stringValue { reloadTimeline(agentId) }
        case "agent_permission_request", "agent_permission_resolved":
            // The agent snapshot's pendingPermissions is authoritative; refresh it.
            if let agentId = p["agentId"]?.stringValue { refreshAgent(agentId) }
        case "agent_attention_required":
            let n = p["notification"]
            onAttention?(AttentionEvent(
                serverId: id, agentId: p["agentId"]?.stringValue ?? "", reason: p["reason"]?.stringValue ?? "",
                title: n?["title"]?.stringValue ?? "", body: n?["body"]?.stringValue ?? "",
                shouldNotify: p["shouldNotify"]?.boolValue ?? false))
        default:
            handleHostPane(type, p)
        }
    }

    // MARK: Timelines

    /// Call when a session screen appears.
    public func openTimeline(_ agentId: String) {
        focusedAgentId = agentId
        sendHeartbeat()
        timelineWatchers[agentId, default: 0] += 1
        Task { await refreshBackgroundWork(agentId) }
        recentTimelines.removeAll { $0 == agentId }
        recentTimelines.append(agentId)
        timelineInterestRevision += 1
        scheduleTimelineSync()
    }

    public func closeTimeline(_ agentId: String) {
        if focusedAgentId == agentId { focusedAgentId = nil; sendHeartbeat() }
        if let count = timelineWatchers[agentId], count > 1 { timelineWatchers[agentId] = count - 1 }
        else { timelineWatchers[agentId] = nil }
        timelineInterestRevision += 1
        scheduleTimelineSync()
        trimTimelineCache()
    }

    /// 串行提交订阅集合：快速 A→B→C 时，旧请求不能覆盖新选择。全局 agent/通知订阅不受影响。
    private func scheduleTimelineSync() {
        guard state == .connected, let c = connection, timelineSyncTask == nil else { return }
        timelineSyncTask = Task {
            defer { if connection === c { timelineSyncTask = nil } }
            while !Task.isCancelled, connection === c {
                let revision = timelineInterestRevision
                let ids = openAgents
                for id in ids { timelineErrors[id] = nil }
                do {
                    for id in ids { SessionSwitchTrace.mark(id, "subscribeStart") }
                    try await resubscribeTimelines(c, agentIds: ids)
                    for id in ids { SessionSwitchTrace.mark(id, "subscribeEnd") }
                    for id in ids where timelineWatchers[id] != nil {
                        guard connection === c, !Task.isCancelled else { return }
                        timelineLoading.insert(id)
                        await catchUp(id, c)
                    }
                } catch {
                    guard !(await c.isClosed), connection === c, !Task.isCancelled else { return }
                    for id in openAgents { timelineErrors[id] = String(localized: "加载历史失败：\(error)", bundle: .module) }
                }
                if revision == timelineInterestRevision { break }
            }
        }
    }

    private func trimTimelineCache() {
        let inactive = recentTimelines.filter { timelineWatchers[$0] == nil && catchingUp[$0] == nil }
        for id in inactive.dropLast(8) {
            timelines[id] = nil
            timelineErrors[id] = nil
            streamBuffer[id] = nil
            recentTimelines.removeAll { $0 == id }
        }
    }

    private func resubscribeTimelines(_ c: DaemonConnection, agentIds: [String]) async throws {
        let old = timelineSubscriptionId
        let r = try await c.request("agent.timeline.set_subscription.request", ["agentIds": .array(agentIds.map { .string($0) })])
        guard connection === c, !Task.isCancelled else { return }
        timelineSubscriptionId = r["payload"]?["subscriptionId"]?.stringValue
        for id in agentIds { SessionSwitchTrace.mark(id, "subscriptionAcknowledged") }
        if let old, old != timelineSubscriptionId {
            // The replacement subscription is already active. Releasing the old ID must not
            // add another network round trip before the selected session can fetch its tail.
            Task { _ = try? await c.request("subscription.release.request", ["subscriptionId": .string(old)]) }
        }
    }

    /// Fetch the tail (first open / epoch change) or forward from endCursor until caught up, then replay buffered stream events.
    func catchUp(_ agentId: String, _ c: DaemonConnection) async {
        guard connection === c, !Task.isCancelled, catchingUp[agentId] !== c else { return }
        catchingUp[agentId] = c
        defer {
            if catchingUp[agentId] === c {
                catchingUp[agentId] = nil
                timelineLoading.remove(agentId)
            }
            trimTimelineCache()
        }
        var timeline = timelines[agentId] ?? AgentTimeline()
        let startEnd = timeline.endSeq
        var pages = 0
        var params: [String: JSONValue] = ["agentId": .string(agentId), "projection": "projected"]
        if let cursor = timeline.endCursor {
            params["direction"] = "after"
            params["cursor"] = cursor
        } else {
            params["direction"] = "tail"
            params["limit"] = 40
            if serverInfo?.hasFeature("wholeTurnTimeline") == true { params["wholeTurns"] = true }
        }
        do {
            for _ in 0..<50 {
                SessionSwitchTrace.mark(agentId, "fetchStart")
                let r = try await c.request("fetch_agent_timeline_request", params)
                SessionSwitchTrace.mark(agentId, "fetchReturned")
                guard connection === c, !Task.isCancelled else { return }
                guard let p = r["payload"] else { break }
                if let e = p["error"], e != .null {
                    timelineErrors[agentId] = e["message"]?.stringValue ?? e.stringValue ?? String(localized: "加载历史失败", bundle: .module)
                    return
                }
                timeline.applyPage(p)
                pages += 1
                if let a = p["agent"].flatMap(Agent.init) { agents[a.id] = a }
                guard p["hasNewer"]?.boolValue == true, let cursor = timeline.endCursor else { break }
                params["direction"] = "after"
                params["cursor"] = cursor
                params["limit"] = nil
                params["wholeTurns"] = nil
            }
        } catch {
            guard !(await c.isClosed), connection === c, !Task.isCancelled else { return }
            timelineErrors[agentId] = String(localized: "加载历史失败：\(error)", bundle: .module)
            return
        }
        timelineErrors[agentId] = nil
        timelines[agentId] = timeline
        SessionSwitchTrace.mark(agentId, "historyPublished", detail: "rows=\(timeline.rows.count) pages=\(pages)")
        let buffered = streamBuffer.removeValue(forKey: agentId) ?? []
        // 回放已进入同步后的时间线；否则 applyStream 会把它们再次放回缓冲区。
        catchingUp[agentId] = nil
        timelineLoading.remove(agentId)
        // 诊断（实时推送时文字偶尔停在第一块）：只记补拉，不记正常推送。
        AppLog.shared.record("时间线", "\(agentId.prefix(8)) 补拉 endSeq \(startEnd.map(String.init) ?? "空")→\(timeline.endSeq.map(String.init) ?? "空")，\(pages) 页，回放缓冲 \(buffered.count) 条：\(buffered.compactMap { $0["seq"]?.doubleValue.map { String(Int($0)) } }.joined(separator: ","))")
        for p in buffered { applyStream(agentId, p) }
    }

    private func applyStream(_ agentId: String, _ payload: JSONValue) {
        guard openAgents.contains(agentId) else { return }
        if let item = payload["event"]?["item"], item["type"]?.stringValue == "tool_call",
           item["detail"]?["type"]?.stringValue == "sub_agent" {
            noteProviderSubagentLaunch(agentId)
        }
        if catchingUp[agentId] != nil || timelines[agentId] == nil {
            streamBuffer[agentId, default: []].append(payload)
            return
        }
        var t = timelines[agentId]!
        let before = t.endSeq
        let result = t.applyStream(payload)
        timelines[agentId] = t
        if result == .gap || result == .stale || result == .epochChanged {
            let item = payload["event"]?["item"]
            AppLog.shared.record("时间线", "\(agentId.prefix(8)) 推送 seq=\(payload["seq"]?.doubleValue.map { String(Int($0)) } ?? "无") endSeq=\(before.map(String.init) ?? "空") → \(result)（\(item?["type"]?.stringValue ?? payload["event"]?["type"]?.stringValue ?? "?")）")
        }
        switch result {
        case .gap:
            streamBuffer[agentId, default: []].append(payload)
            if let c = connection { Task { await catchUp(agentId, c) } }
        case .epochChanged:
            reloadTimeline(agentId)
        default:
            break
        }
    }

    /// Retry after a failed history load.
    public func retryTimeline(_ agentId: String) {
        timelineErrors[agentId] = nil
        guard let c = connection else { return }
        timelineLoading.insert(agentId)
        if timelineWatchers[agentId] != nil { scheduleTimelineSync() }
        else { Task { await catchUp(agentId, c) } }
    }

    private func reloadTimeline(_ agentId: String) {
        timelines[agentId] = nil
        streamBuffer[agentId] = nil
        guard openAgents.contains(agentId), let c = connection else { return }
        timelineLoading.insert(agentId)
        Task { await catchUp(agentId, c) }
    }

    public func loadOlder(_ agentId: String) async {
        guard let c = connection, let t = timelines[agentId], t.hasOlder, let cursor = t.startCursor else { return }
        guard let r = try? await c.request("fetch_agent_timeline_request", [
            "agentId": .string(agentId), "direction": "before", "cursor": cursor, "limit": 40, "projection": "projected",
        ]), let p = r["payload"] else { return }
        timelines[agentId]?.applyPage(p)
    }

    /// A subagent is nested under its parent only when the parent is on this host and still listed;
    /// sessions started from another machine, or whose parent is archived, show as top-level.
    public func isNested(_ agent: Agent) -> Bool {
        guard let parent = agent.parentAgentId else { return false }
        if let server = agent.parentServerId, server != id { return false }
        return agents[parent] != nil
    }

    // MARK: Actions

    public enum ActionError: Error, CustomStringConvertible {
        case notConnected
        case rejected(String)
        public var description: String {
            switch self {
            case .notConnected: String(localized: "未连接", bundle: .module)
            case .rejected(let m): m
            }
        }
    }

    func conn() throws -> DaemonConnection {
        guard let connection else { throw ActionError.notConnected }
        return connection
    }

    func check(_ r: JSONValue) throws {
        let p = r["payload"]
        if p?["accepted"]?.boolValue == false || (p?["error"] != nil && p?["error"] != .null) {
            throw ActionError.rejected(p?["error"]?.stringValue ?? p?["error"]?["message"]?.stringValue ?? String(localized: "请求被拒绝", bundle: .module))
        }
    }

    /// Optimistic previews. Durable cross-device references live in the host's message-image store.
    public private(set) var sentImages: [String: [ImageAttachment]] = [:]

    public func send(_ text: String, to agentId: String, steer: Bool, images: [ImageAttachment] = [], attachments: [JSONValue] = [], messageID: String? = nil, timeout: Duration = .seconds(60)) async throws {
        let c = try conn()
        let messageId = messageID ?? "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if !images.isEmpty { sentImages[messageId] = images }
        timelines[agentId, default: AgentTimeline()].appendPendingUserMessage(text: text, messageId: messageId)
        var params: [String: JSONValue] = [
            "agentId": .string(agentId), "text": .string(text), "messageId": .string(messageId),
            "activeTurnBehavior": steer ? "steer" : "interrupt",
        ]
        if !images.isEmpty {
            params["images"] = .array(images.map(\.json))
        }
        if !attachments.isEmpty { params["attachments"] = .array(attachments) }
        do {
            try await persistMessageImages(images, messageId: messageId)
            try Task.checkCancellation()
            try check(try await c.request("send_agent_message_request", params, timeout: timeout))
        } catch {
            timelines[agentId]?.dropPendingUserMessage(messageId)
            sentImages[messageId] = nil
            throw error
        }
    }

    public func cancel(_ agentId: String) async throws {
        try check(try await conn().request("cancel_agent_request", ["agentId": .string(agentId)]))
    }

    /// Bounded reads for companion clients; these do not change the phone's focused session,
    /// timeline subscriptions, sidebar filter, or pagination.
    public func fetchRecentAgents(limit: Int = 60, timeout: Duration = .seconds(10)) async throws -> [Agent] {
        let r = try await conn().request("fetch_agents_request", [
            "scope": "active", "sort": [["key": "updated_at", "direction": "desc"]],
            "page": ["limit": .number(Double(limit))],
        ], timeout: timeout)
        try check(r)
        return (r["payload"]?["entries"]?.arrayValue ?? []).compactMap { Agent($0["agent"] ?? $0) }
    }

    public func fetchAgentSnapshot(_ agentId: String, timeout: Duration = .seconds(8)) async throws -> Agent {
        let r = try await conn().request("fetch_agent_request", ["agentId": .string(agentId)], timeout: timeout)
        try check(r)
        guard let agent = r["payload"]?["agent"].flatMap(Agent.init) else { throw ActionError.rejected(String(localized: "会话已不存在", bundle: .module)) }
        if agent.archivedAt == nil { agents[agent.id] = agent }
        return agent
    }

    public func fetchRecentTimeline(_ agentId: String, limit: Int = 30, timeout: Duration = .seconds(8)) async throws -> AgentTimeline {
        let r = try await conn().request("fetch_agent_timeline_request", [
            "agentId": .string(agentId), "projection": "projected", "direction": "tail", "limit": .number(Double(limit)),
        ], timeout: timeout)
        try check(r)
        guard let payload = r["payload"] else { throw ActionError.rejected(String(localized: "未收到会话消息", bundle: .module)) }
        var timeline = AgentTimeline()
        timeline.applyPage(payload)
        return timeline
    }

    /// `response` is e.g. `["behavior": "allow"]` or `["behavior": "deny", "message": "Denied by user"]`.
    public func respond(to permission: PermissionRequest, agentId: String, response: [String: JSONValue]) async throws {
        let c = try conn()
        // The permission id doubles as the RPC correlation key; the reply is `agent_permission_resolved`.
        let text = try JSONValue.object(["type": "session", "message": [
            "type": "agent_permission_response", "agentId": .string(agentId),
            "requestId": .string(permission.id), "response": .object(response),
        ]]).serialized()
        try await c.sendRaw(text)
        try? await Task.sleep(for: .milliseconds(300))
        refreshAgent(agentId)
    }

    public func setMode(_ agentId: String, modeId: String) async throws {
        try check(try await conn().request("set_agent_mode_request", ["agentId": .string(agentId), "modeId": .string(modeId)]))
    }

    public func setThinking(_ agentId: String, optionId: String?) async throws {
        try check(try await conn().request("set_agent_thinking_request", ["agentId": .string(agentId), "thinkingOptionId": optionId.map(JSONValue.string) ?? .null]))
    }

    public func setFeature(_ agentId: String, featureId: String, value: JSONValue) async throws {
        try check(try await conn().request("set_agent_feature_request", ["agentId": .string(agentId), "featureId": .string(featureId), "value": value]))
    }

    public struct Command: Sendable, Identifiable, Hashable {
        public let name: String
        public let description: String
        public let argumentHint: String
        public let isSkill: Bool
        public var id: String { name }
    }

    /// Slash commands and skills for autocomplete (cached 60 s per agent like the official app).
    public func listCommands(_ agentId: String) async -> [Command] {
        (try? await fetchCommands(agentId)) ?? commandCache[agentId]?.list ?? []
    }

    /// 菜单需要区分请求失败和确实没有命令；重试时绕过缓存。
    public func fetchCommands(_ agentId: String, forceRefresh: Bool = false) async throws -> [Command] {
        if !forceRefresh, let c = commandCache[agentId], Date().timeIntervalSince(c.at) < 60 { return c.list }
        let r = try await conn().request("list_commands_request", ["agentId": .string(agentId)])
        if let error = r["payload"]?["error"]?.stringValue {
            throw DaemonConnectionError.rpc(requestType: "list_commands_request", code: nil, message: error)
        }
        let list = (r["payload"]?["commands"]?.arrayValue ?? []).compactMap { c -> Command? in
            guard let name = c["name"]?.stringValue else { return nil }
            return Command(name: name, description: c["description"]?.stringValue ?? "", argumentHint: c["argumentHint"]?.stringValue ?? "",
                           isSkill: c["kind"]?.stringValue == "skill")
        }
        commandCache[agentId] = (Date(), list)
        return list
    }
    @ObservationIgnored private var commandCache: [String: (at: Date, list: [Command])] = [:]

    public struct PathSuggestion: Sendable, Hashable, Identifiable {
        public let path: String
        public let isDirectory: Bool
        public var id: String { path }
    }

    /// File/directory search under `cwd` for @mentions (or under $HOME without cwd).
    public func pathSuggestions(cwd: String?, query: String, includeFiles: Bool = true) async -> [PathSuggestion] {
        var params: [String: JSONValue] = ["query": .string(query), "limit": 50, "includeFiles": .bool(includeFiles), "includeDirectories": true]
        if let cwd { params["cwd"] = .string(cwd) }
        guard let r = try? await connection?.request("directory_suggestions_request", params) else { return [] }
        if let entries = r["payload"]?["entries"]?.arrayValue {
            return entries.compactMap { e in e["path"]?.stringValue.map { PathSuggestion(path: $0, isDirectory: e["kind"]?.stringValue == "directory") } }
        }
        return (r["payload"]?["directories"]?.arrayValue ?? []).compactMap { $0.stringValue.map { PathSuggestion(path: $0, isDirectory: true) } }
    }

    /// Rewinds to a user message. Non-"files" modes rebuild the timeline (the daemon pushes a replacement).
    public func rewind(_ agentId: String, messageId: String, mode: String) async throws {
        let r = try await conn().request("agent.rewind.request", ["agentId": .string(agentId), "messageId": .string(messageId), "mode": .string(mode)])
        if r["payload"]?["ok"]?.boolValue == false { throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? String(localized: "回退失败", bundle: .module)) }
        if mode != "files" { reloadTimeline(agentId) }
    }

    /// Serializes the conversation (up to a message) into a text attachment for a new chat.
    public func forkContext(_ agentId: String, boundaryMessageId: String?) async throws -> JSONValue {
        var params: [String: JSONValue] = ["agentId": .string(agentId)]
        if let boundaryMessageId { params["boundaryMessageId"] = .string(boundaryMessageId) }
        let r = try await conn().request("agent.fork_context.request", params)
        guard let a = r["payload"]?["attachment"], a != .null else { throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? String(localized: "分叉失败", bundle: .module)) }
        return a
    }

    public func detach(_ agentId: String) async throws {
        try check(try await conn().request("agent.detach.request", ["agentId": .string(agentId)]))
    }

    /// Reload: interrupt, rehydrate from the provider's history, refetch the timeline.
    public func reload(_ agentId: String) async throws {
        _ = try await conn().request("refresh_agent_request", ["agentId": .string(agentId)], timeout: .seconds(120))
        reloadTimeline(agentId)
    }

    // MARK: Workspaces

    /// The host's home directory, inferred from workspace paths (`/Users/<name>` or `/home/<name>`).
    public var homeDirectory: String? {
        for path in workspaces.values.map(\.directory) + projects.values.map(\.rootPath) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "Users" || parts[0] == "home" { return "/" + parts[0] + "/" + parts[1] }
        }
        return nil
    }

    public struct BranchOption: Sendable, Hashable, Identifiable {
        public let refName: String
        public let label: String
        public let detail: String
        public var id: String { refName }
    }

    public struct ChangeRequest: Sendable, Hashable, Identifiable {
        public let number: Int
        public let title: String
        public let headRefName: String
        public let forge: String?
        public let projectPath: String?
        public var id: Int { number }
    }

    /// Remote branches first (they are the default base), then local ones. Official: new-workspace-picker-item.ts.
    public func branchSuggestions(cwd: String, query: String) async -> [BranchOption] {
        (try? await fetchBranchSuggestions(cwd: cwd, query: query)) ?? []
    }

    public func fetchBranchSuggestions(cwd: String, query: String) async throws -> [BranchOption] {
        let r = try await conn().request("branch_suggestions_request", ["cwd": .string(cwd), "query": .string(query), "limit": 20])
        let p = r["payload"]
        if let error = p?["error"]?.stringValue { throw ActionError.rejected(error) }
        if let details = p?["branchDetails"]?.arrayValue, !details.isEmpty {
            var remote: [BranchOption] = [], local: [BranchOption] = []
            for d in details {
                guard let name = d["name"]?.stringValue else { continue }
                if d["hasRemote"]?.boolValue == true { remote.append(BranchOption(refName: "refs/remotes/origin/" + name, label: name, detail: "origin")) }
                if d["hasLocal"]?.boolValue == true {
                    let ahead = Int(d["localAhead"]?.doubleValue ?? 0), behind = Int(d["localBehind"]?.doubleValue ?? 0)
                    let diverged = d["hasRemote"]?.boolValue == true && (ahead > 0 || behind > 0)
                    if d["hasRemote"]?.boolValue != true || diverged {
                        local.append(BranchOption(refName: "refs/heads/" + name, label: name, detail: diverged ? String(localized: "本地 ↑\(ahead) ↓\(behind)", bundle: .module) : String(localized: "本地", bundle: .module)))
                    }
                }
                if d["hasRemote"] == nil && d["hasLocal"] == nil { local.append(BranchOption(refName: name, label: name, detail: "")) }
            }
            return remote + local
        }
        return (p?["branches"]?.arrayValue ?? []).compactMap { $0.stringValue.map { BranchOption(refName: $0, label: $0, detail: "") } }
    }

    /// Open PRs for the "start from" picker; empty unless the forge CLI is authenticated.
    public func searchChangeRequests(cwd: String, query: String) async -> [ChangeRequest] {
        guard serverInfo?.hasFeature("forgeSearch") == true,
              let r = try? await connection?.request("forge.search.request", ["cwd": .string(cwd), "query": .string(query), "limit": 20, "kinds": ["change_request"]]),
              r["payload"]?["authState"]?.stringValue == "authenticated" else { return [] }
        return (r["payload"]?["items"]?.arrayValue ?? []).compactMap { i in
            guard let n = i["number"]?.doubleValue, let head = i["headRefName"]?.stringValue else { return nil }
            return ChangeRequest(number: Int(n), title: i["title"]?.stringValue ?? "", headRefName: head,
                                 forge: i["forge"]?.stringValue, projectPath: i["projectPath"]?.stringValue)
        }
    }

    /// Creates a workspace (local directory or new worktree), optionally with a first agent. Waits for the whole creation.
    /// Returns (workspaceId, agentId).
    public func createWorkspace(source: JSONValue, title: String? = nil, agentConfig: [String: JSONValue]? = nil,
                                prompt: String? = nil, images: [ImageAttachment] = [], attachments: [JSONValue] = []) async throws -> (String?, String?) {
        var params: [String: JSONValue] = ["idempotencyKey": .string("ws-" + UUID().uuidString.lowercased()), "source": source]
        if let title { params["title"] = .string(title) }
        if let agentConfig {
            var agent: [String: JSONValue] = ["config": .object(agentConfig), "labels": [:]]
            if let prompt {
                agent["initialPrompt"] = .string(prompt)
                let mid = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                agent["clientMessageId"] = .string(mid)
                if !images.isEmpty {
                    try await persistMessageImages(images, messageId: mid)
                    sentImages[mid] = images
                    agent["images"] = .array(images.map(\.json))
                }
            }
            if !attachments.isEmpty { agent["attachments"] = .array(attachments) }
            params["agent"] = .object(agent)
        }
        let r = try await conn().request("workspace.create.request", params, timeout: .seconds(900))
        let p = r["payload"]
        if let e = p?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? e["message"]?.stringValue ?? String(localized: "创建工作区失败", bundle: .module)) }
        if let w = p?["workspace"].flatMap(Workspace.init) { workspaces[w.id] = w }
        if let a = p?["agent"].flatMap(Agent.init) { agents[a.id] = a }
        return (p?["workspace"]?["id"]?.stringValue, p?["agent"]?["id"]?.stringValue)
    }

    /// Registers a directory as a project (idempotent).
    public func addProject(cwd: String) async throws -> Project? {
        let r = try await conn().request("project.add.request", ["cwd": .string(cwd)])
        if r["payload"]?["errorCode"]?.stringValue == "directory_not_found" { throw ActionError.rejected(String(localized: "目录不存在", bundle: .module)) }
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? String(localized: "添加项目失败", bundle: .module)) }
        let p = r["payload"]?["project"].flatMap(Project.init)
        if let p { projects[p.id] = p }
        return p
    }

    /// Folders sessions of one provider ran in over the last 30 days, minus existing projects (`projectSuggestions`).
    /// Scans the provider's history, so ask per provider: a slow one then holds up only itself.
    public func projectSuggestions(provider: String) async throws -> [ProjectSuggestion] {
        let r = try await conn().request("project.suggestions.request", ["providers": [.string(provider)]], timeout: .seconds(60))
        return (r["payload"]?["suggestions"]?.arrayValue ?? []).compactMap(ProjectSuggestion.init)
    }

    /// Creates `parent/name` on the host and registers it as a project.
    public func createProjectDirectory(parent: String, name: String) async throws -> Project? {
        let r = try await conn().request("project.create_directory.request", ["parentPath": .string(parent), "name": .string(name)], timeout: .seconds(60))
        let p = r["payload"]
        if let e = p?["error"], e != .null {
            let messages = ["invalid_name": String(localized: "名字不合法", bundle: .module), "parent_directory_not_found": String(localized: "父目录不存在", bundle: .module), "directory_exists": String(localized: "这个目录已经存在", bundle: .module),
                            "permission_denied": String(localized: "没有权限", bundle: .module), "registration_failed": String(localized: "目录建好了，但注册项目失败", bundle: .module)]
            throw ActionError.rejected(p?["errorCode"]?.stringValue.flatMap { messages[$0] } ?? e.stringValue ?? String(localized: "新建目录失败", bundle: .module))
        }
        let project = p?["project"].flatMap(Project.init)
        if let project { projects[project.id] = project }
        return project
    }

    public struct GitHubRepo: Sendable, Identifiable, Hashable {
        public let id: String
        public let nameWithOwner: String
        public let name: String
        public let description: String?
        public let isPrivate: Bool
        public let cloneUrl: String
    }

    /// Repositories visible to the host's GitHub account; `unavailable` explains why search does not work.
    public func searchGitHubRepositories(_ query: String) async throws -> (repos: [GitHubRepo], unavailable: String?) {
        let r = try await conn().request("workspace.github.search_repositories.request", ["query": .string(query), "limit": 30], timeout: .seconds(30))
        let p = r["payload"]
        let repos = (p?["repositories"]?.arrayValue ?? []).compactMap { v -> GitHubRepo? in
            guard let id = v["id"]?.stringValue, let nwo = v["nameWithOwner"]?.stringValue, let url = v["cloneUrl"]?.stringValue else { return nil }
            return GitHubRepo(id: id, nameWithOwner: nwo, name: v["name"]?.stringValue ?? nwo, description: v["description"]?.stringValue,
                              isPrivate: v["visibility"]?.stringValue != "public", cloneUrl: url)
        }
        let status = p?["status"]?.stringValue
        let unavailable: String? = switch status {
        case "unavailable": String(localized: "主机上没有安装 gh，不能搜索，可以直接填仓库地址", bundle: .module)
        case "unauthenticated": String(localized: "主机上的 gh 未登录，不能搜索，可以直接填仓库地址", bundle: .module)
        case "error": p?["error"]?.stringValue ?? String(localized: "搜索 GitHub 仓库失败", bundle: .module)
        default: nil
        }
        return (repos, unavailable)
    }

    /// Clones into `parent/<repo name>` on the host and registers the project. Can take minutes.
    public func cloneGitHubRepository(_ repo: String, protocol proto: String?, parent: String) async throws -> Project? {
        var params: [String: JSONValue] = ["repo": .string(repo), "targetDirectory": .string(parent)]
        if let proto { params["cloneProtocol"] = .string(proto) }
        let r = try await conn().request("project.github.clone.request", params, timeout: .seconds(300))
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? String(localized: "克隆失败", bundle: .module)) }
        let project = r["payload"]?["project"].flatMap(Project.init)
        if let project { projects[project.id] = project }
        return project
    }

    /// `name` nil or empty reverts to the name derived from the directory.
    public func renameProject(_ id: String, name: String?) async throws {
        let r = try await conn().request("project.rename.request", ["projectId": .string(id), "customName": name.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null])
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? e["message"]?.stringValue ?? String(localized: "重命名失败", bundle: .module)) }
    }

    /// Sets the project's icon from image bytes (base64; the daemon accepts a square PNG/JPEG/GIF/WebP up to
    /// 1024×1024 and 512 KB), or back to the automatic one when `base64` is nil. Feature `projectCustomIcon`.
    public func setProjectIcon(_ id: String, base64: String?) async throws {
        let source: JSONValue = base64.map { ["type": "upload", "data": .string($0)] } ?? ["type": "automatic"]
        try check(try await conn().request("project.icon.set.request", ["projectId": .string(id), "source": source]))
    }

    /// Removes the project from Paseo (files on disk stay).
    public func removeProject(_ id: String) async throws {
        let r = try await conn().request("project.remove.request", ["projectId": .string(id)], timeout: .seconds(120))
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? e["message"]?.stringValue ?? String(localized: "移除失败", bundle: .module)) }
        projects[id] = nil
    }

    public func renameWorkspace(_ id: String, title: String?) async throws {
        try check(try await conn().request("workspace.title.set.request", ["workspaceId": .string(id), "title": title.map(JSONValue.string) ?? .null]))
    }

    public func pinWorkspace(_ id: String, pinned: Bool) async throws {
        try check(try await conn().request("workspace.pin.set.request", ["workspaceId": .string(id), "pinned": .bool(pinned)]))
    }

    public func archiveWorkspace(_ id: String) async throws {
        let r = try await conn().request("archive_workspace_request", ["workspaceId": .string(id)], timeout: .seconds(120))
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? String(localized: "归档失败", bundle: .module)) }
        workspaces[id] = nil
    }

    /// 已归档的工作区能不能恢复（官方 workspace.recovery.inspect）：返回 state.kind，如 "recoverable"。
    public func inspectWorkspaceRecovery(_ id: String) async throws -> JSONValue {
        let r = try await conn().request("workspace.recovery.inspect.request", ["workspaceId": .string(id)], timeout: .seconds(30))
        return r["payload"]?["state"] ?? .null
    }

    /// 恢复已归档的工作区（官方 workspace.recovery.restore）。会话还活着而工作区被归档时，官方客户端看不到这个会话，恢复后才会出现。
    public func restoreWorkspace(_ id: String) async throws {
        let r = try await conn().request("workspace.recovery.restore.request", ["workspaceId": .string(id)], timeout: .seconds(120))
        if r["payload"]?["accepted"]?.boolValue != true {
            throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? String(localized: "恢复失败", bundle: .module))
        }
    }

    public func markWorkspaceRead(_ id: String) async throws {
        _ = try await conn().request("workspace.clear_attention.request", ["workspaceId": .string(id)])
    }

    public func markWorkspaceUnread(_ id: String) async throws {
        let r = try await conn().request("workspace.mark_unread.request", ["workspaceId": .string(id)])
        if r["payload"]?["success"]?.boolValue == false { throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? String(localized: "没有可标为未读的会话", bundle: .module)) }
    }

    // MARK: Schedules (no push: callers refetch)

    public func listSchedules(timeout: Duration = .seconds(60)) async throws -> [Schedule] {
        let r = try await conn().request("schedule/list", timeout: timeout)
        try check(r)
        return (r["payload"]?["schedules"]?.arrayValue ?? []).compactMap(Schedule.init)
    }

    public func inspectSchedule(_ id: String, timeout: Duration = .seconds(60)) async throws -> Schedule? {
        let r = try await conn().request("schedule/inspect", ["scheduleId": .string(id)], timeout: timeout)
        try check(r)
        return r["payload"]?["schedule"].flatMap(Schedule.init)
    }

    public func scheduleAction(_ action: String, _ id: String) async throws {
        // run-once replies only when the run ends; don't block the UI on it.
        let timeout: Duration = action == "run-once" ? .seconds(3600) : .seconds(60)
        _ = try await conn().request("schedule/" + action, ["scheduleId": .string(id)], timeout: timeout)
    }

    public func createSchedule(_ params: [String: JSONValue]) async throws {
        _ = try await conn().request("schedule/create", params)
    }

    public func updateSchedule(_ id: String, _ params: [String: JSONValue]) async throws {
        var p = params
        p["scheduleId"] = .string(id)
        _ = try await conn().request("schedule/update", p)
    }

    // MARK: Usage

    /// Streams usage reports (`usage.list_reports.update`) and returns them all once the response arrives.
    /// False when the host switched provider usage queries off (daemon config `usage.enabled`, 0.15+).
    public var usageQueriesEnabled: Bool { daemonConfig?["usage"]?["enabled"]?.boolValue != false }

    public func usageReports(forceRefresh: Bool = false, agentId: String? = nil, onReport: @escaping @MainActor (UsageReport) -> Void) async throws {
        var params: [String: JSONValue] = ["forceRefresh": .bool(forceRefresh)]
        if let agentId { params["agentId"] = .string(agentId) }
        let r = try await conn().request("usage.list_reports.request", params, timeout: .seconds(90)) { update in
            guard let report = update["payload"]?["report"].flatMap(UsageReport.init) else { return }
            Task { @MainActor in onReport(report) }
        }
        if let e = r["payload"]?["error"]?.stringValue { throw ActionError.rejected(e) }
    }

    public func setModel(_ agentId: String, modelId: String?) async throws {
        try check(try await conn().request("set_agent_model_request", ["agentId": .string(agentId), "modelId": modelId.map(JSONValue.string) ?? .null]))
    }

    public func rename(_ agentId: String, to name: String) async throws {
        try check(try await conn().request("update_agent_request", ["agentId": .string(agentId), "name": .string(name)]))
    }

    public func archive(_ agentId: String) async throws {
        _ = try await conn().request("archive_agent_request", ["agentId": .string(agentId)])
    }

    public func clearAttention(_ agentId: String) {
        guard let c = connection, agents[agentId]?.requiresAttention == true else { return }
        Task { _ = try? await c.request("clear_agent_attention", ["agentId": .string(agentId)]) }
    }

    /// Creates a session in a workspace and sends the first prompt. Returns the new agent id.
    public func createAgent(workspace: Workspace, provider: String, model: String?, modeId: String?, thinkingOptionId: String? = nil,
                            prompt: String, images: [ImageAttachment] = [], attachments: [JSONValue] = []) async throws -> String {
        var config: [String: JSONValue] = ["provider": .string(provider), "cwd": .string(workspace.directory)]
        if let model { config["model"] = .string(model) }
        if let modeId { config["modeId"] = .string(modeId) }
        if let thinkingOptionId { config["thinkingOptionId"] = .string(thinkingOptionId) }
        let clientMessageId = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await persistMessageImages(images, messageId: clientMessageId)
        if !images.isEmpty { sentImages[clientMessageId] = images }
        var params: [String: JSONValue] = [
            "idempotencyKey": .string("create-" + UUID().uuidString.lowercased()),
            "workspaceId": .string(workspace.id),
            "config": .object(config),
            "initialPrompt": .string(prompt),
            "clientMessageId": .string(clientMessageId),
            "labels": [:],
        ]
        if !images.isEmpty { params["images"] = .array(images.map(\.json)) }
        if !attachments.isEmpty { params["attachments"] = .array(attachments) }
        let r = try await conn().request("agent.create.request", params)
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e.stringValue ?? e["message"]?.stringValue ?? String(localized: "创建失败", bundle: .module)) }
        guard let a = r["payload"]?["agent"].flatMap(Agent.init) else { throw ActionError.rejected(String(localized: "创建失败", bundle: .module)) }
        agents[a.id] = a
        return a.id
    }

    public func loadProviders(cwd: String?) async {
        var params: [String: JSONValue] = [:]
        if let cwd { params["cwd"] = .string(cwd) }
        guard let r = try? await connection?.request("get_providers_snapshot_request", params) else { return }
        providers = r["payload"]?["entries"]?.arrayValue ?? []
        providersCwd = cwd
    }

    public func fetchHistory(search: String?) async throws -> [Agent] {
        try await fetchHistoryPage(search: search, cursor: nil).agents
    }

    /// One page of the history (newest first); `nextCursor` is nil on the last page.
    public func fetchHistoryPage(search: String?, cursor: String?, limit: Int = 100) async throws -> (agents: [Agent], nextCursor: String?) {
        var page: [String: JSONValue] = ["limit": .number(Double(min(limit, 200)))]
        if let cursor { page["cursor"] = .string(cursor) }
        var params: [String: JSONValue] = ["sort": [["key": "updated_at", "direction": "desc"]], "page": .object(page)]
        if let search, !search.isEmpty { params["search"] = .string(search) }
        let r = try await conn().request("fetch_agent_history_request", params)
        let agents = (r["payload"]?["entries"]?.arrayValue ?? []).compactMap { Agent($0["agent"] ?? $0) }
        let info = r["payload"]?["pageInfo"]
        let next = info?["hasMore"]?.boolValue == true ? info?["nextCursor"]?.stringValue : nil
        return (agents, next)
    }

    public func unarchive(_ agentId: String) async throws {
        _ = try await conn().request("refresh_agent_request", ["agentId": .string(agentId)])
    }

    /// The daemon bumps `updatedAt` on every streamed event but only pushes the agent on state changes;
    /// refetch running ones so "how long since it last did something" stays true.
    public func refreshRunningAgents() {
        guard state == .connected else { return }
        for a in agents.values where a.status == .running && a.archivedAt == nil { refreshAgent(a.id) }
    }

    private func refreshAgent(_ agentId: String) {
        guard let c = connection else { return }
        Task {
            guard let r = try? await c.request("fetch_agent_request", ["agentId": .string(agentId)]),
                  let a = r["payload"]?["agent"].flatMap(Agent.init) else { return }
            if a.archivedAt == nil { agents[a.id] = a }
        }
    }

    // MARK: Presence

    /// The daemon only pushes when no client was active in the last 180 s, so report visibility promptly.
    public func setAppVisible(_ visible: Bool) {
        guard visible != appVisible else { return }
        appVisible = visible
        visibilityChangedAt = Date()
        if visible { lastActivityAt = Date() }
        sendHeartbeat()
        if visible {
            if state == .connected, let c = connection {
                Task { await c.validateOnForeground() }
            } else {
                reconnectNow()
            }
            Task { await recheckUnavailableProviders() }
        }
    }

    public func noteActivity() { lastActivityAt = Date() }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        sendHeartbeat()
        heartbeatTask = Task {
            await measureLatency()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                sendHeartbeat()
                await measureLatency()
                heartbeatTicks += 1
                if heartbeatTicks % 2 == 0 { pollIdleProviderSubagents() }
            }
        }
    }

    /// Session `ping` → `pong` (the RPC the official app uses to pick the fastest connection). A timeout or
    /// error leaves the last value; a closed connection clears it (runLoop / stop).
    private func measureLatency() async {
        guard let c = connection else { return }
        let start = ContinuousClock.now
        // Whole milliseconds: the daemon ignores a fractional clientSentAt (no pong, the request times out).
        let sent = (Date().timeIntervalSince1970 * 1000).rounded()
        guard (try? await c.request("ping", ["clientSentAt": .number(sent)], timeout: .seconds(5))) != nil,
              connection === c else { return }
        let elapsed = ContinuousClock.now - start
        latencyMs = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
    }

    func sendHeartbeat() {
        guard let c = connection else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let params: [String: JSONValue] = [
            "deviceType": "mobile",
            "focusedAgentId": focusedAgentId.map(JSONValue.string) ?? .null,
            "focusedTerminalId": focusedTerminalId.map(JSONValue.string) ?? .null,
            "lastActivityAt": .string(iso.string(from: lastActivityAt)),
            "appVisible": .bool(appVisible),
            "appVisibilityChangedAt": .string(iso.string(from: visibilityChangedAt)),
        ]
        Task { try? await c.send("client_heartbeat", params) }
    }
}
