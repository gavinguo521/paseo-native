import Foundation
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct SidebarOrderingTests {
    /// 测试跑在 App 进程里，写设置不能落到本机正式版（排序、手动顺序、项目合并）。
    @Test func testsUseSeparatePreferences() {
        #expect(AppDefaults.isTesting)
        #expect(AppDefaults.store !== UserDefaults.standard)
    }

    private func agent(_ id: String, project: String, time: Int) throws -> Agent {
        try #require(Agent(["id": .string(id), "workspaceId": .string(id),
            "cwd": .string("/test/" + project), "status": "idle",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": .string("2026-01-01T00:00:\(String(format: "%02d", time))Z"),
            "lastUserMessageAt": .string("2026-01-01T00:00:\(String(format: "%02d", time))Z")]))
    }

    @Test func projectDragSwitchesToManualUntilUserChoosesActivity() throws {
        let host = HostStore(offer: .direct(serverId: "ordering-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "排序测试", clientId: "test", appVersion: "test")
        host.agents["a"] = try agent("a", project: "A", time: 20)
        host.agents["b"] = try agent("b", project: "B", time: 10)
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil
        model.grouping = .project
        model.projectAliases = [:]
        model.projectOrder = []
        model.workspaceOrder = [:]
        model.sort = .updated
        model.moveProject("project:B", to: "project:A")
        #expect(model.sort == .manual)
        #expect(AppDefaults.store.string(forKey: "sidebarSort") == SidebarSort.manual.rawValue)
        let expected = ["project:B", "project:A"]
        #expect(model.groups.map(\.id) == expected)
        // 与 agent_update 一样替换同一个会话对象；手动模式不能被新消息打乱。
        host.agents["a"] = try agent("a", project: "A", time: 30)
        #expect(model.groups.map(\.id) == expected)
        // 用户主动选回最近活动，才恢复自动排序。
        model.sort = .updated
        host.agents["a"] = try agent("a", project: "A", time: 40)
        #expect(model.groups.map(\.id) == ["project:A", "project:B"])
        host.agents["b2"] = try agent("b2", project: "B", time: 50)
        #expect(model.groups.map(\.id) == expected)
        #expect(model.groups[0].rows.map(\.agent.id) == ["b2", "b"])
    }

    @Test func workspaceDragAlsoSwitchesToManualAndPersistsMode() throws {
        let host = HostStore(offer: .direct(serverId: "ordering-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "排序测试", clientId: "test", appVersion: "test")
        host.agents["a"] = try agent("a", project: "A", time: 20)
        host.agents["b"] = try agent("b", project: "A", time: 10)
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil
        model.grouping = .project
        model.projectAliases = [:]
        model.projectOrder = []
        model.workspaceOrder = [:]
        model.sort = .updated
        model.moveWorkspace("ordering-test:b", to: "ordering-test:a", inGroup: "project:A")
        #expect(model.sort == .manual)
        #expect(AppDefaults.store.string(forKey: "sidebarSort") == SidebarSort.manual.rawValue)
        #expect(model.groups[0].rows.map(\.agent.id) == ["b", "a"])
        host.agents["a"] = try agent("a", project: "A", time: 40)
        #expect(model.groups[0].rows.map(\.agent.id) == ["b", "a"])
    }
    @Test func newWorkspaceStaysAfterManuallyPlacedRows() throws {
        let host = HostStore(offer: .direct(serverId: "ordering-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "排序测试", clientId: "test", appVersion: "test")
        host.agents["a"] = try agent("a", project: "A", time: 20)
        host.agents["b"] = try agent("b", project: "B", time: 10)
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil; model.grouping = .project; model.projectAliases = [:]
        model.projectOrder = []; model.workspaceOrder = [:]; model.sort = .updated
        model.moveProject("project:B", to: "project:A")
        host.agents["a2"] = try agent("a2", project: "A", time: 40)
        host.agents["c"] = try agent("c", project: "C", time: 50)
        #expect(model.groups.map(\.id) == ["project:B", "project:A", "project:C"])
        #expect(model.groups.first { $0.id == "project:A" }?.rows.map(\.agent.id) == ["a", "a2"])
        model.rememberManualOrder(model.groups)
        host.agents["a3"] = try agent("a3", project: "A", time: 55)
        host.agents["d"] = try agent("d", project: "D", time: 56)
        #expect(model.groups.map(\.id) == ["project:B", "project:A", "project:C", "project:D"])
        #expect(model.groups.first { $0.id == "project:A" }?.rows.map(\.agent.id) == ["a", "a2", "a3"])
        model.rememberManualOrder(model.groups)
        // 新出现的位置也保存下来，重建模型后不退回创建时间排序。
        let restored = AppModel(testHosts: [host])
        restored.hostFilter = nil; restored.grouping = .project; restored.projectAliases = [:]; restored.sort = .manual
        #expect(restored.groups.map(\.id) == model.groups.map(\.id))
        #expect(restored.groups.first { $0.id == "project:A" }?.rows.map(\.agent.id) == ["a", "a2", "a3"])
    }

    @Test func selectingManualFromMenuFreezesCurrentOrder() throws {
        let host = HostStore(offer: .direct(serverId: "ordering-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "排序测试", clientId: "test", appVersion: "test")
        host.agents["a"] = try agent("a", project: "A", time: 20)
        host.agents["b"] = try agent("b", project: "B", time: 10)
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil; model.grouping = .project; model.projectAliases = [:]
        model.projectOrder = []; model.workspaceOrder = [:]; model.sort = .updated
        let original = model.groups.map(\.id)
        model.selectSort(.manual)
        #expect(model.projectOrder == original)
        host.agents["b2"] = try agent("b2", project: "B", time: 50)
        #expect(model.groups.map(\.id) == original)
        #expect(model.groups.first { $0.id == "project:B" }?.rows.map(\.agent.id) == ["b", "b2"])
        model.search = "b2"
        model.rememberManualOrder(model.groups)
        model.search = ""
        #expect(model.groups.map(\.id) == original)
        #expect(model.groups.first { $0.id == "project:B" }?.rows.map(\.agent.id) == ["b", "b2"])
    }

}
