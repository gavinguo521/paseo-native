// Schedules (and heartbeats) and usage reports. See docs/protocol/04-schedules-usage-workspaces.md §1–2.

import Foundation

public struct ScheduleRun: Sendable, Identifiable {
    public let id: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let status: String
    public let agentId: String?
    public let output: String?
    public let error: String?

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        startedAt = v["startedAt"]?.dateValue
        endedAt = v["endedAt"]?.dateValue
        status = v["status"]?.stringValue ?? "running"
        agentId = v["agentId"]?.stringValue
        output = v["output"]?.stringValue
        error = v["error"]?.stringValue
    }
}

public struct Schedule: Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let prompt: String
    public let cronExpression: String?
    public let timezone: String?
    public let everyMs: Double?
    /// "agent" (heartbeat) or "new-agent".
    public let targetType: String
    public let targetAgentId: String?
    public let config: JSONValue?
    public let status: String
    public let createdAt: Date?
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    public let expiresAt: Date?
    public let maxRuns: Int?
    public let runs: [ScheduleRun]

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        name = v["name"]?.stringValue
        prompt = v["prompt"]?.stringValue ?? ""
        cronExpression = v["cadence"]?["expression"]?.stringValue
        timezone = v["cadence"]?["timezone"]?.stringValue
        everyMs = v["cadence"]?["everyMs"]?.doubleValue
        targetType = v["target"]?["type"]?.stringValue ?? "new-agent"
        targetAgentId = v["target"]?["agentId"]?.stringValue
        config = v["target"]?["config"]
        status = v["status"]?.stringValue ?? "active"
        createdAt = v["createdAt"]?.dateValue
        nextRunAt = v["nextRunAt"]?.dateValue
        lastRunAt = v["lastRunAt"]?.dateValue
        expiresAt = v["expiresAt"]?.dateValue
        maxRuns = v["maxRuns"]?.doubleValue.map(Int.init)
        runs = (v["runs"]?.arrayValue ?? []).compactMap(ScheduleRun.init)
    }

    public var isHeartbeat: Bool { targetType == "agent" }
    public var cwd: String? { config?["cwd"]?.stringValue }

    /// Official title order: name → config.title → first prompt line.
    public var title: String {
        if let name, !name.isEmpty { return name }
        if let t = config?["title"]?.stringValue, !t.isEmpty { return t }
        let first = prompt.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? (isHeartbeat ? String(localized: "未命名心跳", bundle: .module) : String(localized: "未命名计划任务", bundle: .module)) : first
    }

    public var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }
}

public struct UsageWindow: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let shortLabel: String?
    public let usedPct: Double?
    public let remainingPct: Double?
    public let resetsAt: Date?
    public let runsOutAt: Date?
    public let tone: String?
    public let summary: Bool
}

public struct UsageBalance: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let used: Double?
    public let remaining: Double?
    public let limit: Double?
    public let unit: String
}

public struct UsageReport: Sendable, Identifiable {
    public let id: String
    public let sourceId: String
    public let sourceLabel: String
    /// Inline SVG for the source (currentColor), as shipped by the usage source plugin.
    public let iconSVG: String?
    public let account: String?
    public let fetchedAt: Date?
    public let planLabel: String?
    public let windows: [UsageWindow]
    public let balances: [UsageBalance]
    public let details: [(label: String, value: String)]
    /// Set when the latest fetch failed; `windows` then come from the last successful report.
    public let problem: String?
    public let retained: Bool

    public init?(_ e: JSONValue) {
        guard let id = e["id"]?.stringValue else { return nil }
        self.id = id
        sourceId = e["sourceId"]?.stringValue ?? ""
        sourceLabel = e["sourceLabel"]?.stringValue ?? sourceId
        iconSVG = e["icon"]?.stringValue
        account = e["account"]?["label"]?.stringValue
        fetchedAt = e["fetchedAt"]?.dateValue
        var report = e["report"] ?? .null
        var problem: String?
        var retained = false
        switch report["status"]?.stringValue {
        case "unavailable":
            let p = report["problem"]
            switch p?["kind"]?.stringValue {
            case "expired":
                if let cmd = p?["refreshedBy"]?.stringValue { problem = String(localized: "登录已过期，运行 \(cmd) 重新登录", bundle: .module) }
                else { problem = String(localized: "登录已过期", bundle: .module) }
            case "rejected": problem = String(localized: "凭据被拒绝（\(Int(p?["status"]?.doubleValue ?? 0))）", bundle: .module)
            case "no_quota": problem = p?["detail"]?.stringValue ?? String(localized: "没有额度信息", bundle: .module)
            default: problem = String(localized: "不可用", bundle: .module)
            }
        case "error": problem = report["error"]?.stringValue ?? String(localized: "获取失败", bundle: .module)
        default: break
        }
        if problem != nil, let last = e["lastSuccessful"]?["report"] { report = last; retained = true }
        self.problem = problem
        self.retained = retained
        planLabel = report["planLabel"]?.stringValue
        windows = (report["windows"]?.arrayValue ?? []).compactMap { w in
            guard let id = w["id"]?.stringValue else { return nil }
            return UsageWindow(id: id, label: w["label"]?.stringValue ?? id, shortLabel: w["shortLabel"]?.stringValue,
                               usedPct: w["usedPct"]?.doubleValue, remainingPct: w["remainingPct"]?.doubleValue,
                               resetsAt: w["resetsAt"]?.dateValue, runsOutAt: w["runsOutAt"]?.dateValue,
                               tone: w["tone"]?.stringValue, summary: w["summary"]?.boolValue ?? false)
        }
        balances = (report["balances"]?.arrayValue ?? []).compactMap { b in
            guard let id = b["id"]?.stringValue else { return nil }
            return UsageBalance(id: id, label: b["label"]?.stringValue ?? id, used: b["used"]?.doubleValue,
                                remaining: b["remaining"]?.doubleValue, limit: b["limit"]?.doubleValue, unit: b["unit"]?.stringValue ?? "")
        }
        details = (report["details"]?.arrayValue ?? []).compactMap { d in
            guard let l = d["label"]?.stringValue, let v = d["value"]?.stringValue else { return nil }
            return (l, v)
        }
    }
}
