import Foundation
import Testing
@testable import PaseoKit

@Suite(.timeLimit(.minutes(1))) @MainActor struct BarkNotificationTests {
    @Test func readsExecutionHostWithoutOpeningSettingsAndRefreshesAfterAnotherClientChangesIt() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        #expect(await host.barkHandlesCompletions())
        await transport.setStatus(["configured": true, "notifyOnFinish": false])
        #expect(await host.barkHandlesCompletions() == false)
        await transport.setStatus(["configured": true, "notifyOnFinish": true])
        #expect(await host.barkHandlesCompletions())
        #expect(await transport.methods == ["bark.status", "bark.status", "bark.status"])
    }

    @Test func hostsHaveIndependentCompletionPreferences() async throws {
        let (first, firstTransport) = try await connected(id: "first")
        let (second, secondTransport) = try await connected(id: "second")
        defer { first.stop(); second.stop() }
        await secondTransport.setStatus(["configured": true, "notifyOnFinish": false])
        #expect(await first.barkHandlesCompletions())
        #expect(await second.barkHandlesCompletions() == false)
        await firstTransport.failRequests()
        #expect(await first.barkHandlesCompletions())
        #expect(second.barkCompletionEnabled == false)
    }

    @Test func unavailableOrLegacyPluginPreservesNativeNotifications() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        await transport.failRequests()
        #expect(await host.barkHandlesCompletions() == false)
        await transport.setStatus(["configured": true])
        #expect(await host.barkHandlesCompletions() == false)
        await transport.setStatus(["configured": false, "notifyOnFinish": true])
        #expect(await host.barkHandlesCompletions() == false)
    }

    @Test func lastConfirmedBarkPreferenceSurvivesTransientReadFailures() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        #expect(await host.barkHandlesCompletions())
        await transport.failRequests()
        #expect(await host.barkHandlesCompletions())
        await transport.setStatus(.null)
        #expect(await host.barkHandlesCompletions())
    }

    @Test func settingsChangesAndRemovalUpdateTheFallbackImmediately() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        for (method, status, expected) in [
            ("bark.preferences", JSONValue.object(["configured": true, "notifyOnFinish": true]), true),
            ("bark.preferences", JSONValue.object(["configured": true, "notifyOnFinish": false]), false),
            ("bark.configure", JSONValue.object(["configured": true, "notifyOnFinish": true]), true),
            ("bark.clear", JSONValue.object(["configured": false, "notifyOnFinish": false]), false)
        ] {
            await transport.setStatus(status)
            _ = try await host.invokePlugin("live-activity", method, [:])
            await transport.failRequests()
            #expect(await host.barkHandlesCompletions() == expected)
        }
    }

    @Test func disabledOrRemovedPluginRestoresNativePathWithoutAStatusRequest() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        #expect(await host.barkHandlesCompletions())
        await transport.removePlugin()
        await host.loadPlugins()
        #expect(await host.barkHandlesCompletions() == false)
        #expect(await transport.methods == ["bark.status"])
    }

    @Test func lateReadCannotUndoAConfirmedSettingsChange() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        await transport.holdNextStatus()
        let read = Task { await host.barkHandlesCompletions() }
        await transport.waitForHeldStatus()
        await transport.setStatus(["configured": true, "notifyOnFinish": false])
        _ = try await host.invokePlugin("live-activity", "bark.preferences", ["notifyOnFinish": false])
        await transport.releaseStatus()
        #expect(await read.value == false)
        #expect(host.barkCompletionEnabled == false)
    }

    @Test func oldSocketResponseCannotReplaceReconnectedHostsPreference() async throws {
        let (host, transport) = try await connected()
        defer { host.stop() }
        let oldConnection = try #require(host.connection)
        await transport.holdNextStatus()
        let read = Task { await host.barkHandlesCompletions() }
        await transport.waitForHeldStatus()

        let (replacement, nextTransport) = try await connected()
        defer { replacement.stop() }
        host.connection = replacement.connection
        await nextTransport.setStatus(["configured": true, "notifyOnFinish": false])
        #expect(await host.barkHandlesCompletions() == false)
        await transport.releaseStatus()
        #expect(await read.value == false)
        #expect(host.barkCompletionEnabled == false)
        await oldConnection.close()
    }

    private func connected(id: String = "test") async throws -> (HostStore, BarkStatusTransport) {
        let transport = BarkStatusTransport(serverId: id)
        let connection = DaemonConnection(channel: transport)
        try await connection.handshake(hello: HelloOptions(clientId: "test"), expectedServerId: id)
        let host = HostStore(offer: .direct(serverId: id, endpoint: "localhost:1", useTls: false, password: nil),
                             label: id, clientId: "test", appVersion: "test")
        host.connection = connection
        await host.loadPlugins()
        return (host, transport)
    }
}

/// Exercises the real plugin RPC path without contacting a host or sending pushes.
private actor BarkStatusTransport: FrameTransport {
    let serverId: String
    private var incoming: [WireFrame] = []
    private var receiver: CheckedContinuation<WireFrame, Error>?
    private var closed = false
    private var output: JSONValue = ["configured": true, "notifyOnFinish": true]
    private var failing = false
    private var installed = true
    private var holdStatus = false
    private var held: (JSONValue, JSONValue)?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private(set) var methods: [String] = []

    init(serverId: String) { self.serverId = serverId }
    func setStatus(_ value: JSONValue) { output = value; failing = false }
    func failRequests() { failing = true }
    func removePlugin() { installed = false }
    func holdNextStatus() { holdStatus = true }
    func waitForHeldStatus() async {
        if held != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func releaseStatus() {
        guard let (request, value) = held else { return }
        held = nil
        reply(request, output: value)
    }

    func send(_ frame: WireFrame) async throws {
        guard !closed else { throw TransportClosed(code: 1000, reason: "test closed") }
        guard case .text(let text) = frame else { return }
        let message = try JSONValue.parse(text)
        if message["type"]?.stringValue == "hello" {
            deliver(["type": "status", "payload": ["status": "server_info", "serverId": .string(serverId)]])
            return
        }
        let request = message["message"] ?? message
        if request["type"]?.stringValue == "plugin.list.request" {
            let plugins: JSONValue = installed ? [["id": "live-activity", "enabled": true, "status": "running"]] : []
            deliver(["type": "plugin.list.response", "payload": ["requestId": request["requestId"] ?? .null, "plugins": plugins]])
            return
        }
        guard request["type"]?.stringValue == "plugin.rpc.invoke.request" else { return }
        #expect(request["pluginId"]?.stringValue == "live-activity")
        let method = request["method"]?.stringValue ?? ""
        methods.append(method)
        if method == "bark.status", holdStatus {
            holdStatus = false
            held = (request, output)
            heldWaiter?.resume()
            heldWaiter = nil
        } else if failing {
            deliver(["type": "rpc_error", "payload": ["requestId": request["requestId"] ?? .null, "error": "test unavailable"]])
        } else {
            reply(request, output: output)
        }
    }

    private func reply(_ request: JSONValue, output: JSONValue) {
        deliver(["type": "plugin.rpc.invoke.response", "payload": ["requestId": request["requestId"] ?? .null, "output": output]])
    }

    private func deliver(_ message: JSONValue) {
        let frame = WireFrame.text(try! JSONValue.object(["type": "session", "message": message]).serialized())
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { incoming.append(frame) }
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
    }
}
