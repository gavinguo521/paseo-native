import Testing
@testable import PaseoKit
@testable import Paseo

@MainActor struct SidebarUnreadTests {
    @Test func unseenTabsAreCountedWithoutChangingManualOrder() throws {
        let host = HostStore(offer: .direct(serverId: "unread-test", endpoint: "localhost:1", useTls: false, password: nil), label: "test", clientId: "test", appVersion: "test")
        func agent(_ id: String, project: String, unread: Bool, reason: String = "completed") throws -> Agent {
            try #require(Agent(["id": .string(id), "workspaceId": .string(project), "cwd": .string("/test/" + project), "status": "idle", "requiresAttention": .bool(unread), "attentionReason": .string(reason)]))
        }
        host.agents["a"] = try agent("a", project: "A", unread: false)
        host.agents["b"] = try agent("b", project: "B", unread: false)
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil; model.grouping = .project; model.sort = .manual
        model.projectAliases = [:]; model.workspaceOrder = [:]; model.projectOrder = ["project:A", "project:B"]
        model.destination = .agent(AgentRef(serverId: host.id, agentId: "b"))
        host.agents["b2"] = try agent("b2", project: "B", unread: true)
        host.agents["permission"] = try agent("permission", project: "B", unread: true, reason: "permission")
        let groups = model.groups
        #expect(groups.map(\.id) == ["project:A", "project:B"])
        #expect(groups[1].rows[0].agent.id == "b")
        let unread = AppModel.unread(in: groups[1], index: model.sidebarUnreadIndex())
        #expect(unread == [AgentRef(serverId: host.id, agentId: "b2")])
        model.open(unread[0])
        #expect(model.destination == .agent(unread[0]))
        #expect(model.sort == .manual)
        #expect(model.groups.map(\.id) == ["project:A", "project:B"])
        host.agents["b2"] = try agent("b2", project: "B", unread: false)
        #expect(AppModel.unread(in: model.groups[1], index: model.sidebarUnreadIndex()).isEmpty)
    }
}
