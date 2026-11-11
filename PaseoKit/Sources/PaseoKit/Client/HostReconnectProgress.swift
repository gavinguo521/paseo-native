import Foundation

/// Persisted per client so relaunching does not restart a long offline period.
public struct HostReconnectProgress: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let failures: Int
    public let retryAt: Date

    public init(startedAt: Date, failures: Int, retryAt: Date) {
        self.startedAt = startedAt
        self.failures = failures
        self.retryAt = retryAt
    }

    static let frequentRetryDuration: TimeInterval = 15 * 60
    static let slowRetryInterval: TimeInterval = 30 * 60
    static let slowRetryDuration: TimeInterval = 24 * 60 * 60

    var frequentRetryEndsAt: Date { startedAt.addingTimeInterval(Self.frequentRetryDuration) }
    var expiresAt: Date { frequentRetryEndsAt.addingTimeInterval(Self.slowRetryDuration) }

    static func afterFailure(startedAt: Date, failures: Int, now: Date) -> Self {
        let failures = min(max(failures, 1), 6)
        let frequentEnd = startedAt.addingTimeInterval(frequentRetryDuration)
        let deadline = frequentEnd.addingTimeInterval(slowRetryDuration)
        let retryAt: Date
        if now < frequentEnd {
            let delay = min(1.5 * pow(2, Double(failures - 1)), 30)
            retryAt = min(now.addingTimeInterval(delay), frequentEnd)
        } else {
            retryAt = min(now.addingTimeInterval(slowRetryInterval), deadline)
        }
        return Self(startedAt: startedAt, failures: failures, retryAt: retryAt)
    }
}
