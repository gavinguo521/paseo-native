import Foundation
import UIKit
import Testing
import PaseoWatchBridge
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct EnergyWorkTests {
    @Test func summaryKeepsNestedStatusAndGroupedCounts() throws {
        let model = try SidebarTestFixture.model(projects: 1)
        let host = try #require(model.hosts.first)
        let parent = "p0-w0-s0"
        host.agents["child"] = try #require(Agent(["id": "child", "status": "running",
            "labels": ["paseo.parent-agent-id": .string(parent)]]))
        host.agents["grandchild"] = try #require(Agent(["id": "grandchild", "status": "idle",
            "attentionReason": "permission", "labels": ["paseo.parent-agent-id": "child"]]))
        host.agents["running"] = try #require(Agent(["id": "running", "workspaceId": "p0-w1", "status": "running"]))
        host.agents["archived"] = try #require(Agent(["id": "archived", "status": "running", "archivedAt": "2026-01-01T00:00:00Z"]))
        let state = LiveActivityController.snapshot(model)
        #expect(state.waiting == 1)
        #expect(state.running == 1)
        #expect(state.rows.count == 2)
        #expect(state.rows.first?.agentId == "grandchild")
        let children = Dictionary(grouping: host.agents.values.filter { $0.archivedAt == nil && $0.parentAgentId != nil }) { $0.parentAgentId! }
        for roots in Dictionary(grouping: host.agents.values.filter { $0.archivedAt == nil && !host.isNested($0) }, by: { $0.workspaceId ?? $0.id }).values {
            #expect(model.groupBucket(roots, in: host) == model.groupBucket(roots, in: host, children: children))
        }
    }

    @Test func runningRingStopsWhenDisabledAndDetached() async throws {
        let scene = try await layoutTestScene()
        let window = UIWindow(windowScene: scene)
        let view = SpinningRingView()
        window.addSubview(view)
        func spins() -> Bool { view.layer.sublayers?.contains { $0.animation(forKey: "spin") != nil } == true }
        #expect(spins())
        view.animating = false
        #expect(!spins())
        view.animating = true
        #expect(spins())
        view.removeFromSuperview()
        #expect(!spins())
    }

    @Test func watchOverviewSkipsDuplicatesButRetriesFailures() throws {
        var delivery = WatchOverviewDelivery()
        let first = WatchOverview(hosts: [.init(id: "host", name: "测试主机")])
        var sent = 0
        for _ in 0..<100 { delivery.send(first) { _ in sent += 1 } }
        #expect(sent == 1)
        let changed = WatchOverview(hosts: [.init(id: "host", name: "新名称")])
        enum Failure: Error { case offline }
        do { try delivery.send(changed) { _ in throw Failure.offline }; Issue.record("发送失败必须抛出") }
        catch Failure.offline {} catch { Issue.record("意外错误：\(error)") }
        delivery.send(changed) { _ in sent += 1 }
        #expect(sent == 2)
        delivery = WatchOverviewDelivery()
        delivery.send(changed) { _ in sent += 1 }
        #expect(sent == 3)
    }

    @Test func activitySummaryCost() throws {
        for count in [30, 100] {
            let model = try SidebarTestFixture.model(projects: count)
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for _ in 0..<10 {
                    let state = LiveActivityController.snapshot(model)
                    #expect(state.running == 0 && state.waiting == 0 && state.rows.isEmpty)
                }
            }
            print("ENERGY-SUMMARY projects=\(count) agents=\(count * 16) snapshots=10 elapsed=\(elapsed)")
        }
    }
}
