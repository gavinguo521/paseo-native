#if os(iOS)
import CryptoKit
import Foundation
import Observation
import OSLog
import PaseoKit
import PaseoWatchBridge
import UIKit
import WatchConnectivity

/// The phone is the sole daemon client. The watch receives bounded snapshots and explicit receipts.
@MainActor
final class WatchCompanion: NSObject, WCSessionDelegate {
    static let shared = WatchCompanion()
    private weak var model: AppModel?
    private var session: WCSession?
    private var pages: [String: WatchSessionPage] = [:]
    private var publishTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Paseo", category: "Watch")
    private let ledger = WatchActionLedger(file: URL.applicationSupportDirectory.appending(path: "watch-actions.json"))

    func start(model: AppModel) {
        guard WCSession.isSupported(), self.model == nil else { return }
        self.model = model
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        observe()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            for host in model.hosts {
                _ = host.label; _ = host.state; _ = host.agents; _ = host.workspaces
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.schedulePublish()
            }
        }
    }

    private func schedulePublish() {
        guard publishTask == nil, session?.isWatchAppInstalled == true else { return }
        publishTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // Only actively running phone data is offered as a fresh passive snapshot.
            if UIApplication.shared.applicationState != .background, let model {
                for host in model.hosts where host.state == .connected {
                    let rows = host.agents.values.filter { $0.archivedAt == nil && !$0.isSubagent }
                    let summaries = rows.map { summary($0, host: host) }.sorted(by: Self.sessionOrder)
                    if pages[host.id]?.sessions != Array(summaries.prefix(60)) {
                        pages[host.id] = WatchSessionPage(hostID: host.id, sessions: Array(summaries.prefix(60)), hasMore: summaries.count > 60)
                    }
                }
            }
            publish()
            publishTask = nil
        }
    }

    private func overview() -> WatchOverview {
        let hosts = model?.hosts.map { WatchHost(id: $0.id, name: String($0.label.prefix(100))) } ?? []
        // Context is a fast preview; the watch requests each selected host independently for its full page.
        var preview = WatchOverview(hosts: hosts, pages: hosts.compactMap { pages[$0.id] })
        for index in preview.pages.indices {
            if preview.pages[index].sessions.count > 8 { preview.pages[index].hasMore = true }
            preview.pages[index].sessions = Array(preview.pages[index].sessions.prefix(8))
        }
        // Many paired hosts must still fit WCSession's payload budget.
        while (try? WatchEnvelope(payload: .overview(preview)).encoded()) == nil,
              let index = preview.pages.indices.max(by: { preview.pages[$0].sessions.count < preview.pages[$1].sessions.count }),
              !preview.pages[index].sessions.isEmpty {
            preview.pages[index].sessions.removeLast()
            preview.pages[index].hasMore = true
        }
        return preview
    }

    private func publish() {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }
        do { try session.updateApplicationContext([WatchEnvelope.key: try WatchEnvelope(payload: .overview(overview())).encoded()]) }
        catch { logger.debug("Watch context not delivered: \(String(describing: error), privacy: .public)") }
    }

    private func readyHost(_ id: String) async throws -> HostStore {
        guard let model, let host = model.host(id) else { throw CompanionError(String(localized: "这台主机已从 iPhone 移除")) }
        model.start()
        try await host.prepareForCompanionRequest()
        return host
    }

    private func handle(_ request: WatchRequest) async -> WatchPayload {
        let background = UIApplication.shared.beginBackgroundTask(withName: "paseo.watch")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            if request.command.isAction {
                let result = await ledger.execute(request) { @MainActor [weak self] in
                    guard let self else { return .init(.notSent, "phone-unavailable") }
                    return await self.performAction(request)
                }
                return .action(localized(result))
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            for attempt in 0..<2 {
                do { return try await read(request.command, deadline: deadline) }
                catch {
                    guard attempt == 0, HostStore.isConnectionLoss(error),
                          ContinuousClock.now.duration(to: deadline) > .seconds(10) else { throw error }
                    logger.info("Recovering host connection before retrying watch read")
                }
            }
            throw CompanionError(String(localized: "主机连接超时，请稍后刷新"))
        } catch { return .failure(readableError(error)) }
    }

    private func read(_ command: WatchCommand, deadline: ContinuousClock.Instant) async throws -> WatchPayload {
        switch command {
        case .overview:
            return .overview(overview())
        case .sessions(let hostID):
            let host = try await readyHost(hostID)
            let agents = try await host.fetchRecentAgents(timeout: readBudget(deadline))
            let summaries = agents.filter { $0.archivedAt == nil && !$0.isSubagent }.map { summary($0, host: host) }.sorted(by: Self.sessionOrder)
            let page = WatchSessionPage(hostID: hostID, sessions: summaries, hasMore: agents.count >= 60)
            pages[hostID] = page
            publish()
            return .sessions(page)
        case .session(let ref):
            let host = try await readyHost(ref.hostID)
            let timeout = try readBudget(deadline)
            async let agentRead = host.fetchAgentSnapshot(ref.agentID, timeout: timeout)
            async let timelineRead = host.fetchRecentTimeline(ref.agentID, timeout: timeout)
            let (agent, timeline) = try await (agentRead, timelineRead)
            let messages = timeline.rows.compactMap { row -> WatchMessage? in
                let role: String, text: String
                switch row.item {
                case .userMessage(let value, _): role = "user"; text = value
                case .assistantMessage(let value, _): role = "assistant"; text = value
                case .error(let value): role = "error"; text = value
                default: return nil
                }
                let compact = WatchMessageText.compact(text, role: role)
                guard !compact.isEmpty else { return nil }
                return WatchMessage(id: row.id, role: role, text: String(compact.prefix(800)), truncated: compact.count > 800, timestamp: row.timestamp)
            }
            return .session(WatchSessionDetail(session: summary(agent, host: host), messages: Array(messages.suffix(8)),
                                               permissions: Array(agent.pendingPermissions.prefix(4)).map(permission)))
        case .schedules(let hostID):
            let host = try await readyHost(hostID)
            let schedules = try await host.listSchedules(timeout: readBudget(deadline))
            return .schedules(WatchSchedulePage(hostID: hostID, schedules: schedules.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(50).map { schedule($0, host: host, detail: false) }, hasMore: schedules.count > 50))
        case .schedule(let hostID, let scheduleID):
            let host = try await readyHost(hostID)
            guard let value = try await host.inspectSchedule(scheduleID, timeout: readBudget(deadline)) else { throw CompanionError(String(localized: "计划任务已不存在")) }
            return .schedule(schedule(value, host: host, detail: true))
        case .actionStatus(let id):
            return .action(await actionStatus(id))
        case .reply, .permission:
            return .failure(String(localized: "不支持的操作"))
        }
    }

    private func readBudget(_ deadline: ContinuousClock.Instant) throws -> Duration {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw DaemonConnectionError.timeout("watch read") }
        return min(.seconds(8), remaining)
    }

    private func readableError(_ error: any Error) -> String {
        logger.error("Watch request failed: \(String(describing: error), privacy: .public)")
        if HostStore.isConnectionLoss(error) {
            return String(localized: "与主机的连接已中断，正在恢复，请稍后刷新")
        }
        if case DaemonConnectionError.timeout = error { return String(localized: "主机响应超时，请稍后刷新") }
        return String(describing: error)
    }

    private func performAction(_ request: WatchRequest) async -> WatchActionResult {
        var dispatched = false
        do {
            switch request.command {
            case .reply(let ref, let text):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.utf8.count <= 12_000 else { return .init(.notSent, String(localized: "消息为空或过长，请编辑后发送")) }
                let host = try await readyHost(ref.hostID)
                let agent = try await host.fetchAgentSnapshot(ref.agentID)
                guard agent.archivedAt == nil, agent.status != .closed else { return .init(.notSent, String(localized: "会话已关闭，消息未发送")) }
                dispatched = true
                do {
                    try await host.send(text, to: ref.agentID, steer: true, messageID: request.messageID, timeout: .seconds(8))
                } catch HostStore.ActionError.rejected(let message) {
                    // 主机明确拒绝了这条消息；保留错误，让手表解除待确认状态后可编辑重发。
                    return .init(.notSent, message)
                }
                return .init(.confirmed, String(localized: "消息已发送"))
            case .permission(let ref, let requestID, let revision, let actionID):
                let host = try await readyHost(ref.hostID)
                let agent = try await host.fetchAgentSnapshot(ref.agentID)
                guard let current = agent.pendingPermissions.first(where: { $0.id == requestID }) else {
                    return .init(.notSent, String(localized: "这个请求已处理，请刷新会话"))
                }
                let display = permission(current)
                guard let action = display.action(id: actionID, expectedRevision: revision) else {
                    return .init(.notSent, String(localized: "请求内容已变化，请刷新后重新查看"))
                }
                var response: [String: JSONValue] = ["behavior": .string(action.behavior)]
                if !current.actions.isEmpty { response["selectedActionId"] = .string(action.id) }
                if action.behavior == "deny" {
                    response["message"] = current.kind == "question" ? "Dismissed by user" : "Denied by user"
                } else if current.kind == "question" {
                    guard let form = display.questionForm, let input = current.input,
                          let answers = request.questionAnswers,
                          let updated = try? form.updatedInput(JSONEncoder().encode(input), answers: answers),
                          let decoded = try? JSONDecoder().decode(JSONValue.self, from: updated) else {
                        return .init(.notSent, String(localized: "回答内容无效，请重新选择或输入"))
                    }
                    response["updatedInput"] = decoded
                }
                dispatched = true
                try await host.respond(to: current, agentId: ref.agentID, response: response)
                for _ in 0..<3 {
                    let fresh = try await host.fetchAgentSnapshot(ref.agentID, timeout: .seconds(3))
                    if !fresh.pendingPermissions.contains(where: { $0.id == requestID }) {
                        return .init(.confirmed, String(localized: "请求已处理"))
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
                return .init(.uncertain, String(localized: "操作已发出，尚未确认结果"))
            default: return .init(.notSent, String(localized: "不支持的操作"))
            }
        } catch {
            return .init(dispatched ? .uncertain : .notSent,
                         dispatched ? String(localized: "尚未确认结果，请查询状态，避免重复发送") : readableError(error))
        }
    }

    private func actionStatus(_ id: UUID) async -> WatchActionResult {
        if let result = await ledger.result(for: id), result.state != .uncertain { return localized(result) }
        guard let original = await ledger.request(for: id) else {
            return .init(.uncertain, String(localized: "尚未收到操作记录，请保持 iPhone 可连接后重试"))
        }
        do {
            switch original.command {
            case .reply(let ref, _):
                let host = try await readyHost(ref.hostID)
                let timeline = try await host.fetchRecentTimeline(ref.agentID)
                if timeline.rows.contains(where: { row in
                    if case .userMessage(_, let messageID) = row.item { return messageID == original.messageID }
                    return false
                }) {
                    let message = String(localized: "消息已发送")
                    await ledger.confirm(id, message: message)
                    return .init(.confirmed, message)
                }
            case .permission(let ref, let requestID, _, _):
                let host = try await readyHost(ref.hostID)
                let fresh = try await host.fetchAgentSnapshot(ref.agentID)
                if !fresh.pendingPermissions.contains(where: { $0.id == requestID }) {
                    let message = String(localized: "请求已处理")
                    await ledger.confirm(id, message: message)
                    return .init(.confirmed, message)
                }
            default: break
            }
        } catch { /* Keep the uncertain receipt; do not repeat a mutation. */ }
        return .init(.uncertain, String(localized: "尚未确认结果，请刷新会话查看"))
    }

    private func localized(_ result: WatchActionResult) -> WatchActionResult {
        var result = result
        switch result.message {
        case "request-expired": result.message = String(localized: "操作已过期，请重新查看后操作")
        case "request-mismatch", "invalid-ledger", "cannot-save-action": result.message = String(localized: "无法安全记录操作，未发送")
        case "result-unconfirmed": result.message = String(localized: "尚未确认结果，请查询状态，避免重复发送")
        case "phone-unavailable": result.message = String(localized: "请在 iPhone 上打开 Paseo 后重试")
        default: break
        }
        return result
    }

    private func summary(_ agent: Agent, host: HostStore) -> WatchSessionSummary {
        let status: WatchSessionStatus
        switch agent.bucket {
        case .needsInput: status = .waiting
        case .failed: status = .failed
        case .running: status = .running
        case .attention: status = .attention
        case .done: status = .done
        }
        return WatchSessionSummary(ref: .init(hostID: host.id, agentID: agent.id), title: String(agent.displayTitle.prefix(160)),
                                   hostName: String(host.label.prefix(100)), status: status, updatedAt: agent.updatedAt, startedAt: agent.activeTurnStartedAt)
    }

    private static func sessionOrder(_ a: WatchSessionSummary, _ b: WatchSessionSummary) -> Bool {
        if a.status.priority != b.status.priority { return a.status.priority < b.status.priority }
        return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
    }

    private func permission(_ request: PermissionRequest) -> WatchPermission {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let raw = (try? encoder.encode(request.raw)) ?? Data()
        let revision = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let isQuestion = request.kind == "question"
        let actions = request.actions.isEmpty
            ? [WatchPermissionAction(id: "deny", label: isQuestion ? String(localized: "跳过") : String(localized: "拒绝"), behavior: "deny"),
               WatchPermissionAction(id: "allow", label: isQuestion ? String(localized: "提交") : String(localized: "允许本次"), behavior: "allow")]
            : request.actions.filter { $0.behavior == "allow" || $0.behavior == "deny" }.map { WatchPermissionAction(id: $0.id, label: $0.label, behavior: $0.behavior) }
        if isQuestion {
            let form = request.input.flatMap { try? WatchQuestionForm(inputData: encoder.encode($0)) }
            let needsPhone = form == nil || !actions.contains(where: { $0.behavior == "allow" })
            return WatchPermission(id: request.id, title: String(localized: "回答问题"),
                                   detail: String((form?.questions.first?.text ?? request.description ?? String(localized: "请在 iPhone 上查看此问答")).prefix(1_200)),
                                   revision: revision, actions: needsPhone ? [] : actions, needsPhone: needsPhone,
                                   kind: request.kind, questionForm: form)
        }
        var parts = [String]()
        if let description = request.description, !description.isEmpty { parts.append(description) }
        if let plan = request.planText { parts.append(plan) }
        else if let input = request.input {
            // Keep all tool parameters, including paths and flags, in the approval preview.
            parts.append(input.description)
            if case .shell(_, let cwd?, _, _) = request.detail { parts.append("cwd: " + cwd) }
        } else if let detail = request.raw["detail"] {
            parts.append(detail.description)
        }
        let detail = parts.joined(separator: "\n\n")
        let needsPhone = !["tool", "plan"].contains(request.kind) || detail.isEmpty || detail.count > 1_200 || actions.isEmpty
        return WatchPermission(id: request.id, title: String((request.title ?? request.name ?? String(localized: "请求批准")).prefix(100)),
                               detail: String(detail.prefix(1_200)), revision: revision, actions: needsPhone ? [] : actions, needsPhone: needsPhone, kind: request.kind)
    }

    private func schedule(_ value: Schedule, host: HostStore, detail: Bool) -> WatchSchedule {
        WatchSchedule(hostID: host.id, scheduleID: value.id, hostName: String(host.label.prefix(100)), title: String(value.title.prefix(160)),
                      status: value.isExpired ? "expired" : value.status, nextRunAt: value.nextRunAt, lastRunAt: value.lastRunAt,
                      prompt: detail ? String(value.prompt.prefix(1_500)) : "",
                      runs: detail ? value.runs.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }.prefix(5).map {
                          WatchScheduleRun(id: $0.id, status: $0.status, startedAt: $0.startedAt, output: String(($0.error ?? $0.output ?? "").prefix(1_000)), agentID: $0.agentId)
                      } : [])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.schedulePublish() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.schedulePublish() } }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message[WatchEnvelope.key] as? Data else { replyHandler([:]); return }
        // WCSession owns this callback across queues. The box is immutable and invoked exactly once.
        let reply = WatchReply(replyHandler)
        Task { @MainActor in
            UserDefaults.standard.set(["event": "received", "time": Date().timeIntervalSince1970,
                                       "applicationState": UIApplication.shared.applicationState.rawValue], forKey: "watch.transportStatus")
            let response: WatchEnvelope
            do {
                guard let request = try WatchEnvelope.decode(data).request else { throw CompanionError("Invalid request") }
                response = WatchEnvelope(requestID: request.id, payload: await self.handle(request))
            } catch { response = WatchEnvelope(payload: .failure(String(localized: "请更新 iPhone 和手表上的 Paseo 后重试"))) }
            do {
                reply.send([WatchEnvelope.key: try response.encoded()])
                UserDefaults.standard.set(["event": "replied", "time": Date().timeIntervalSince1970,
                                           "applicationState": UIApplication.shared.applicationState.rawValue], forKey: "watch.transportStatus")
            }
            catch {
                let fallback = WatchEnvelope(requestID: response.requestID, payload: .failure(String(localized: "内容过多，请在 iPhone 上查看")))
                reply.send([WatchEnvelope.key: (try? fallback.encoded()) ?? Data()])
            }
        }
    }
}

private struct CompanionError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private final class WatchReply: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ message: [String: Any]) { callback(message) }
}
#endif
