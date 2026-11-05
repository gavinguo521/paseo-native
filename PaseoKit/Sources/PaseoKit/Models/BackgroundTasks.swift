import Foundation

/// Claude 后台命令（Bash 的 run_in_background）的结束通知。daemon 把 Claude 的 task_notification 转成一条名为
/// `task_notification` 的工具调用，metadata 里带原命令的调用 id（toolUseId）、任务 id（taskId）和原始状态
/// （vendor/paseo/packages/server/src/server/agent/providers/claude/task-notification-tool-call.ts）。
public struct BackgroundTaskEnd: Sendable, Equatable {
    /// Claude 的原始状态：completed / failed / stopped / killed 等。
    public let status: String
    public let summary: String?

    /// 从一条原始时间线条目里认出结束通知，返回 (配对用的 id 列表, 结束信息)。
    static func parse(_ item: JSONValue) -> (keys: [String], end: BackgroundTaskEnd)? {
        guard item["type"]?.stringValue == "tool_call", item["name"]?.stringValue == "task_notification" else { return nil }
        let meta = item["metadata"]
        let keys = [meta?["toolUseId"]?.stringValue, meta?["taskId"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }
        let status = meta?["status"]?.stringValue ?? item["status"]?.stringValue ?? "completed"
        let summary = item["detail"]?["label"]?.stringValue
        return (keys, BackgroundTaskEnd(status: status, summary: summary))
    }
}

/// 会话里一条后台命令和它现在的状态。daemon 不提供「正在跑的后台任务」列表，这里由时间线推出来：
/// 输出是「Command running in background with ID: …」的命令行，还没等到对应的结束通知，就是在跑。
public struct AgentBackgroundTask: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case running, completed, failed, stopped
        /// 没等到结束通知，会话就已关闭或出错：Claude 进程退出时后台命令会跟着结束，但不会再有通知。
        case interrupted
    }

    /// 原命令的调用 id。
    public let id: String
    public let taskId: String
    public let command: String
    public let startedAt: Date?
    public let state: State
    public let summary: String?

    /// 时间线里那条命令的行 id（`AgentTimeline` 用 "tool-<callId>"）。
    public var rowId: String { "tool-\(id)" }

    private static let marker = "running in background with ID:"

    /// 后台命令的任务 id，不是后台命令返回 nil。
    public static func taskId(fromOutput output: String) -> String? {
        guard let r = output.range(of: marker) else { return nil }
        let rest = output[r.upperBound...].drop { $0 == " " }
        let id = rest.prefix { !$0.isWhitespace && $0 != "." && $0 != "," }
        return id.isEmpty ? nil : String(id)
    }

    static func state(for end: BackgroundTaskEnd) -> State {
        switch end.status.lowercased() {
        case "failed", "error": .failed
        case "stopped", "killed", "canceled", "cancelled": .stopped
        default: .completed
        }
    }
}

extension AgentTimeline {
    /// 已加载的时间线里所有后台命令，按开始先后排列。`sessionEnded`：会话已关闭或出错，没结束的算中断。
    /// 只看已加载的部分：更早、还没加载的历史里开始的后台命令不在其中。
    public func backgroundTasks(sessionEnded: Bool) -> [AgentBackgroundTask] {
        rows.compactMap { row -> AgentBackgroundTask? in
            guard case .toolCall(let callId, _, _, let detail, _, _) = row.item,
                  case .shell(let command, _, let output, _) = detail,
                  let output, let taskId = AgentBackgroundTask.taskId(fromOutput: output) else { return nil }
            let end = backgroundTaskEnds[callId] ?? backgroundTaskEnds[taskId]
            let state: AgentBackgroundTask.State = end.map(AgentBackgroundTask.state(for:)) ?? (sessionEnded ? .interrupted : .running)
            return AgentBackgroundTask(id: callId, taskId: taskId, command: command, startedAt: row.timestamp, state: state,
                                  summary: end?.summary)
        }
    }
}
