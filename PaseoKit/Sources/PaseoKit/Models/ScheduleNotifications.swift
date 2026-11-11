import Foundation

/// Stored on the execution host by live-activity, not in the daemon's schedule
/// config (which strips unknown fields). Older plugins must not look like "off".
public struct ScheduleNotificationPreference: Sendable, Equatable {
    public let enabled: Bool
    public let revision: String
    public let ready: Bool

    public init?(_ value: JSONValue) {
        guard value["version"]?.doubleValue == 1,
              let enabled = value["enabled"]?.boolValue,
              let revision = value["revision"]?.stringValue, !revision.isEmpty,
              let ready = value["ready"]?.boolValue else { return nil }
        self.enabled = enabled
        self.revision = revision
        self.ready = ready
    }
}

/// A failed run may have no agent; always open schedule history from this push.
public struct ScheduleNotificationRoute: Sendable, Hashable {
    public let serverId: String
    public let scheduleId: String

    public init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["reason"] as? String == "schedule_result",
              let serverId = userInfo["serverId"] as? String, !serverId.isEmpty,
              let scheduleId = userInfo["scheduleId"] as? String, !scheduleId.isEmpty else { return nil }
        self.serverId = serverId
        self.scheduleId = scheduleId
    }

    /// Bark opens the same task history as native APNs, including failures that
    /// happened before a session was created. Links only navigate, never run tasks.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "paseonative", url.host?.lowercased() == "schedule",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let servers = items.filter { $0.name == "serverId" }
        let schedules = items.filter { $0.name == "scheduleId" }
        guard servers.count == 1, schedules.count == 1,
              let serverId = servers.first?.value, let scheduleId = schedules.first?.value,
              [serverId, scheduleId].allSatisfy({ value in
                  !value.isEmpty && value.count <= 200 && value.utf8.allSatisfy {
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                  }
              }) else { return nil }
        self.serverId = serverId
        self.scheduleId = scheduleId
    }
}
