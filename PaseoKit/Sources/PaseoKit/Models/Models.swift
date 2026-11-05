// Typed views over daemon payloads. Built from JSONValue rather than Codable so unknown enum values and
// new fields never fail decoding (schemas only grow). See docs/protocol/02-messages.md §2, §4.7, §7.

import Foundation

public enum AgentStatus: String, Sendable {
    case initializing, idle, running, error, closed, unknown
}

/// The bucket shown as a status badge (vendor/paseo/packages/protocol/src/agent-state-bucket.ts).
public enum StatusBucket: String, Sendable, Comparable {
    case needsInput = "needs_input", failed, running, attention, done

    var priority: Int {
        switch self { case .needsInput: 0; case .failed: 1; case .running: 2; case .attention: 3; case .done: 4 }
    }
    public static func < (a: StatusBucket, b: StatusBucket) -> Bool { a.priority < b.priority }
}

public struct AgentMode: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let icon: String?

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        label = v["label"]?.stringValue ?? id
        description = v["description"]?.stringValue
        icon = v["icon"]?.stringValue
    }
}

public struct PermissionAction: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let behavior: String
    public let variant: String?

    public init(id: String, label: String, behavior: String, variant: String?) {
        self.id = id
        self.label = label
        self.behavior = behavior
        self.variant = variant
    }
}

public struct PermissionRequest: Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String?
    public let title: String?
    public let description: String?
    public let input: JSONValue?
    public let detail: ToolCallDetail?
    public let actions: [PermissionAction]
    public let raw: JSONValue

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        kind = v["kind"]?.stringValue ?? "tool"
        name = v["name"]?.stringValue
        title = v["title"]?.stringValue
        description = v["description"]?.stringValue
        input = v["input"]
        detail = v["detail"].map(ToolCallDetail.init)
        actions = (v["actions"]?.arrayValue ?? []).compactMap { a in
            guard let id = a["id"]?.stringValue else { return nil }
            return PermissionAction(id: id, label: a["label"]?.stringValue ?? id,
                                    behavior: a["behavior"]?.stringValue ?? "allow", variant: a["variant"]?.stringValue)
        }
        raw = v
    }

    /// Plan text for `kind == "plan"`.
    public var planText: String? { input?["plan"]?.stringValue ?? raw["metadata"]?["planText"]?.stringValue }
}

/// Provider feature control on an agent (toggle or select). `messages.ts` AgentFeature.
public struct AgentFeature: Sendable, Identifiable {
    public struct Option: Sendable, Hashable, Identifiable { public let id: String; public let label: String }
    public let id: String
    public let label: String
    public let isToggle: Bool
    public let boolValue: Bool
    public let selectedId: String?
    public let options: [Option]
    public let icon: String?

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        label = v["label"]?.stringValue ?? id
        isToggle = v["type"]?.stringValue == "toggle"
        boolValue = v["value"]?.boolValue ?? false
        selectedId = v["value"]?.stringValue
        options = (v["options"]?.arrayValue ?? []).compactMap { o in
            o["id"]?.stringValue.map { Option(id: $0, label: o["label"]?.stringValue ?? $0) }
        }
        icon = v["icon"]?.stringValue
    }
}

public struct Usage: Sendable {
    public let contextWindowMaxTokens: Double?
    public let contextWindowUsedTokens: Double?
    public let totalCostUsd: Double?
    public var inputTokens: Double? = nil
    public var cachedInputTokens: Double? = nil
    public var outputTokens: Double? = nil
}

public struct Agent: Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let cwd: String
    public let workspaceId: String?
    public let title: String?
    public let status: AgentStatus
    public let activeTurnStartedAt: Date?
    public let model: String?
    public let thinkingOptionId: String?
    public let effectiveThinkingOptionId: String?
    public let currentModeId: String?
    public let availableModes: [AgentMode]
    public let pendingPermissions: [PermissionRequest]
    public let features: [AgentFeature]
    /// Rewind modes this provider supports: "conversation", "files", "both".
    public let rewindModes: [String]
    public let createdAt: Date?
    public let updatedAt: Date?
    public let lastUserMessageAt: Date?
    public let lastError: String?
    public let labels: [String: String]
    public let requiresAttention: Bool
    public let attentionReason: String?
    public let archivedAt: Date?
    public let lastUsage: Usage?
    public let raw: JSONValue

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        provider = v["provider"]?.stringValue ?? "unknown"
        cwd = v["cwd"]?.stringValue ?? ""
        workspaceId = v["workspaceId"]?.stringValue
        title = v["title"]?.stringValue
        status = AgentStatus(rawValue: v["status"]?.stringValue ?? "") ?? .unknown
        activeTurnStartedAt = v["activeTurn"]?["startedAt"]?.dateValue
        model = v["model"]?.stringValue
        thinkingOptionId = v["thinkingOptionId"]?.stringValue
        effectiveThinkingOptionId = v["effectiveThinkingOptionId"]?.stringValue
        currentModeId = v["currentModeId"]?.stringValue
        availableModes = (v["availableModes"]?.arrayValue ?? []).compactMap(AgentMode.init)
        pendingPermissions = (v["pendingPermissions"]?.arrayValue ?? []).compactMap(PermissionRequest.init)
        features = (v["features"]?.arrayValue ?? []).compactMap(AgentFeature.init)
        let caps = v["capabilities"]
        rewindModes = [("conversation", "supportsRewindConversation"), ("files", "supportsRewindFiles"), ("both", "supportsRewindBoth")]
            .filter { caps?[$0.1]?.boolValue == true }.map(\.0)
        createdAt = v["createdAt"]?.dateValue
        updatedAt = v["updatedAt"]?.dateValue
        lastUserMessageAt = v["lastUserMessageAt"]?.dateValue
        lastError = v["lastError"]?.stringValue
        labels = (v["labels"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        requiresAttention = v["requiresAttention"]?.boolValue ?? false
        attentionReason = v["attentionReason"]?.stringValue
        archivedAt = v["archivedAt"]?.dateValue
        lastUsage = v["lastUsage"].map {
            Usage(contextWindowMaxTokens: $0["contextWindowMaxTokens"]?.doubleValue,
                  contextWindowUsedTokens: $0["contextWindowUsedTokens"]?.doubleValue,
                  totalCostUsd: $0["totalCostUsd"]?.doubleValue,
                  inputTokens: $0["inputTokens"]?.doubleValue,
                  cachedInputTokens: $0["cachedInputTokens"]?.doubleValue,
                  outputTokens: $0["outputTokens"]?.doubleValue)
        }
        raw = v
    }

    public var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? String(localized: "新会话", bundle: .module) }

    /// The provider's own CLI command to resume this session in a terminal (official "Copy resume command").
    public var resumeCommand: String? {
        guard let sid = raw["runtimeInfo"]?["sessionId"]?.stringValue ?? raw["persistence"]?["sessionId"]?.stringValue else { return nil }
        let templates = ["codex": "codex resume {id}", "claude": "claude --resume {id}", "hermes": "hermes --resume {id}",
                         "pi": "pi --session {id}", "omp": "omp --session {id}", "opencode": "opencode --session {id}"]
        return templates[provider]?.replacingOccurrences(of: "{id}", with: sid)
    }
    public var parentAgentId: String? { labels["paseo.parent-agent-id"] }
    /// Host of the parent agent; nil means the same host.
    public var parentServerId: String? { labels["paseo.parent-server-id"] }
    public var isSubagent: Bool { parentAgentId != nil }
    public var currentMode: AgentMode? { availableModes.first { $0.id == currentModeId } }

    public var bucket: StatusBucket {
        if !pendingPermissions.isEmpty || attentionReason == "permission" { return .needsInput }
        if status == .error || attentionReason == "error" { return .failed }
        if status == .running { return .running }
        if requiresAttention { return .attention }
        return .done
    }
}

public struct Workspace: Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let isGit: Bool
    public let labels: [String]
    public let projectId: String
    /// Cross-machine project identity (official view key); nil on old daemons.
    public let projectKey: String?
    /// Fingerprint of the project's effective icon; refetch the icon when it changes.
    public let projectIconRevision: String?
    public let projectDisplayName: String
    public let projectRootPath: String
    public let name: String
    public let directory: String
    public let kind: String
    public let status: StatusBucket
    public let activityAt: Date?
    public let pinnedAt: Date?
    public let currentBranch: String?
    public let additions: Int?
    public let deletions: Int?
    public let pullRequest: PullRequestInfo?
    public let remoteUrl: String?
    public let raw: JSONValue

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        title = v["title"]?.stringValue
        labels = (v["labels"]?.arrayValue ?? []).compactMap(\.stringValue)
        isGit = v["projectKind"]?.stringValue == "git" || v["gitRuntime"] != nil
        projectId = v["projectId"]?.stringValue ?? ""
        projectKey = v["projectKey"]?.stringValue
        projectIconRevision = v["projectIconRevision"]?.stringValue ?? v["projectCustomIconRevision"]?.stringValue
        projectDisplayName = v["projectDisplayName"]?.stringValue ?? ""
        projectRootPath = v["projectRootPath"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        directory = v["workspaceDirectory"]?.stringValue ?? projectRootPath
        kind = v["workspaceKind"]?.stringValue ?? "directory"
        status = StatusBucket(rawValue: v["status"]?.stringValue ?? "") ?? .done
        activityAt = v["activityAt"]?.dateValue
        pinnedAt = v["pinnedAt"]?.dateValue
        currentBranch = v["gitRuntime"]?["currentBranch"]?.stringValue
        additions = v["diffStat"]?["additions"]?.doubleValue.map(Int.init)
        deletions = v["diffStat"]?["deletions"]?.doubleValue.map(Int.init)
        pullRequest = PullRequestInfo(v["githubRuntime"]?["pullRequest"])
        remoteUrl = v["gitRuntime"]?["remoteUrl"]?.stringValue
        raw = v
    }
}

extension Workspace {
    /// Web page of the current branch on the forge, from `git@host:o/r.git` or `https://host/o/r.git`.
    public var branchWebURL: URL? {
        guard var r = remoteUrl, let branch = currentBranch else { return nil }
        if r.hasSuffix(".git") { r.removeLast(4) }
        if r.hasPrefix("git@"), let colon = r.firstIndex(of: ":") {
            r = "https://" + r[r.index(r.startIndex, offsetBy: 4)..<colon] + "/" + r[r.index(after: colon)...]
        } else if r.hasPrefix("ssh://") {
            r = "https://" + r.dropFirst(6).split(separator: "@").last.map(String.init)!.replacingOccurrences(of: ":\\d+/", with: "/", options: .regularExpression)
        }
        guard r.hasPrefix("http") else { return nil }
        let path = r.contains("gitlab") ? "/-/tree/" : "/tree/"
        return URL(string: r + path + (branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch))
    }

    /// Web page of a file (relative to the workspace) on the current branch.
    public func fileWebURL(_ relativePath: String) -> URL? {
        guard let tree = branchWebURL?.absoluteString else { return nil }
        let blob = tree.replacingOccurrences(of: "/-/tree/", with: "/-/blob/").replacingOccurrences(of: "/tree/", with: "/blob/")
        return URL(string: blob + "/" + (relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath))
    }
}

public struct Project: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let kind: String
    /// Stable key for the identity colour (official createProjectViewKey).
    public let projectKey: String?
    /// Fingerprint of the effective icon; changes when a custom icon is set or cleared.
    public let iconRevision: String?

    public init?(_ v: JSONValue) {
        guard let id = v["projectId"]?.stringValue else { return nil }
        self.id = id
        displayName = v["projectDisplayName"]?.stringValue ?? id
        rootPath = v["projectRootPath"]?.stringValue ?? ""
        kind = v["projectKind"]?.stringValue ?? "directory"
        projectKey = v["projectKey"]?.stringValue
        iconRevision = v["projectIconRevision"]?.stringValue ?? v["projectCustomIconRevision"]?.stringValue
    }
}

// MARK: - Timeline

public enum ToolCallDetail: Sendable {
    case shell(command: String, cwd: String?, output: String?, exitCode: Int?)
    case read(filePath: String, content: String?)
    case edit(filePath: String, oldString: String?, newString: String?, unifiedDiff: String?)
    case write(filePath: String, content: String?)
    case search(query: String, content: String?, filePaths: [String])
    case fetch(url: String, result: String?)
    case subAgent(description: String?, log: String?)
    case plainText(label: String?, text: String?, icon: String?)
    case plan(text: String)
    case unknown(JSONValue)

    public init(_ v: JSONValue) {
        let s = { (k: String) in v[k]?.stringValue }
        switch s("type") {
        case "shell": self = .shell(command: s("command") ?? "", cwd: s("cwd"), output: s("output"),
                                    exitCode: v["exitCode"]?.doubleValue.map(Int.init))
        case "read": self = .read(filePath: s("filePath") ?? "", content: s("content"))
        case "edit": self = .edit(filePath: s("filePath") ?? "", oldString: s("oldString"), newString: s("newString"),
                                  unifiedDiff: s("unifiedDiff"))
        case "write": self = .write(filePath: s("filePath") ?? "", content: s("content"))
        case "search": self = .search(query: s("query") ?? "", content: s("content"),
                                      filePaths: (v["filePaths"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "fetch": self = .fetch(url: s("url") ?? "", result: s("result"))
        case "sub_agent": self = .subAgent(description: s("description"), log: s("log"))
        case "plain_text": self = .plainText(label: s("label"), text: s("text"), icon: s("icon"))
        case "plan": self = .plan(text: s("text") ?? "")
        default: self = .unknown(v)
        }
    }
}

public struct TodoItem: Sendable, Hashable {
    public let text: String
    public let status: String
    public var completed: Bool { status == "completed" }
}

public enum TimelineItem: Sendable {
    case userMessage(text: String, messageId: String?)
    case assistantMessage(text: String, messageId: String?)
    case reasoning(text: String)
    case toolCall(callId: String, name: String, status: String, detail: ToolCallDetail, error: JSONValue?, agentMessage: JSONValue?)
    case todo([TodoItem])
    case error(message: String)
    case notification(level: String, message: String)
    case compaction(status: String, trigger: String?, preTokens: Int?)
    /// Rows appended by server plugins (turn-speed, next-input…); `data` is plugin-defined.
    case plugin(id: String, pluginId: String, kind: String, version: Int, data: JSONValue)
    case unknown(type: String)

    public init(_ v: JSONValue) {
        let s = { (k: String) in v[k]?.stringValue }
        switch s("type") {
        case "user_message": self = .userMessage(text: s("text") ?? "", messageId: s("messageId") ?? s("clientMessageId"))
        case "assistant_message": self = .assistantMessage(text: s("text") ?? "", messageId: s("messageId"))
        case "reasoning": self = .reasoning(text: s("text") ?? "")
        case "tool_call":
            let error = v["error"].flatMap { $0 == .null ? nil : $0 }
            self = .toolCall(callId: s("callId") ?? UUID().uuidString, name: s("name") ?? "tool", status: s("status") ?? "running",
                             detail: ToolCallDetail(v["detail"] ?? .null), error: error, agentMessage: v["agentMessage"])
        case "todo":
            self = .todo((v["items"]?.arrayValue ?? []).map {
                TodoItem(text: $0["text"]?.stringValue ?? "",
                         status: $0["status"]?.stringValue ?? ($0["completed"]?.boolValue == true ? "completed" : "pending"))
            })
        case "error": self = .error(message: s("message") ?? "")
        case "notification": self = .notification(level: s("level") ?? "info", message: s("message") ?? "")
        case "compaction": self = .compaction(status: s("status") ?? "completed", trigger: s("trigger"), preTokens: v["preTokens"]?.doubleValue.map(Int.init))
        case "plugin": self = .plugin(id: s("id") ?? UUID().uuidString, pluginId: s("pluginId") ?? "", kind: s("kind") ?? "",
                                      version: Int(v["version"]?.doubleValue ?? 1), data: v["data"] ?? .null)
        default: self = .unknown(type: s("type") ?? "?")
        }
    }
}

extension JSONValue {
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    public var dateValue: Date? {
        guard let s = stringValue else { return nil }
        return Self.isoFractional.date(from: s) ?? Self.iso.date(from: s)
    }
}
