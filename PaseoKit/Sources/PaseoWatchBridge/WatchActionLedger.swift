import Foundation

/// Persist before dispatching a mutation. A lost reply, duplicate tap, or phone restart must not
/// turn a WatchConnectivity retry into a second message or a different permission approval.
public actor WatchActionLedger {
    private struct Record: Codable {
        var request: WatchRequest
        var result: WatchActionResult?
    }
    private var records: [String: Record]
    private var running: [UUID: Task<WatchActionResult, Never>] = [:]
    private let file: URL
    private var readable: Bool

    public init(file: URL) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
                records = decoded; readable = true
            } else { records = [:]; readable = false }
        } else { records = [:]; readable = true }
    }

    public func request(for id: UUID) -> WatchRequest? { records[id.uuidString]?.request }
    public func result(for id: UUID) -> WatchActionResult? { records[id.uuidString]?.result }
    public func contains(_ id: UUID) -> Bool { records[id.uuidString] != nil }

    public func execute(_ request: WatchRequest, now: Date = Date(),
                        operation: @escaping @Sendable () async -> WatchActionResult) async -> WatchActionResult {
        guard readable, request.command.isAction else { return .init(.notSent, "invalid-ledger") }
        let key = request.id.uuidString
        if let old = records[key] {
            guard old.request == request else { return .init(.notSent, "request-mismatch") }
            if let task = running[request.id] { return await task.value }
            return old.result ?? .init(.uncertain, "result-unconfirmed")
        }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= -60, age < 180 else { return .init(.notSent, "request-expired") }
        // Old IDs cannot execute again after pruning because the timestamp check above rejects them.
        records = records.filter { now.timeIntervalSince($0.value.request.createdAt) < 86_400 }
        records[key] = Record(request: request, result: nil)
        do { try save() } catch { records[key] = nil; return .init(.notSent, "cannot-save-action") }
        let task = Task { await operation() }
        running[request.id] = task
        let result = await task.value
        records[key]?.result = result
        running[request.id] = nil
        // A durable pending entry still prevents replay if this write fails.
        try? save()
        return result
    }

    public func confirm(_ id: UUID, message: String) {
        guard records[id.uuidString] != nil else { return }
        records[id.uuidString]?.result = .init(.confirmed, message)
        try? save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }
}
