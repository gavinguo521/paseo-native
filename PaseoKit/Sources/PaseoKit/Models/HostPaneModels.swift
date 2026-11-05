// Files, git checkout, terminals and workspace scripts. See docs/protocol/03-files-git-terminal.md.

import Foundation

public struct FileEntry: Sendable, Identifiable, Hashable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int
    public let modifiedAt: Date?
    public var id: String { path }

    init?(_ v: JSONValue) {
        guard let name = v["name"]?.stringValue, let path = v["path"]?.stringValue else { return nil }
        self.name = name
        self.path = path
        isDirectory = v["kind"]?.stringValue == "directory"
        size = Int(v["size"]?.doubleValue ?? 0)
        modifiedAt = v["modifiedAt"]?.dateValue
    }
}

public struct FileContent: Sendable {
    public enum Kind: Sendable { case text, image, binary }
    public let path: String
    public let kind: Kind
    public let mimeType: String
    public let data: Data
    public let size: Int
    public let revision: String?

    public var text: String? { kind == .text ? String(data: data, encoding: .utf8) : nil }
}

public struct CheckoutStatus: Sendable {
    public let isGit: Bool
    public let currentBranch: String?
    public let isDirty: Bool
    public let baseRef: String?
    public let ahead: Int
    public let behind: Int
    public let aheadOfOrigin: Int
    public let behindOfOrigin: Int
    public let hasRemote: Bool
    public let isPaseoOwnedWorktree: Bool

    init(_ v: JSONValue) {
        isGit = v["isGit"]?.boolValue ?? false
        currentBranch = v["currentBranch"]?.stringValue
        isDirty = v["isDirty"]?.boolValue ?? false
        baseRef = v["baseRef"]?.stringValue
        ahead = Int(v["aheadBehind"]?["ahead"]?.doubleValue ?? 0)
        behind = Int(v["aheadBehind"]?["behind"]?.doubleValue ?? 0)
        aheadOfOrigin = Int(v["aheadOfOrigin"]?.doubleValue ?? 0)
        behindOfOrigin = Int(v["behindOfOrigin"]?.doubleValue ?? 0)
        hasRemote = v["hasRemote"]?.boolValue ?? false
        isPaseoOwnedWorktree = v["isPaseoOwnedWorktree"]?.boolValue ?? false
    }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: String, Sendable { case header, context, add, remove }
    public let kind: Kind
    public let content: String
    public let oldNumber: Int?
    public let newNumber: Int?
}

/// A pull/merge request on the forge (GitHub, GitLab…). From the workspace's `githubRuntime.pullRequest`
/// or `checkout_pr_status_response.status`; both share these fields.
public struct PullRequestInfo: Sendable, Hashable {
    public struct Check: Sendable, Hashable, Identifiable {
        public let name: String
        /// success, failure, pending, skipped, cancelled.
        public let status: String
        public let url: String?
        public let workflow: String?
        public let duration: String?
        public let checkRunId: Int?
        public let workflowRunId: Int?
        public var id: String { (workflow ?? "") + "/" + name }
    }

    public let number: Int?
    public let url: String
    public let title: String
    /// OPEN, CLOSED, MERGED (forge casing varies).
    public let state: String
    public let baseRefName: String
    public let headRefName: String
    public let isMerged: Bool
    public let isDraft: Bool
    /// MERGEABLE, CONFLICTING, UNKNOWN.
    public let mergeable: String
    public let checks: [Check]
    /// none, pending, success, failure.
    public let checksStatus: String?
    /// approved, changes_requested, pending.
    public let reviewDecision: String?
    public let repoOwner: String?
    public let repoName: String?

    public var isOpen: Bool { !isMerged && state.lowercased() == "open" }

    public init?(_ v: JSONValue?) {
        guard let v, let url = v["url"]?.stringValue else { return nil }
        number = v["number"]?.doubleValue.map(Int.init)
        self.url = url
        title = v["title"]?.stringValue ?? ""
        state = v["state"]?.stringValue ?? ""
        baseRefName = v["baseRefName"]?.stringValue ?? ""
        headRefName = v["headRefName"]?.stringValue ?? ""
        isMerged = v["isMerged"]?.boolValue ?? false
        isDraft = v["isDraft"]?.boolValue ?? false
        mergeable = v["mergeable"]?.stringValue ?? "UNKNOWN"
        checks = (v["checks"]?.arrayValue ?? []).compactMap { c in
            guard let name = c["name"]?.stringValue else { return nil }
            return Check(name: name, status: c["status"]?.stringValue?.lowercased() ?? "pending", url: c["url"]?.stringValue,
                         workflow: c["workflow"]?.stringValue, duration: c["duration"]?.stringValue,
                         checkRunId: c["checkRunId"]?.doubleValue.map(Int.init), workflowRunId: c["workflowRunId"]?.doubleValue.map(Int.init))
        }
        checksStatus = v["checksStatus"]?.stringValue?.lowercased()
        reviewDecision = v["reviewDecision"]?.stringValue?.lowercased()
        repoOwner = v["repoOwner"]?.stringValue
        repoName = v["repoName"]?.stringValue
    }
}

/// `checkout_pr_status_response`: the PR (if any) and whether forge features can be used.
public struct PrStatus: Sendable {
    public let pullRequest: PullRequestInfo?
    /// authenticated, unauthenticated, cli_missing, no_remote, error.
    public let authState: String
    public let forge: String

    init(_ p: JSONValue) {
        pullRequest = PullRequestInfo(p["status"])
        authState = p["authState"]?.stringValue ?? (p["githubFeaturesEnabled"]?.boolValue == true ? "authenticated" : "error")
        forge = p["forge"]?.stringValue ?? "github"
    }

    /// Short reason forge actions are unavailable, nil when they work.
    public var unavailableReason: String? {
        switch authState {
        case "authenticated": nil
        case "unauthenticated":
            forge == "github" ? "GitHub 命令行未登录（在主机上运行 gh auth login）"
                : forge == "gitlab" ? "GitLab 命令行未登录（在主机上运行 glab auth login）"
                : "\(forgeName) 未登录，PR 功能不可用"
        case "cli_missing":
            forge == "github" ? "主机上没有安装 gh 命令行工具" : forge == "gitlab" ? "主机上没有安装 glab 命令行工具" : "主机上缺少 \(forgeName) 的命令行工具"
        case "no_remote": "没有找到 \(forgeName) 上的远程仓库，PR 功能不可用"
        default: "无法连接 \(forgeName)"
        }
    }

    public var forgeName: String { forge == "gitlab" ? "GitLab" : forge == "github" ? "GitHub" : forge }
}

/// A review or comment on a PR (`pull_request_timeline_response.items`).
public struct PRTimelineItem: Sendable, Identifiable, Hashable {
    public let id: String
    /// review or comment.
    public let kind: String
    public let author: String
    public let body: String
    public let createdAt: Date?
    public let url: String
    /// approved, changes_requested, commented (reviews).
    public let reviewState: String?
    public let path: String?
    public let line: Int?
    public let isResolved: Bool
    public let isOutdated: Bool

    init(_ v: JSONValue, index: Int) {
        id = v["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "item-\(index)"
        kind = v["kind"]?.stringValue ?? "comment"
        author = v["author"]?.stringValue ?? "unknown"
        body = v["body"]?.stringValue ?? ""
        createdAt = v["createdAt"]?.doubleValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        url = v["url"]?.stringValue ?? ""
        reviewState = v["reviewState"]?.stringValue
        path = v["location"]?["path"]?.stringValue
        line = v["location"]?["line"]?.doubleValue.map(Int.init)
        isResolved = v["location"]?["isResolved"]?.boolValue ?? v["threadIsResolved"]?.boolValue ?? false
        isOutdated = v["location"]?["isOutdated"]?.boolValue ?? false
    }
}

/// CI check details for one failing check.
public struct CheckDetails: Sendable {
    public struct Annotation: Sendable, Hashable { public let path: String?; public let line: Int?; public let level: String?; public let message: String }
    public let name: String
    public let conclusion: String?
    public let title: String?
    public let summary: String?
    public let text: String?
    public let annotations: [Annotation]
    public let failedJobs: [String]
    public let url: String?

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        conclusion = v["conclusion"]?.stringValue
        title = v["output"]?["title"]?.stringValue
        summary = v["output"]?["summary"]?.stringValue
        text = v["output"]?["text"]?.stringValue
        annotations = (v["annotations"]?.arrayValue ?? []).compactMap { a in
            guard let m = a["message"]?.stringValue else { return nil }
            return Annotation(path: a["path"]?.stringValue, line: a["startLine"]?.doubleValue.map(Int.init), level: a["annotationLevel"]?.stringValue, message: m)
        }
        failedJobs = (v["failedJobs"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        url = v["detailsUrl"]?.stringValue ?? v["url"]?.stringValue
    }

    /// Plain text for handing the failure to an agent.
    public var asPrompt: String {
        var out = "CI 检查「\(name)」失败" + (conclusion.map { "（\($0)）" } ?? "") + "。"
        if let title { out += "\n" + title }
        if let summary, !summary.isEmpty { out += "\n\n" + String(summary.prefix(4000)) }
        if !failedJobs.isEmpty { out += "\n\n失败的 job：" + failedJobs.joined(separator: "、") }
        for a in annotations.prefix(30) {
            out += "\n- " + [a.path.map { $0 + (a.line.map { ":\($0)" } ?? "") }, a.message].compactMap { $0 }.joined(separator: " ")
        }
        if let url { out += "\n\n详情：" + url }
        return out
    }
}

public struct CommitInfo: Sendable, Identifiable, Hashable {
    public struct File: Sendable, Hashable, Identifiable {
        public let path: String
        public let additions: Int
        public let deletions: Int
        public let status: String?
        public var id: String { path }
        public var letter: String {
            switch status { case "added": "A"; case "deleted": "D"; case "renamed": "R"; default: "M" }
        }
    }

    public let sha: String
    public let shortSha: String
    public let subject: String
    public let authorName: String
    public let authorDate: Date?
    /// false = local only, not pushed yet.
    public let isOnRemote: Bool
    public let isOnBase: Bool
    public let files: [File]
    public var id: String { sha }

    init?(_ v: JSONValue) {
        guard let sha = v["sha"]?.stringValue else { return nil }
        self.sha = sha
        shortSha = v["shortSha"]?.stringValue ?? String(sha.prefix(7))
        subject = v["subject"]?.stringValue ?? ""
        authorName = v["authorName"]?.stringValue ?? ""
        authorDate = v["authorDate"]?.dateValue
        isOnRemote = v["isOnRemote"]?.boolValue ?? false
        isOnBase = v["isOnBase"]?.boolValue ?? false
        files = (v["files"]?.arrayValue ?? []).compactMap { f in
            guard let path = f["path"]?.stringValue else { return nil }
            return File(path: path, additions: Int(f["additions"]?.doubleValue ?? 0), deletions: Int(f["deletions"]?.doubleValue ?? 0),
                        status: f["status"]?.stringValue)
        }
    }
}

public struct DiffFile: Sendable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let isNew: Bool
    public let isDeleted: Bool
    public let additions: Int
    public let deletions: Int
    /// "ok", "binary" or "too_large".
    public let status: String
    public let lines: [DiffLine]
    public var id: String { path }

    /// Git-style letter derived from flags (the protocol has no porcelain codes).
    public var letter: String { isNew ? "A" : isDeleted ? "D" : oldPath != nil ? "R" : "M" }

    init?(_ v: JSONValue) {
        guard let path = v["path"]?.stringValue else { return nil }
        self.path = path
        oldPath = v["oldPath"]?.stringValue
        isNew = v["isNew"]?.boolValue ?? false
        isDeleted = v["isDeleted"]?.boolValue ?? false
        additions = Int(v["additions"]?.doubleValue ?? 0)
        deletions = Int(v["deletions"]?.doubleValue ?? 0)
        status = v["status"]?.stringValue ?? "ok"
        var out: [DiffLine] = []
        for h in v["hunks"]?.arrayValue ?? [] {
            var old = Int(h["oldStart"]?.doubleValue ?? 1), new = Int(h["newStart"]?.doubleValue ?? 1)
            for l in h["lines"]?.arrayValue ?? [] {
                let kind = DiffLine.Kind(rawValue: l["type"]?.stringValue ?? "") ?? .context
                let content = l["content"]?.stringValue ?? ""
                switch kind {
                case .header: out.append(DiffLine(kind: kind, content: content, oldNumber: nil, newNumber: nil))
                case .context: out.append(DiffLine(kind: kind, content: content, oldNumber: old, newNumber: new)); old += 1; new += 1
                case .remove: out.append(DiffLine(kind: kind, content: content, oldNumber: old, newNumber: nil)); old += 1
                case .add: out.append(DiffLine(kind: kind, content: content, oldNumber: nil, newNumber: new)); new += 1
                }
            }
        }
        lines = out
    }
}

public struct CheckoutDiff: Sendable {
    public let files: [DiffFile]
    public let tooLarge: Bool
    public let error: String?

    init(_ p: JSONValue) {
        files = (p["files"]?.arrayValue ?? []).compactMap(DiffFile.init)
        tooLarge = p["diffTooLarge"]?.boolValue ?? false
        error = p["error"]?["message"]?.stringValue ?? p["error"]?.stringValue
    }
}

public struct TerminalInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let title: String?
    /// "idle", "working" or "attention".
    public let activity: String?

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        name = v["name"]?.stringValue ?? "终端"
        title = v["title"]?.stringValue
        activity = v["activity"]?["state"]?.stringValue
    }
}

public struct WorkspaceScript: Sendable, Identifiable, Hashable {
    public let name: String
    public let type: String
    public let lifecycle: String
    public let health: String?
    public let exitCode: Int?
    public let terminalId: String?
    public let port: Int?
    public let hostname: String?
    public let localProxyUrl: String?
    public let publicProxyUrl: String?
    public let proxyUrl: String?
    public var id: String { name }
    public var isRunning: Bool { lifecycle == "running" }
    /// Every address the service is reachable at, most shareable first.
    public var urls: [(label: String, url: String)] {
        var out: [(String, String)] = []
        if let u = publicProxyUrl { out.append(("公网代理", u)) }
        if let u = proxyUrl, u != publicProxyUrl { out.append(("代理", u)) }
        if let u = localProxyUrl, u != proxyUrl { out.append(("本地代理", u)) }
        if let port { out.append(("直连", "http://\(hostname ?? "localhost"):\(port)")) }
        return out
    }

    init?(_ v: JSONValue) {
        guard let name = v["scriptName"]?.stringValue else { return nil }
        self.name = name
        type = v["type"]?.stringValue ?? "script"
        lifecycle = v["lifecycle"]?.stringValue ?? "stopped"
        health = v["health"]?.stringValue
        exitCode = v["exitCode"]?.doubleValue.map(Int.init)
        terminalId = v["terminalId"]?.stringValue
        port = v["port"]?.doubleValue.map(Int.init)
        hostname = v["hostname"]?.stringValue
        localProxyUrl = v["localProxyUrl"]?.stringValue
        publicProxyUrl = v["publicProxyUrl"]?.stringValue
        proxyUrl = v["proxyUrl"]?.stringValue
    }
}

public enum TerminalEvent: Sendable {
    /// Raw PTY output.
    case output(Data)
    /// Full redraw: reset the emulator first, then feed (and drop its replies while feeding).
    case restore(Data)
    case exited(error: String?)
}

public struct WorkspaceLabel: Sendable, Identifiable, Hashable {
    public static let colors = ["violet", "sky", "emerald", "orange", "pink", "indigo", "teal", "red", "amber", "blue"]
    public let name: String
    public let color: String
    public var id: String { name.lowercased() }

    init?(_ v: JSONValue) {
        guard let name = v["name"]?.stringValue else { return nil }
        self.name = name
        color = v["color"]?.stringValue ?? "blue"
    }
}

public struct ProviderSubagent: Sendable, Identifiable, Hashable {
    public let id: String
    public let parentAgentId: String
    /// Set when another provider subagent spawned this one; top-level rows have nil.
    public let parentSubagentId: String?
    /// The subagent type ("general-purpose", "Explore", "fork"); repeats across a fan-out.
    public let title: String?
    /// The task it was given; names the row when present.
    public let description: String?
    /// Provider-owned context such as "general-purpose · Opus 5.5 · Medium · 250.4k tokens".
    public let subtitle: String?
    /// "running", "completed", "failed" or "canceled".
    public let status: String
    public let createdAt: Date?
    public let updatedAt: Date?

    public var isFinished: Bool { status != "running" }
    /// Official presentation: the task names the row, the provider context sits below it.
    public var label: String { description ?? title ?? "子代理" }
    public var detail: String? { subtitle ?? (description != nil ? title : nil) }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, let parent = v["parentAgentId"]?.stringValue else { return nil }
        func text(_ key: String) -> String? {
            guard let t = v[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  t.lowercased() != "new agent" else { return nil }
            return t
        }
        self.id = id
        parentAgentId = parent
        parentSubagentId = v["parentSubagentId"]?.stringValue
        title = text("title")
        description = text("description")
        subtitle = text("subtitle")
        status = v["status"]?.stringValue ?? "running"
        createdAt = v["createdAt"]?.dateValue
        updatedAt = v["updatedAt"]?.dateValue
    }
}

public struct UploadedFile: Sendable, Identifiable, Hashable {
    public let id: String
    public let fileName: String
    public let size: Int
    /// The `uploaded_file` attachment, sent as-is in `attachments`.
    public let attachment: JSONValue

    public init(id: String, fileName: String, size: Int, attachment: JSONValue) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.attachment = attachment
    }
}

/// An issue or PR/MR found with `forge.search`, attachable to a message.
public struct ForgeItem: Sendable, Identifiable, Hashable {
    public let kind: String
    public let forge: String
    public let number: Int
    public let title: String
    public let url: String
    public let state: String
    public let body: String?
    public let baseRefName: String?
    public let headRefName: String?
    public let projectPath: String?
    public var id: String { kind + "#" + String(number) }
    public var isChangeRequest: Bool { kind == "change_request" || kind == "pr" }

    init?(_ v: JSONValue) {
        guard let n = v["number"]?.doubleValue, let title = v["title"]?.stringValue, let url = v["url"]?.stringValue else { return nil }
        kind = v["kind"]?.stringValue ?? "issue"
        forge = v["forge"]?.stringValue ?? "github"
        number = Int(n)
        self.title = title
        self.url = url
        state = v["state"]?.stringValue ?? ""
        body = v["body"]?.stringValue
        baseRefName = v["baseRefName"]?.stringValue
        headRefName = v["headRefName"]?.stringValue
        projectPath = v["projectPath"]?.stringValue
    }

    /// Forge-neutral attachment (`forge_issue` / `forge_change_request`).
    public var attachment: JSONValue {
        var a: [String: JSONValue] = ["forge": .string(forge), "number": .number(Double(number)), "title": .string(title), "url": .string(url)]
        if let body { a["body"] = .string(String(body.prefix(20000))) }
        if let projectPath { a["projectPath"] = .string(projectPath) }
        if isChangeRequest {
            a["type"] = "forge_change_request"; a["mimeType"] = "application/paseo-forge-change-request"
            if let b = baseRefName { a["baseRefName"] = .string(b) }
            if let h = headRefName { a["headRefName"] = .string(h) }
        } else {
            a["type"] = "forge_issue"; a["mimeType"] = "application/paseo-forge-issue"
        }
        return .object(a)
    }
}

/// `workspace_setup_progress` / setup snapshot: worktree setup commands and their logs.
public struct WorktreeSetup: Sendable {
    public struct Command: Sendable, Identifiable {
        public let index: Int
        public let command: String
        public let log: String
        /// running, completed, failed.
        public let status: String
        public let exitCode: Int?
        public let durationMs: Double?
        public var id: Int { index }
    }
    /// running, completed, failed, blocked.
    public let status: String
    public let error: String?
    public let branchName: String?
    public let log: String
    public let commands: [Command]

    init(_ v: JSONValue) {
        status = v["status"]?.stringValue ?? "running"
        error = v["error"]?.stringValue
        let d = v["detail"]
        branchName = d?["branchName"]?.stringValue
        log = d?["log"]?.stringValue ?? ""
        commands = (d?["commands"]?.arrayValue ?? []).compactMap { c in
            guard let i = c["index"]?.doubleValue, let cmd = c["command"]?.stringValue else { return nil }
            return Command(index: Int(i), command: cmd, log: c["log"]?.stringValue ?? "", status: c["status"]?.stringValue ?? "running",
                           exitCode: c["exitCode"]?.doubleValue.map(Int.init), durationMs: c["durationMs"]?.doubleValue)
        }
    }
}
