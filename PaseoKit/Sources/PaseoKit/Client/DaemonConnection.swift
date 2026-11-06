// One connection to a daemon over the relay: secure channel, app hello, request/response correlation,
// server-push events and liveness pings. Reconnect policy lives a layer above.
// See docs/protocol/01-connection.md §4–§6.

import Foundation

public enum DaemonConnectionError: Error, CustomStringConvertible {
    case rejected(reason: String)
    case serverIdMismatch(expected: String, actual: String)
    case rpc(requestType: String, code: String?, message: String)
    case timeout(String)
    case closed(String)

    public var description: String {
        switch self {
        case .rejected(let r): "daemon rejected hello: \(r)"
        case .serverIdMismatch(let e, let a): "server id mismatch: expected \(e), got \(a)"
        case .rpc(let t, let c, let m): "\(t) failed\(c.map { " [\($0)]" } ?? ""): \(m)"
        case .timeout(let what): "timed out: \(what)"
        case .closed(let why): "connection closed: \(why)"
        }
    }

    /// Wrong or missing password: retrying won't help.
    public var isAuthFailure: Bool {
        if case .rejected(let r) = self { return r == "password_required" || r == "incorrect_password" }
        return false
    }
}

public struct ServerInfo: Sendable {
    public let raw: JSONValue
    public var serverId: String { raw["serverId"]?.stringValue ?? "" }
    public var hostname: String? { raw["hostname"]?.stringValue }
    public var version: String? { raw["version"]?.stringValue }
    public var features: [String: JSONValue] { raw["features"]?.objectValue ?? [:] }
    public func hasFeature(_ name: String) -> Bool { features[name]?.boolValue == true }
}

public struct HelloOptions: Sendable {
    public var clientId: String
    public var password: String?
    public var appVersion: String
    /// Only advertise what the client actually handles: the daemon gates new message shapes on these.
    public var capabilities: [String: JSONValue]

    public init(clientId: String, password: String? = nil, appVersion: String = "0.1.0",
                capabilities: [String: JSONValue] = ["hello_rejection": true]) {
        self.clientId = clientId
        self.password = password
        self.appVersion = appVersion
        self.capabilities = capabilities
    }
}

public actor DaemonConnection {
    public nonisolated let events: AsyncStream<JSONValue>
    public private(set) var serverInfo: ServerInfo?
    /// Whether the relay channel negotiated binary ciphertext frames (always false for direct hosts).
    public nonisolated let binaryCiphertext: Bool

    /// The E2EE relay channel, or the bare socket for direct hosts.
    private let channel: any FrameTransport
    private let eventSink: AsyncStream<JSONValue>.Continuation
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    /// Streaming RPCs: `….update` messages sharing the request id before the final response.
    private var updateHandlers: [String: @Sendable (JSONValue) -> Void] = [:]
    /// App-level binary frames (file transfer 0x10–0x12, terminal 0x01–0x05).
    private var binaryHandler: (@Sendable (Data) -> Void)?

    public func setBinaryHandler(_ handler: @escaping @Sendable (Data) -> Void) { binaryHandler = handler }

    public func sendBinary(_ data: Data) async throws {
        if let closedReason { throw DaemonConnectionError.closed(closedReason) }
        try await channel.send(.binary(data))
    }
    private var pongWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var inboundRevision = 0
    private var closedReason: String?
    private var readLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?

    init(channel: any FrameTransport, binaryCiphertext: Bool = false) {
        self.binaryCiphertext = binaryCiphertext
        // Reassembles `binary_chunking_v1` messages; plain frames pass straight through.
        self.channel = ChunkedReceiver(channel)
        (events, eventSink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .bufferingNewest(10_000))
    }

    /// Opens the relay socket, runs the E2EE handshake and the app hello. Returns once `server_info` arrives.
    /// `transport` overrides the relay socket (paseo-probe wraps it to count bytes); `offerBinaryCiphertext: false`
    /// keeps every record as base64 text, the pre-1.1 behaviour.
    public static func connect(
        offer: PairingOffer, hello: HelloOptions, timeout: Duration = .seconds(15),
        transport customTransport: (any FrameTransport)? = nil, offerBinaryCiphertext: Bool = true
    ) async throws -> DaemonConnection {
        if offer.isDirect {
            return try await connectDirect(url: offer.directWebSocketURL(), hello: hello, expectedServerId: offer.serverId, timeout: timeout)
        }
        let transport = try customTransport ?? WebSocketTransport(url: offer.relayWebSocketURL())
        return try await withTimeout(timeout, "connect") {
            let channel = try await SecureChannel.open(transport: transport, daemonPublicKey: offer.daemonPublicKey,
                                                       offerBinaryCiphertext: offerBinaryCiphertext)
            let connection = DaemonConnection(channel: channel, binaryCiphertext: channel.binaryCiphertext)
            try await connection.handshake(hello: hello, expectedServerId: offer.serverId)
            return connection
        } onTimeout: {
            await transport.close(code: 1001, reason: "Connect timed out")
        }
    }

    /// Direct WebSocket without a relay or E2EE; `expectedServerId` empty accepts whichever daemon answers (adding a host).
    public static func connectDirect(url: URL, hello: HelloOptions, expectedServerId: String, timeout: Duration = .seconds(15)) async throws -> DaemonConnection {
        let transport = WebSocketTransport(url: url)
        return try await withTimeout(timeout, "connect") {
            let connection = DaemonConnection(channel: transport)
            try await connection.handshake(hello: hello, expectedServerId: expectedServerId)
            return connection
        } onTimeout: {
            await transport.close(code: 1001, reason: "Connect timed out")
        }
    }

    func handshake(hello: HelloOptions, expectedServerId: String) async throws {
        var msg: [String: JSONValue] = [
            "type": "hello",
            "clientId": .string(hello.clientId),
            "clientType": "mobile",
            "protocolVersion": 1,
            "appVersion": .string(hello.appVersion),
            "capabilities": .object(hello.capabilities),
        ]
        if let pw = hello.password, !pw.isEmpty {
            msg["auth"] = ["kind": "password", "password": .string(pw)]
        }
        try await channel.send(.text(JSONValue.object(msg).serialized()))

        while true {
            guard case .text(let text) = try await channel.receive(), let m = try? JSONValue.parse(text) else { continue }
            if m["type"]?.stringValue == "hello.rejected" {
                await channel.close(code: 1000, reason: "")
                throw DaemonConnectionError.rejected(reason: m["reason"]?.stringValue ?? "unknown")
            }
            if m["type"]?.stringValue == "session", let inner = m["message"], inner["type"]?.stringValue == "status",
               let payload = inner["payload"], payload["status"]?.stringValue == "server_info" {
                let info = ServerInfo(raw: payload)
                guard expectedServerId.isEmpty || info.serverId == expectedServerId else {
                    await channel.close(code: 1000, reason: "")
                    throw DaemonConnectionError.serverIdMismatch(expected: expectedServerId, actual: info.serverId)
                }
                serverInfo = info
                break
            }
        }
        readLoop = Task { await self.runReadLoop() }
        pingLoop = Task { await self.runPingLoop() }
    }

    // MARK: Requests

    /// Sends `{"type":"session","message":{type, requestId, ...params}}` and waits for the response whose
    /// `payload.requestId` matches, or an `rpc_error`. Returns the response `message` (type + payload).
    public func request(_ type: String, _ params: [String: JSONValue] = [:], timeout: Duration = .seconds(60),
                        onUpdate: (@Sendable (JSONValue) -> Void)? = nil, requestId: String? = nil) async throws -> JSONValue {
        if let closedReason { throw DaemonConnectionError.closed(closedReason) }
        let requestId = requestId ?? UUID().uuidString.lowercased()
        if let onUpdate { updateHandlers[requestId] = onUpdate }
        var message = params
        message["type"] = .string(type)
        message["requestId"] = .string(requestId)
        let text = try JSONValue.object(["type": "session", "message": .object(message)]).serialized()

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.resolve(requestId, .failure(DaemonConnectionError.timeout(type)))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pending[requestId] = cont
            Task {
                do { try await channel.send(.text(text)) }
                catch { self.resolve(requestId, .failure(error)) }
            }
        }
    }

    /// Sends a session message that has no response.
    public func send(_ type: String, _ params: [String: JSONValue] = [:]) async throws {
        var message = params
        message["type"] = .string(type)
        try await channel.send(.text(JSONValue.object(["type": "session", "message": .object(message)]).serialized()))
    }

    /// Sends an already-serialized top-level message.
    public func sendRaw(_ text: String) async throws {
        if let closedReason { throw DaemonConnectionError.closed(closedReason) }
        try await channel.send(.text(text))
    }

    public func close() async {
        await shutdown("closed by client")
        await channel.close(code: 1000, reason: "")
    }

    public var isClosed: Bool { closedReason != nil }

    private func resolve(_ requestId: String, _ result: Result<JSONValue, Error>) {
        updateHandlers[requestId] = nil
        pending.removeValue(forKey: requestId)?.resume(with: result)
    }

    // MARK: Loops

    private func runReadLoop() async {
        while true {
            let frame: WireFrame
            do { frame = try await channel.receive() } catch {
                await shutdown("\(error)")
                return
            }
            // Any valid inbound message proves liveness.
            inboundRevision += 1
            pongWaiters.values.forEach { $0.resume(returning: true) }
            pongWaiters.removeAll()
            if case .binary(let data) = frame {
                binaryHandler?(data)
                continue
            }
            guard case .text(let text) = frame, let m = try? JSONValue.parse(text) else { continue }
            guard m["type"]?.stringValue == "session", let inner = m["message"], let type = inner["type"]?.stringValue else { continue }
            if type.hasSuffix(".update"), let requestId = inner["payload"]?["requestId"]?.stringValue, let handler = updateHandlers[requestId] {
                handler(inner)
                continue
            }
            let isResponse = type == "rpc_error" || type.hasSuffix("_response") || type.hasSuffix(".response") || type.hasSuffix("/response")
            if isResponse, let requestId = inner["payload"]?["requestId"]?.stringValue, pending[requestId] != nil {
                if type == "rpc_error" {
                    let p = inner["payload"]
                    resolve(requestId, .failure(DaemonConnectionError.rpc(
                        requestType: p?["requestType"]?.stringValue ?? "request",
                        code: p?["code"]?.stringValue,
                        message: p?["error"]?.stringValue ?? "unknown error")))
                } else {
                    resolve(requestId, .success(inner))
                }
                continue
            }
            if type == "pong", let requestId = inner["payload"]?["requestId"]?.stringValue, pending[requestId] != nil {
                resolve(requestId, .success(inner))
                continue
            }
            eventSink.yield(inner)
        }
    }

    /// App-level `{"type":"ping"}` every 10 s after server_info; two missed 15 s windows close the connection.
    private func runPingLoop() async {
        var failures = 0
        while !Task.isCancelled, closedReason == nil {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, closedReason == nil else { return }
            let alive = await probeLiveness()
            failures = alive ? 0 : failures + 1
            if failures >= 2 {
                await channel.close(code: 1001, reason: "Liveness check timed out")
                await shutdown("liveness check timed out")
                return
            }
        }
    }

    /// 超时取消必须唤醒 continuation，否则 task group 无法退出，自动重连也不会发生。
    func probeLiveness(timeout: Duration = .seconds(15)) async -> Bool {
        let revision = inboundRevision
        do { try await channel.send(.text(#"{"type":"ping"}"#)) }
        catch { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitForInbound(since: revision) }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func waitForInbound(since revision: Int) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || closedReason != nil { continuation.resume(returning: false) }
                else if inboundRevision != revision { continuation.resume(returning: true) }
                else { pongWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelPongWaiter(id) }
        }
    }

    private func cancelPongWaiter(_ id: UUID) {
        pongWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    /// 前台恢复用带 requestId 的往返确认旧连接仍可用；失败后交给 HostStore 原有循环重连。
    func validateOnForeground(timeout: Duration = .seconds(3)) async {
        do {
            let sent = (Date().timeIntervalSince1970 * 1000).rounded()
            _ = try await request("ping", ["clientSentAt": .number(sent)], timeout: timeout)
        } catch {
            guard !Task.isCancelled else { return }
            await close()
        }
    }

    private func shutdown(_ reason: String) async {
        guard closedReason == nil else { return }
        closedReason = reason
        pingLoop?.cancel()
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: DaemonConnectionError.closed(reason)) }
        pongWaiters.values.forEach { $0.resume(returning: false) }
        pongWaiters.removeAll()
        eventSink.finish()
    }
}

func withTimeout<T: Sendable>(
    _ timeout: Duration, _ what: String,
    _ body: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () async -> Void
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        while let result = try await group.next() {
            if let value = result { return value }
            await onTimeout()
            throw DaemonConnectionError.timeout(what)
        }
        throw DaemonConnectionError.timeout(what)
    }
}
