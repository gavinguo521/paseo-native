import Foundation
import Testing
@testable import PaseoKit

@Suite(.timeLimit(.minutes(1))) struct ConnectionRecoveryTests {
    @Test func silentTransportProbeTimesOutWithoutWaitingForAnotherFrame() async {
        let transport = RecoveryTransport()
        let connection = DaemonConnection(channel: transport)
        // 失败时主动关闭以释放旧实现悬挂的 waiter；正常超时必须在此之前自行返回。
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await connection.close() }
        }
        let alive = await connection.probeLiveness(timeout: .milliseconds(10))
        watchdog.cancel()
        #expect(!alive)
        #expect(await !connection.isClosed)
        await connection.close()
    }

    @Test func cancelledProbeReturnsWithoutClosingHealthyConnection() async {
        let transport = RecoveryTransport()
        let connection = DaemonConnection(channel: transport)
        let probe = Task { await connection.probeLiveness(timeout: .seconds(30)) }
        _ = await transport.nextSent("ping")
        probe.cancel()
        #expect(await !probe.value)
        #expect(await !connection.isClosed)
        await connection.close()
    }

    @Test func receivedPongKeepsConnectionAlive() async throws {
        let transport = RecoveryTransport()
        let connection = try await connected(transport)
        let probe = Task { await connection.probeLiveness() }
        _ = await transport.nextSent("ping")
        await transport.deliver(["type": "pong"])
        #expect(await probe.value)
        #expect(await !connection.isClosed)
        await connection.close()
    }

    @Test func foregroundTimeoutClosesStaleConnectionAndFinishesEvents() async {
        let transport = RecoveryTransport()
        let connection = DaemonConnection(channel: transport)
        await connection.validateOnForeground(timeout: .milliseconds(10))
        #expect(await connection.isClosed)
        var events = connection.events.makeAsyncIterator()
        #expect(await events.next() == nil)
    }

    @Test func foregroundPongPreservesWorkingConnection() async throws {
        let transport = RecoveryTransport()
        let connection = try await connected(transport)
        let check = Task { await connection.validateOnForeground() }
        let request = try #require(await transport.nextSent("ping"))
        #expect(request["clientSentAt"]?.doubleValue?.rounded() == request["clientSentAt"]?.doubleValue)
        await transport.reply(to: request, type: "pong")
        await check.value
        #expect(await !connection.isClosed)
        await connection.close()
    }

    @Test @MainActor func disconnectedHistoryDoesNotBecomePermanentLoadError() async throws {
        let transport = RecoveryTransport()
        let connection = try await connected(transport)
        let host = makeHost()
        host.connection = connection
        let load = Task { await host.catchUp("agent", connection) }
        _ = await transport.nextSent("fetch_agent_timeline_request")
        await transport.abort()
        await load.value
        #expect(await connection.isClosed)
        #expect(host.timelineErrors["agent"] == nil)
        #expect(!host.timelineLoading.contains("agent"))
        #expect(host.timelines["agent"] == nil)
    }

    @Test @MainActor func newConnectionLoadsWhileOldRequestIsStillFinishing() async throws {
        let oldTransport = RecoveryTransport()
        let old = try await connected(oldTransport)
        let host = makeHost()
        host.connection = old
        let oldLoad = Task { await host.catchUp("agent", old) }
        let oldRequest = try #require(await oldTransport.nextSent("fetch_agent_timeline_request"))

        let transport = RecoveryTransport()
        let current = try await connected(transport)
        host.connection = current
        let load = Task { await host.catchUp("agent", current) }
        let request = try #require(await transport.nextSent("fetch_agent_timeline_request"))
        await oldTransport.reply(to: oldRequest, type: "rpc_error", payload: ["error": "旧连接请求失败"])
        await oldLoad.value
        #expect(host.timelineErrors["agent"] == nil)
        await transport.reply(to: request, type: "fetch_agent_timeline_response", payload: [
            "direction": "tail", "epoch": "new", "entries": [], "hasOlder": false, "hasNewer": false,
        ])
        await load.value
        #expect(host.timelines["agent"]?.epoch == "new")
        #expect(host.timelineErrors["agent"] == nil)
        await old.close()
        await current.close()
    }

    @Test @MainActor func realHistoryErrorRemainsVisibleAndSuccessfulRetryClearsIt() async throws {
        let transport = RecoveryTransport()
        let connection = try await connected(transport)
        let host = makeHost()
        host.connection = connection
        let load = Task { await host.catchUp("agent", connection) }
        let request = try #require(await transport.nextSent("fetch_agent_timeline_request"))
        await transport.reply(to: request, type: "rpc_error", payload: ["error": "历史读取失败"])
        await load.value
        #expect(host.timelineErrors["agent"]?.contains("历史读取失败") == true)

        let retry = Task { await host.catchUp("agent", connection) }
        let retryRequest = try #require(await transport.nextSent("fetch_agent_timeline_request"))
        await transport.reply(to: retryRequest, type: "fetch_agent_timeline_response", payload: ["epoch": "ok", "entries": []])
        await retry.value
        #expect(host.timelineErrors["agent"] == nil)
        #expect(host.timelines["agent"]?.isLoaded == true)
        await connection.close()
    }

    private func connected(_ transport: RecoveryTransport) async throws -> DaemonConnection {
        let connection = DaemonConnection(channel: transport)
        try await connection.handshake(hello: HelloOptions(clientId: "test"), expectedServerId: "test")
        return connection
    }

    @MainActor private func makeHost() -> HostStore {
        HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                  label: "测试", clientId: "test", appVersion: "test")
    }
}

/// 用请求到达作为同步点，测试不依赖真实 daemon、网络或业务数据。
actor RecoveryTransport: FrameTransport {
    private var incoming: [WireFrame] = []
    private var receiver: CheckedContinuation<WireFrame, Error>?
    private var closed = false
    private let sent: AsyncStream<JSONValue>
    private let sentSink: AsyncStream<JSONValue>.Continuation

    init() { (sent, sentSink) = AsyncStream.makeStream(of: JSONValue.self) }

    func send(_ frame: WireFrame) async throws {
        guard !closed else { throw TransportClosed(code: 1000, reason: "test closed") }
        guard case .text(let text) = frame else { return }
        let message = try JSONValue.parse(text)
        if message["type"]?.stringValue == "hello" {
            deliver(["type": "session", "message": ["type": "status", "payload": ["status": "server_info", "serverId": "test"]]])
        } else {
            sentSink.yield(message["message"] ?? message)
        }
    }

    func receive() async throws -> WireFrame {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw TransportClosed(code: 1000, reason: "test closed") }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close(code: Int, reason: String) async {
        closed = true
        receiver?.resume(throwing: TransportClosed(code: code, reason: reason))
        receiver = nil
        sentSink.finish()
    }

    func abort() {
        closed = true
        receiver?.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: 53))
        receiver = nil
        sentSink.finish()
    }

    func deliver(_ message: JSONValue) {
        let frame = WireFrame.text(try! message.serialized())
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else { incoming.append(frame) }
    }

    func reply(to request: JSONValue, type: String, payload: [String: JSONValue] = [:]) {
        var payload = payload
        payload["requestId"] = request["requestId"]
        deliver(["type": "session", "message": ["type": .string(type), "payload": .object(payload)]])
    }

    func nextSent(_ type: String) async -> JSONValue? {
        for await message in sent where message["type"]?.stringValue == type { return message }
        return nil
    }
}
