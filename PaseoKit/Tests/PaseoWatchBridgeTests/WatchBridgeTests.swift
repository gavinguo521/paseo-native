import Foundation
import Testing
@testable import PaseoWatchBridge

private func location() -> URL { FileManager.default.temporaryDirectory.appending(path: "paseo-watch-test-" + UUID().uuidString).appending(path: "actions.json") }
private func summary(_ host: String, status: WatchSessionStatus = .running) -> WatchSessionSummary {
    .init(ref: .init(hostID: host, agentID: "same-agent"), title: "修复登录页", hostName: host, status: status, updatedAt: Date(timeIntervalSince1970: 100), startedAt: nil)
}

@Test func requestRoundTripKeepsActionIdentityAndUnicode() throws {
    let request = WatchRequest(command: .reply(.init(hostID: "mini", agentID: "agent"), text: "继续测试 👋\n完成后告诉我"))
    let decoded = try WatchEnvelope.decode(WatchEnvelope(request: request).encoded())
    #expect(decoded.request == request)
    #expect(decoded.request?.messageID == request.messageID)
}

@Test func protocolVersionMismatchIsRejected() throws {
    let envelope = WatchEnvelope(request: .init(command: .overview))
    var json = try #require(JSONSerialization.jsonObject(with: envelope.encoded()) as? [String: Any])
    json["version"] = 999
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: WatchWireError.self) { try WatchEnvelope.decode(data) }
}

@Test func oversizedMultibyteMessageIsRejectedBeforeTransport() {
    let request = WatchRequest(command: .reply(.init(hostID: "mini", agentID: "agent"), text: String(repeating: "👋", count: 20_000)))
    #expect(throws: WatchWireError.self) { try WatchEnvelope(request: request).encoded() }
}

@Test func olderBackgroundSnapshotCannotReplaceNewerHostData() {
    let newer = WatchSessionPage(hostID: "mini", refreshedAt: .init(timeIntervalSince1970: 200), sessions: [summary("mini", status: .done)])
    var cache = WatchOverview(hosts: [.init(id: "mini", name: "Mac mini")], pages: [newer])
    cache.merge(WatchOverview(hosts: cache.hosts, pages: [.init(hostID: "mini", refreshedAt: .init(timeIntervalSince1970: 100), sessions: [summary("mini")])]))
    #expect(cache.pages == [newer])
}

@Test func hostFilterAndSessionIDsKeepMachinesSeparate() {
    let cache = WatchOverview(hosts: [.init(id: "mini", name: "Mini"), .init(id: "air", name: "Air")],
                              pages: [.init(hostID: "mini", sessions: [summary("mini")]), .init(hostID: "air", sessions: [summary("air", status: .waiting)])])
    #expect(cache.sessions(hostID: "mini").map(\.ref.hostID) == ["mini"])
    #expect(cache.sessions(hostID: nil).first?.ref.hostID == "air")
    #expect(Set(cache.sessions(hostID: nil).map(\.id)).count == 2)
}

@Test func removingPairedHostDropsItsCachedSessions() {
    var cache = WatchOverview(hosts: [.init(id: "mini", name: "Mini"), .init(id: "air", name: "Air")],
                              pages: [.init(hostID: "mini", sessions: [summary("mini")]), .init(hostID: "air", sessions: [summary("air")])])
    cache.merge(.init(hosts: [.init(id: "mini", name: "Mini")]))
    #expect(cache.pages.map(\.hostID) == ["mini"])
}

private actor Counter {
    var count = 0
    func increment() -> WatchActionResult { count += 1; return .init(.confirmed, "sent") }
}

@Test func concurrentRetriesExecuteMutationOnlyOnce() async {
    let file = location()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let ledger = WatchActionLedger(file: file)
    let counter = Counter()
    let request = WatchRequest(command: .reply(.init(hostID: "mini", agentID: "agent"), text: "继续"))
    await withTaskGroup(of: WatchActionResult.self) { group in
        for _ in 0..<20 { group.addTask { await ledger.execute(request) { await counter.increment() } } }
        for await result in group { #expect(result.state == .confirmed) }
    }
    #expect(await counter.count == 1)
}

@Test func completedReceiptSurvivesPhoneRestart() async {
    let file = location()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let request = WatchRequest(command: .permission(.init(hostID: "mini", agentID: "agent"), requestID: "permission-1", revision: "rev", actionID: "allow"))
    let first = WatchActionLedger(file: file)
    _ = await first.execute(request) { .init(.confirmed, "handled") }
    let restarted = WatchActionLedger(file: file)
    let counter = Counter()
    let result = await restarted.execute(request) { await counter.increment() }
    #expect(result == .init(.confirmed, "handled"))
    #expect(await counter.count == 0)
}

@Test func reusingIDForDifferentActionCannotChangePermissionDecision() async {
    let file = location()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    var request = WatchRequest(command: .permission(.init(hostID: "mini", agentID: "agent"), requestID: "old", revision: "rev", actionID: "allow"))
    let ledger = WatchActionLedger(file: file)
    _ = await ledger.execute(request) { .init(.confirmed, "handled") }
    request.command = .permission(.init(hostID: "mini", agentID: "agent"), requestID: "new", revision: "rev", actionID: "allow")
    let counter = Counter()
    let result = await ledger.execute(request) { await counter.increment() }
    #expect(result.state == .notSent)
    #expect(await counter.count == 0)
}

@Test func expiredOfflineActionIsNeverExecutedLater() async {
    let file = location()
    let ledger = WatchActionLedger(file: file)
    let now = Date()
    let request = WatchRequest(createdAt: now.addingTimeInterval(-181), command: .reply(.init(hostID: "mini", agentID: "agent"), text: "旧指令"))
    let counter = Counter()
    let result = await ledger.execute(request, now: now) { await counter.increment() }
    #expect(result.state == .notSent)
    #expect(await counter.count == 0)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func unreadableReceiptStoreFailsClosed() async throws {
    let file = location()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: file)
    let ledger = WatchActionLedger(file: file)
    let counter = Counter()
    let result = await ledger.execute(.init(command: .reply(.init(hostID: "mini", agentID: "agent"), text: "继续"))) { await counter.increment() }
    #expect(result.state == .notSent)
    #expect(await counter.count == 0)
}

@Test func permissionRequiresCurrentContentAndExactAction() {
    let permission = WatchPermission(id: "request-1", title: "Test", detail: "npm test", revision: "new-content",
                                     actions: [.init(id: "allow-once", label: "Allow Once", behavior: "allow")])
    #expect(permission.action(id: "allow-once", expectedRevision: "old-content") == nil)
    #expect(permission.action(id: "allow-always", expectedRevision: "new-content") == nil)
    #expect(permission.action(id: "allow-once", expectedRevision: "new-content")?.behavior == "allow")
    var incomplete = permission
    incomplete.needsPhone = true
    #expect(incomplete.action(id: "allow-once", expectedRevision: "new-content") == nil)
}

private actor OperationGate {
    var entered = false
    var entryWaiter: CheckedContinuation<Void, Never>?
    var operationWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { operationWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func resume() { operationWaiter?.resume(); operationWaiter = nil }
}

@Test func restartDuringDispatchKeepsOutcomeUncertainWithoutReplaying() async {
    let file = location()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let ledger = WatchActionLedger(file: file)
    let gate = OperationGate()
    let request = WatchRequest(command: .reply(.init(hostID: "mini", agentID: "agent"), text: "继续"))
    let inFlight = Task { await ledger.execute(request) { await gate.pause(); return .init(.confirmed, "sent") } }
    await gate.waitForEntry()
    let restarted = WatchActionLedger(file: file)
    let counter = Counter()
    let result = await restarted.execute(request) { await counter.increment() }
    #expect(result.state == .uncertain)
    #expect(await counter.count == 0)
    await gate.resume()
    _ = await inFlight.value
}
