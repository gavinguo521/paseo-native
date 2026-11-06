import Foundation

public struct WatchSessionRef: Codable, Hashable, Sendable, Identifiable {
    public var hostID: String
    public var agentID: String
    public var id: String { hostID + "/" + agentID }
    public init(hostID: String, agentID: String) { self.hostID = hostID; self.agentID = agentID }
}

public struct WatchHost: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum WatchSessionStatus: String, Codable, Sendable {
    case waiting, failed, running, attention, done
    public var priority: Int {
        switch self { case .waiting: 0; case .failed: 1; case .running: 2; case .attention: 3; case .done: 4 }
    }
}

public struct WatchSessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var ref: WatchSessionRef
    public var title: String
    public var hostName: String
    public var status: WatchSessionStatus
    public var updatedAt: Date?
    public var startedAt: Date?
    public var id: String { ref.id }
    public init(ref: WatchSessionRef, title: String, hostName: String, status: WatchSessionStatus, updatedAt: Date?, startedAt: Date?) {
        self.ref = ref; self.title = title; self.hostName = hostName; self.status = status
        self.updatedAt = updatedAt; self.startedAt = startedAt
    }
}

public struct WatchSessionPage: Codable, Equatable, Sendable {
    public var hostID: String
    public var refreshedAt: Date
    public var sessions: [WatchSessionSummary]
    public var hasMore: Bool
    public init(hostID: String, refreshedAt: Date = Date(), sessions: [WatchSessionSummary], hasMore: Bool = false) {
        self.hostID = hostID; self.refreshedAt = refreshedAt; self.sessions = sessions; self.hasMore = hasMore
    }
}

public struct WatchOverview: Codable, Equatable, Sendable {
    public var hosts: [WatchHost]
    public var pages: [WatchSessionPage]
    public init(hosts: [WatchHost] = [], pages: [WatchSessionPage] = []) { self.hosts = hosts; self.pages = pages }

    /// Background context can arrive after a newer foreground reply. Never roll a host back.
    public mutating func merge(_ incoming: WatchOverview) {
        hosts = incoming.hosts
        let ids = Set(hosts.map(\.id))
        pages.removeAll { !ids.contains($0.hostID) }
        for page in incoming.pages where ids.contains(page.hostID) { merge(page) }
    }

    public mutating func merge(_ page: WatchSessionPage) {
        if let index = pages.firstIndex(where: { $0.hostID == page.hostID }) {
            guard pages[index].refreshedAt <= page.refreshedAt else { return }
            pages[index] = page
        } else { pages.append(page) }
    }

    public func sessions(hostID: String?) -> [WatchSessionSummary] {
        pages.filter { hostID == nil || $0.hostID == hostID }.flatMap(\.sessions).sorted {
            if $0.status.priority != $1.status.priority { return $0.status.priority < $1.status.priority }
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.id < $1.id
        }
    }
}

public struct WatchMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: String
    public var text: String
    public var truncated: Bool
    public var timestamp: Date?
    public init(id: String, role: String, text: String, truncated: Bool = false, timestamp: Date? = nil) {
        self.id = id; self.role = role; self.text = text; self.truncated = truncated
        self.timestamp = timestamp
    }
}

public struct WatchPermissionAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var behavior: String
    public init(id: String, label: String, behavior: String) { self.id = id; self.label = label; self.behavior = behavior }
}

public struct WatchPermission: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// Changes to displayed content invalidate actions from an older screen.
    public var revision: String
    public var actions: [WatchPermissionAction]
    public var needsPhone: Bool
    public var kind: String?
    public var questionForm: WatchQuestionForm?
    public init(id: String, title: String, detail: String, revision: String, actions: [WatchPermissionAction], needsPhone: Bool = false,
                kind: String? = nil, questionForm: WatchQuestionForm? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.revision = revision
        self.actions = actions; self.needsPhone = needsPhone
        self.kind = kind; self.questionForm = questionForm
    }
    public func action(id: String, expectedRevision: String) -> WatchPermissionAction? {
        guard !needsPhone, revision == expectedRevision else { return nil }
        return actions.first { $0.id == id }
    }
}

public struct WatchSessionDetail: Codable, Equatable, Sendable {
    public var session: WatchSessionSummary
    public var messages: [WatchMessage]
    public var permissions: [WatchPermission]
    public var refreshedAt: Date
    public init(session: WatchSessionSummary, messages: [WatchMessage], permissions: [WatchPermission], refreshedAt: Date = Date()) {
        self.session = session; self.messages = messages; self.permissions = permissions; self.refreshedAt = refreshedAt
    }
}

public struct WatchSchedule: Codable, Equatable, Sendable, Identifiable {
    public var hostID: String
    public var scheduleID: String
    public var hostName: String
    public var title: String
    public var status: String
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var prompt: String
    public var runs: [WatchScheduleRun]
    public var id: String { hostID + "/" + scheduleID }
    public init(hostID: String, scheduleID: String, hostName: String, title: String, status: String,
                nextRunAt: Date?, lastRunAt: Date?, prompt: String = "", runs: [WatchScheduleRun] = []) {
        self.hostID = hostID; self.scheduleID = scheduleID; self.hostName = hostName; self.title = title; self.status = status
        self.nextRunAt = nextRunAt; self.lastRunAt = lastRunAt; self.prompt = prompt; self.runs = runs
    }
}

public struct WatchScheduleRun: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var startedAt: Date?
    public var output: String
    public var agentID: String?
    public init(id: String, status: String, startedAt: Date?, output: String, agentID: String?) {
        self.id = id; self.status = status; self.startedAt = startedAt; self.output = output; self.agentID = agentID
    }
}

public struct WatchSchedulePage: Codable, Equatable, Sendable {
    public var hostID: String
    public var refreshedAt: Date
    public var schedules: [WatchSchedule]
    public var hasMore: Bool
    public init(hostID: String, refreshedAt: Date = Date(), schedules: [WatchSchedule], hasMore: Bool = false) {
        self.hostID = hostID; self.refreshedAt = refreshedAt; self.schedules = schedules; self.hasMore = hasMore
    }
}

public enum WatchCommand: Codable, Equatable, Sendable {
    case overview
    case sessions(hostID: String)
    case session(WatchSessionRef)
    case schedules(hostID: String)
    case schedule(hostID: String, scheduleID: String)
    case reply(WatchSessionRef, text: String)
    case permission(WatchSessionRef, requestID: String, revision: String, actionID: String)
    case actionStatus(UUID)

    public var isAction: Bool {
        switch self { case .reply, .permission: true; default: false }
    }
}

public struct WatchRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var command: WatchCommand
    public var questionAnswers: [String: WatchQuestionAnswer]?
    public init(id: UUID = UUID(), createdAt: Date = Date(), command: WatchCommand,
                questionAnswers: [String: WatchQuestionAnswer]? = nil) {
        self.id = id; self.createdAt = createdAt; self.command = command
        self.questionAnswers = questionAnswers
    }
    public var messageID: String { "watch_" + id.uuidString.lowercased() }
}

public struct WatchActionResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case confirmed, notSent, uncertain }
    public var state: State
    public var message: String
    public init(_ state: State, _ message: String) { self.state = state; self.message = message }
}

public enum WatchPayload: Codable, Equatable, Sendable {
    case overview(WatchOverview)
    case sessions(WatchSessionPage)
    case session(WatchSessionDetail)
    case schedules(WatchSchedulePage)
    case schedule(WatchSchedule)
    case action(WatchActionResult)
    case failure(String)
}

public struct WatchEnvelope: Codable, Sendable {
    public static let version = 1
    public static let key = "paseo.watch.v1"
    /// Below WatchConnectivity's message limit, including its dictionary overhead.
    public static let maximumBytes = 60_000
    public var version = Self.version
    public var request: WatchRequest?
    public var requestID: UUID?
    public var payload: WatchPayload?
    public init(request: WatchRequest) { self.request = request }
    public init(requestID: UUID? = nil, payload: WatchPayload) { self.requestID = requestID; self.payload = payload }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw WatchWireError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WatchWireError.tooLarge }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        guard envelope.version == version else { throw WatchWireError.versionMismatch }
        return envelope
    }
}

public enum WatchWireError: Error { case tooLarge, versionMismatch }
