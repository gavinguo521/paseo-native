import Foundation
import Observation
import OSLog
import PaseoWatchBridge
import WatchConnectivity
import WatchKit

@MainActor @Observable
final class WatchClient: NSObject, WCSessionDelegate {
    static let shared = WatchClient()
    var overview: WatchOverview
    var schedulePages: [String: WatchSchedulePage]
    var details: [String: WatchSessionDetail] = [:]
    var hostErrors: [String: String] = [:]
    var error: String?
    var loadingHosts: Set<String> = []
    var refreshing = false
    var pendingRoute: WatchSessionRef?
    private(set) var connectionRevision = 0
    var selectedHostID: String? {
        didSet { UserDefaults.standard.set(selectedHostID, forKey: "watch.host") }
    }
    var section = 0
    private(set) var pendingActions: [String: WatchRequest]
    @ObservationIgnored private let session = WCSession.default
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaseoWatch", category: "Connectivity")
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var replies: [UUID: CheckedContinuation<WatchPayload, any Error>] = [:]
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]

    override init() {
        let defaults = UserDefaults.standard
        overview = defaults.data(forKey: "watch.overview").flatMap { try? JSONDecoder().decode(WatchOverview.self, from: $0) } ?? .init()
        schedulePages = defaults.data(forKey: "watch.schedules").flatMap { try? JSONDecoder().decode([String: WatchSchedulePage].self, from: $0) } ?? [:]
        pendingActions = defaults.data(forKey: "watch.pendingActions").flatMap { try? JSONDecoder().decode([String: WatchRequest].self, from: $0) } ?? [:]
        selectedHostID = defaults.string(forKey: "watch.host")
        super.init()
        session.delegate = self
        session.activate()
    }

    var visibleHosts: [WatchHost] { overview.hosts.filter { selectedHostID == nil || $0.id == selectedHostID } }
    var sessions: [WatchSessionSummary] { overview.sessions(hostID: selectedHostID) }
    var schedules: [WatchSchedule] {
        visibleHosts.flatMap { schedulePages[$0.id]?.schedules ?? [] }.sorted {
            if ($0.status == "active") != ($1.status == "active") { return $0.status == "active" }
            return ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture)
        }
    }
    var refreshedAt: Date? {
        let dates = visibleHosts.compactMap { host in
            section == 0 ? overview.pages.first { $0.hostID == host.id }?.refreshedAt : schedulePages[host.id]?.refreshedAt
        }
        return dates.min()
    }

    func refresh() async {
        generation += 1
        let epoch = generation
        let selected = selectedHostID
        let section = section
        refreshing = true; error = nil; hostErrors = [:]; loadingHosts = []
        defer { if generation == epoch { refreshing = false; loadingHosts = [] } }
        do {
            if case .overview(let value) = try await request(.init(command: .overview)) {
                guard epoch == generation, !Task.isCancelled else { return }
                merge(value)
            }
        } catch is CancellationError { return }
        catch {
            if epoch == generation { self.error = error.localizedDescription }
            return
        }
        let hosts = overview.hosts.filter { selected == nil || $0.id == selected }
        loadingHosts = Set(hosts.map(\.id))
        // Each result is applied as it arrives; a slow or offline host never holds back another.
        await withTaskGroup(of: (String, WatchPayload).self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        let command: WatchCommand = section == 0 ? .sessions(hostID: host.id) : .schedules(hostID: host.id)
                        return (host.id, try await self.request(.init(command: command)))
                    } catch { return (host.id, .failure(error.localizedDescription)) }
                }
            }
            for await (id, payload) in group {
                guard generation == epoch, !Task.isCancelled else { group.cancelAll(); return }
                loadingHosts.remove(id)
                switch payload {
                case .sessions(let page): overview.merge(page); saveOverview()
                case .schedules(let page):
                    if (schedulePages[page.hostID]?.refreshedAt ?? .distantPast) <= page.refreshedAt { schedulePages[page.hostID] = page }
                    UserDefaults.standard.set(try? JSONEncoder().encode(schedulePages), forKey: "watch.schedules")
                case .failure(let message): hostErrors[id] = message
                default: break
                }
            }
        }
    }

    func invalidateRefresh() { generation += 1; refreshing = false; loadingHosts = [] }

    func loadSession(_ ref: WatchSessionRef) async throws -> WatchSessionDetail {
        guard case .session(let value) = try await request(.init(command: .session(ref))) else { throw ClientError.invalidResponse }
        details[ref.id] = value
        return value
    }

    func loadSchedule(_ value: WatchSchedule) async throws -> WatchSchedule {
        guard case .schedule(let detail) = try await request(.init(command: .schedule(hostID: value.hostID, scheduleID: value.scheduleID))) else { throw ClientError.invalidResponse }
        return detail
    }

    static func actionKey(_ command: WatchCommand) -> String {
        switch command {
        case .reply(let ref, _): return ref.id + "/reply"
        case .permission(let ref, let id, _, _): return ref.id + "/permission/" + id
        default: return "invalid"
        }
    }

    func perform(_ command: WatchCommand, questionAnswers: [String: WatchQuestionAnswer]? = nil) async -> WatchActionResult {
        if case .reply(_, let text) = command,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 12_000 {
            return .init(.notSent, String(localized: "消息为空或过长，请编辑后发送"))
        }
        let key = Self.actionKey(command)
        let previous = pendingActions[key]
        if previous == nil {
            do { try await waitForPhone() }
            catch { return .init(.notSent, error.localizedDescription) }
        }
        // Reuse the exact original request after a lost reply, including its text and timestamp.
        let action = previous ?? WatchRequest(command: command, questionAnswers: questionAnswers)
        pendingActions[key] = action
        saveActions()
        do {
            guard case .action(var result) = try await request(action) else { throw ClientError.invalidResponse }
            if result.state == .uncertain,
               case .action(let checked) = try? await request(.init(command: .actionStatus(action.id))) { result = checked }
            if result.state != .uncertain { pendingActions[key] = nil; saveActions() }
            if result.state == .confirmed { WKInterfaceDevice.current().play(.success) }
            else { WKInterfaceDevice.current().play(.failure) }
            return result
        } catch {
            // Delivery errors do not prove the daemon did not act. Keep the ID until reconciled.
            return .init(.uncertain, String(localized: "尚未确认结果，请重试核对，原操作不会重复发送"))
        }
    }

    func savedReply(for ref: WatchSessionRef) -> String? {
        if case .reply(_, let text) = pendingActions[ref.id + "/reply"]?.command { return text }
        return UserDefaults.standard.string(forKey: "watch.draft." + ref.id)
    }
    func saveDraft(_ text: String, for ref: WatchSessionRef) { UserDefaults.standard.set(text, forKey: "watch.draft." + ref.id) }
    private func saveActions() { UserDefaults.standard.set(try? JSONEncoder().encode(pendingActions), forKey: "watch.pendingActions") }
    private func saveOverview() { UserDefaults.standard.set(try? JSONEncoder().encode(overview), forKey: "watch.overview") }

    private func merge(_ value: WatchOverview) {
        overview.merge(value)
        if let selectedHostID, !value.hosts.contains(where: { $0.id == selectedHostID }) { self.selectedHostID = nil }
        let ids = Set(value.hosts.map(\.id))
        schedulePages = schedulePages.filter { ids.contains($0.key) }
        saveOverview()
    }

    private func request(_ request: WatchRequest) async throws -> WatchPayload {
        do { return try await transmit(request) }
        catch ClientError.unreachable where !request.command.isAction {
            // Briefly wait for the companion to wake; never turn a connectivity retry into an action.
            try await Task.sleep(for: .milliseconds(700))
            return try await transmit(request)
        }
    }

    private func waitForPhone() async throws {
        if session.activationState == .notActivated { session.activate() }
        for _ in 0..<40 {
            try Task.checkCancellation()
            // The active watch's message is also the wake-up request for the phone. A transient
            // isReachable=false must not prevent us from attempting that foreground delivery.
            if session.activationState == .activated { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClientError.unreachable
    }

    private func transmit(_ request: WatchRequest) async throws -> WatchPayload {
        try await waitForPhone()
        let data = try WatchEnvelope(request: request).encoded()
        let attemptID = UUID()
        UserDefaults.standard.set(["event": "send", "time": Date().timeIntervalSince1970,
                                   "reachable": session.isReachable], forKey: "watch.transportStatus")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                replies[attemptID] = continuation
                timeouts[attemptID] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(28)) } catch { return }
                    self?.finish(attemptID, .failure(ClientError.timeout))
                }
                // WCSession invokes these callbacks on its own queue. Explicit Sendable closures
                // prevent Swift 6 from inheriting MainActor and trapping before the Task hop.
                session.sendMessage([WatchEnvelope.key: data]) { @Sendable [weak self] message in
                    let data = message[WatchEnvelope.key] as? Data
                    Task { @MainActor in
                        do {
                            guard let data else { throw ClientError.invalidResponse }
                            let response = try WatchEnvelope.decode(data)
                            if case .failure(let message) = response.payload { throw ClientError.remote(message) }
                            guard response.requestID == request.id, let payload = response.payload else { throw ClientError.invalidResponse }
                            UserDefaults.standard.set(["event": "reply", "time": Date().timeIntervalSince1970], forKey: "watch.transportStatus")
                            self?.finish(attemptID, .success(payload))
                        } catch { self?.finish(attemptID, .failure(error)) }
                    }
                } errorHandler: { @Sendable [weak self] error in
                    let description = error.localizedDescription
                    let code = (error as NSError).code
                    Task { @MainActor in
                        self?.logger.error("Phone message failed (\(code)): \(description, privacy: .public)")
                        UserDefaults.standard.set(["event": "error", "time": Date().timeIntervalSince1970, "code": code], forKey: "watch.transportStatus")
                        let failure: ClientError
                        switch code {
                        case WCError.Code.messageReplyTimedOut.rawValue: failure = .timeout
                        case WCError.Code.notReachable.rawValue, WCError.Code.sessionNotActivated.rawValue,
                             WCError.Code.deliveryFailed.rawValue, WCError.Code.sessionInactive.rawValue: failure = .unreachable
                        default: failure = .remote(String(localized: "iPhone 暂时无法处理请求，请稍后重试"))
                        }
                        self?.finish(attemptID, .failure(failure))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(attemptID, .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, _ result: Result<WatchPayload, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(with: result)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let data = session.receivedApplicationContext[WatchEnvelope.key] as? Data
        Task { @MainActor in self.applyContext(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchEnvelope.key] as? Data
        Task { @MainActor in self.applyContext(data) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            if reachable { self.connectionRevision += 1 }
        }
    }
    private func applyContext(_ data: Data?) {
        guard let data, let envelope = try? WatchEnvelope.decode(data), case .overview(let value) = envelope.payload else { return }
        merge(value)
    }

    enum ClientError: LocalizedError {
        case unreachable, timeout, invalidResponse, remote(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: String(localized: "暂时无法联系 iPhone。请保持手机在附近，必要时打开 Paseo。")
            case .timeout: String(localized: "等待 iPhone 响应超时，请稍后重试")
            case .invalidResponse: String(localized: "请更新 iPhone 和手表上的 Paseo 后重试")
            case .remote(let message): message
            }
        }
    }
}
