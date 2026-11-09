import Foundation
import Testing
@testable import PaseoKit
@testable import Paseo
#if os(iOS)
import PaseoWatchBridge
#endif

@Suite(.serialized) @MainActor struct ScheduledSidebarTests {
    private func agent(_ id: String, workspace: String, time: Int = 10, status: String = "idle",
                       labels: [String: JSONValue] = [:], unread: Bool = false, archived: Bool = false) throws -> Agent {
        try #require(Agent([
            "id": .string(id), "title": .string(id), "workspaceId": .string(workspace),
            "cwd": .string("/test/" + workspace), "status": .string(status), "labels": .object(labels),
            "createdAt": "2026-01-01T00:00:00Z",
            "lastUserMessageAt": .string("2026-01-01T00:00:\(String(format: "%02d", time))Z"),
            "requiresAttention": .bool(unread),
            "archivedAt": archived ? "2026-01-01T00:01:00Z" : .null
        ]))
    }

    private func fixture() -> (AppModel, HostStore) {
        let host = HostStore(offer: .direct(serverId: "scheduled-sidebar-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "test", clientId: "test", appVersion: "test")
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil; model.grouping = .project; model.sort = .updated
        model.search = ""; model.labelFilter = []; model.projectAliases = [:]
        model.projectOrder = []; model.workspaceOrder = [:]
        return (model, host)
    }

    @Test func scheduledRunsNeverEnterSidebarDuringTheirLifecycle() throws {
        let (model, host) = fixture()
        host.agents["chat"] = try agent("chat", workspace: "project")
        model.selectSort(.manual)
        for marker in ["paseo.schedule-id", "paseo.schedule-run"] {
            for state in ["initializing", "running", "idle", "error"] {
                host.agents["scheduled"] = try agent("scheduled", workspace: "scheduled-workspace", time: 50,
                                                     status: state, labels: [marker: "schedule-run"], unread: true)
                model.rememberManualOrder(model.groups)
                #expect(model.groups.flatMap(\.agents).map(\.id) == ["chat"])
                #expect(model.sidebarSessionIndex().values.flatMap { $0 }.map(\.id) == ["chat"])
                #expect(model.sidebarUnreadIndex().isEmpty)
                #expect(model.projectOrder == ["project:project"])
                #expect(model.workspaceOrder["project:scheduled-workspace"] == nil)
            }
        }
        host.agents["scheduled"] = try agent("scheduled", workspace: "scheduled-workspace", labels: ["paseo.schedule-id": "schedule"], archived: true)
        #expect(model.groups.flatMap(\.agents).map(\.id) == ["chat"])
        host.agents["scheduled"] = nil
        #expect(model.groups.flatMap(\.agents).map(\.id) == ["chat"])
    }

    @Test func scheduledRunSharingAWorkspaceDoesNotChangeItsRowOrUnreadState() throws {
        let (model, host) = fixture()
        host.agents["older"] = try agent("older", workspace: "A", time: 10)
        host.agents["newer"] = try agent("newer", workspace: "B", time: 20)
        let run = try agent("scheduled", workspace: "A", time: 50, status: "running",
                            labels: ["paseo.schedule-id": "schedule", "paseo.schedule-run": "run"], unread: true)
        host.agents[run.id] = run
        let ref = AgentRef(serverId: host.id, agentId: run.id)
        // Explicitly opening the run from its schedule must not promote it into the sidebar.
        model.destination = .agent(ref)
        #expect(model.agent(ref)?.id == run.id)
        #expect(model.groups.map(\.id) == ["project:B", "project:A"])
        #expect(model.groups.flatMap(\.agents).map(\.id) == ["newer", "older"])
        #expect(model.groups.flatMap(\.rows).allSatisfy { $0.bucket == .done })
        #expect(model.sidebarSessionIndex()[host.id + "|A"]?.map(\.id) == ["older"])
        #expect(model.sidebarUnreadIndex().isEmpty)

        model.search = "scheduled"
        #expect(model.groups.isEmpty)
        model.search = ""
        model.grouping = .status
        #expect(model.groups.map(\.id) == ["status:done"])

        host.agents[run.id] = try agent("scheduled", workspace: "A", time: 50,
                                      labels: ["paseo.schedule-id": "schedule"], unread: true)
        #expect(model.sidebarUnreadIndex().isEmpty)
    }

    @Test func ordinarySessionsIncludingHeartbeatTargetsRemainVisible() throws {
        let (model, host) = fixture()
        // A schedule targeting an existing chat does not add the schedule-run labels to that chat.
        host.agents["定时任务讨论"] = try agent("定时任务讨论", workspace: "A", status: "running", labels: ["custom": "schedule"])
        host.agents["child"] = try agent("child", workspace: "A", status: "running", labels: ["paseo.parent-agent-id": "定时任务讨论"])
        host.agents["unread"] = try agent("unread", workspace: "B", unread: true)
        #expect(Set(model.groups.flatMap(\.agents).map(\.id)) == ["定时任务讨论", "unread"])
        #expect(model.groups.first { $0.id == "project:A" }?.rows.first?.bucket == .running)
        #expect(model.sidebarSessionIndex()[host.id + "|A"]?.map(\.id) == ["定时任务讨论"])
        #expect(model.sidebarUnreadIndex().values.flatMap { $0 } == [AgentRef(serverId: host.id, agentId: "unread")])
    }

    #if os(iOS)
    @Test func watchSnapshotsAndRefreshesExcludeRunsAndReplaceCachedRows() throws {
        let (_, host) = fixture()
        let chat = try agent("chat", workspace: "A")
        let heartbeat = try agent("heartbeat", workspace: "B", status: "running")
        host.agents[chat.id] = chat
        host.agents[heartbeat.id] = heartbeat
        host.agents["archived"] = try agent("archived", workspace: "A", archived: true)
        host.agents["child"] = try agent("child", workspace: "A", labels: ["paseo.parent-agent-id": .string(chat.id)])
        for state in ["initializing", "running", "idle", "error"] {
            host.agents["scheduled"] = try agent("scheduled", workspace: "A", status: state, labels: ["paseo.schedule-id": "schedule"])
            let passive = WatchCompanion.sessionSummaries(host.agents.values, host: host)
            let refreshed = WatchCompanion.sessionSummaries(Array(host.agents.values), host: host)
            #expect(passive == refreshed)
            #expect(refreshed.map(\.ref.agentID) == ["heartbeat", "chat"])

            var cached = WatchOverview(pages: [WatchSessionPage(hostID: host.id, refreshedAt: Date(timeIntervalSince1970: 1), sessions: [
                WatchSessionSummary(ref: .init(hostID: host.id, agentID: "scheduled"), title: "scheduled",
                                    hostName: host.label, status: .running, updatedAt: nil, startedAt: nil)
            ])])
            cached.merge(WatchSessionPage(hostID: host.id, refreshedAt: Date(timeIntervalSince1970: 2), sessions: refreshed))
            #expect(cached.sessions(hostID: host.id).map(\.ref.agentID) == ["heartbeat", "chat"])
        }
    }
    #endif
}
