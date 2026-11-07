import Foundation
import Testing
@testable import PaseoKit

@Suite(.timeLimit(.minutes(1))) @MainActor struct BackgroundWorkTests {
    private let item: JSONValue = ["id": "one", "kind": "shell", "description": "测试命令", "command": "sleep 30",
                                   "startedAt": "2026-11-07T00:00:00Z", "canStop": true, "stopToken": "token-one"]

    private func fixture() async throws -> (HostStore, RecoveryTransport, DaemonConnection) {
        let transport = RecoveryTransport()
        let connection = DaemonConnection(channel: transport)
        try await connection.handshake(hello: HelloOptions(clientId: "test"), expectedServerId: "test")
        let host = HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "测试", clientId: "test", appVersion: "test")
        host.connection = connection
        host.serverInfo = ServerInfo(raw: ["features": ["agentBackgroundWork": true, "agentBackgroundWorkStop": true]])
        return (host, transport, connection)
    }

    @Test func pushWinsAgainstEarlierListReply() async throws {
        let (host, transport, connection) = try await fixture()
        let load = Task { await host.refreshBackgroundWork("agent") }
        let request = try #require(await transport.nextSent("agent.background_work.list.request"))
        host.receiveBackgroundWork(["agentId": "agent", "items": [item]])
        await transport.reply(to: request, type: "agent.background_work.list.response", payload: ["agentId": "agent", "items": []])
        await load.value
        #expect(host.backgroundWork["agent"]?.map(\.id) == ["one"])
        #expect(!host.backgroundWorkLoading.contains("agent"))
        await connection.close()
    }

    @Test func failedListIsNotAnEmptyInventoryAndRetryRecovers() async throws {
        let (host, transport, connection) = try await fixture()
        host.receiveBackgroundWork(["agentId": "agent", "items": [item]])
        let failed = Task { await host.refreshBackgroundWork("agent") }
        let request = try #require(await transport.nextSent("agent.background_work.list.request"))
        await transport.reply(to: request, type: "agent.background_work.list.response", payload: ["error": "不可用", "items": []])
        await failed.value
        #expect(host.backgroundWorkErrors["agent"] != nil)
        #expect(host.backgroundWork["agent"]?.count == 1)
        let retry = Task { await host.refreshBackgroundWork("agent") }
        let next = try #require(await transport.nextSent("agent.background_work.list.request"))
        await transport.reply(to: next, type: "agent.background_work.list.response", payload: ["items": []])
        await retry.value
        #expect(host.backgroundWorkErrors["agent"] == nil)
        #expect(host.backgroundWork["agent"]?.isEmpty == true)
        await connection.close()
    }

    @Test func stopUsesServerTokenAndKeepsItemsUntilConfirmation() async throws {
        let (host, transport, connection) = try await fixture()
        let sibling: JSONValue = ["id": "two", "kind": "monitor", "startedAt": "2026-11-07T00:00:00Z"]
        host.receiveBackgroundWork(["agentId": "agent", "items": [item, sibling]])
        let work = try #require(AgentBackgroundWork(item))
        let stop = Task { try await host.stopBackgroundWork(work, agentId: "agent") }
        let request = try #require(await transport.nextSent("agent.background_work.stop.request"))
        #expect(request["itemId"]?.stringValue == "one")
        #expect(request["stopToken"]?.stringValue == "token-one")
        #expect(host.backgroundWork["agent"]?.count == 2)
        await transport.reply(to: request, type: "agent.background_work.stop.response")
        let list = try #require(await transport.nextSent("agent.background_work.list.request"))
        await transport.reply(to: list, type: "agent.background_work.list.response", payload: ["items": [sibling]])
        try await stop.value
        #expect(host.backgroundWork["agent"]?.map(\.id) == ["two"])
        await connection.close()
    }

    @Test func oldDaemonDoesNotEnableNewOperations() async throws {
        let (host, _, connection) = try await fixture()
        host.serverInfo = ServerInfo(raw: ["features": [:]])
        #expect(!host.supportsBackgroundWork && !host.supportsBackgroundWorkStop)
        await host.refreshBackgroundWork("agent")
        #expect(host.backgroundWork.isEmpty && host.backgroundWorkErrors.isEmpty)
        await #expect(throws: HostStore.ActionError.self) {
            try await host.stopBackgroundWork(try #require(AgentBackgroundWork(item)), agentId: "agent")
        }
        await connection.close()
    }

    @Test func reconnectResetRejectsOldReply() async throws {
        let (host, transport, connection) = try await fixture()
        let oldLoad = Task { await host.refreshBackgroundWork("agent") }
        let oldRequest = try #require(await transport.nextSent("agent.background_work.list.request"))
        host.resetBackgroundWork()
        host.receiveBackgroundWork(["agentId": "agent", "items": []])
        await transport.reply(to: oldRequest, type: "agent.background_work.list.response", payload: ["items": [item]])
        await oldLoad.value
        #expect(host.backgroundWork["agent"]?.isEmpty == true)
        await connection.close()
    }

    @Test func backgroundCountPreservesPermissionAndErrorPriority() throws {
        let running = try #require(Agent(["id": "a", "status": "idle", "backgroundWork": ["count": 1]]))
        let error = try #require(Agent(["id": "b", "status": "error", "backgroundWork": ["count": 1]]))
        let permission = try #require(Agent(["id": "c", "status": "idle", "attentionReason": "permission", "backgroundWork": ["count": 1]]))
        #expect(running.bucket == .running)
        #expect(error.bucket == .failed)
        #expect(permission.bucket == .needsInput)
    }
}
