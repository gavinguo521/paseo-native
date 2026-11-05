import Foundation

/// What the app itself went through (connection changes and their errors), kept in memory for 「导出诊断信息」.
/// Holds no chat text, pairing links or passwords.
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 2000

    public func record(_ category: String, _ message: String) {
        let line = Date().formatted(.iso8601) + " [" + category + "] " + message
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
