import Foundation

/// daemon 提供的实时后台工作；不从命令输出推断，也不持久化停止令牌。
public struct AgentBackgroundWork: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let description: String?
    public let command: String?
    public let startedAt: Date?
    public let canStop: Bool
    public let stopToken: String?

    public init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue else { return nil }
        self.id = id
        kind = value["kind"]?.stringValue ?? "other"
        description = value["description"]?.stringValue
        command = value["command"]?.stringValue
        startedAt = value["startedAt"]?.dateValue
        stopToken = value["stopToken"]?.stringValue
        canStop = value["canStop"]?.boolValue == true && stopToken != nil
    }
}
