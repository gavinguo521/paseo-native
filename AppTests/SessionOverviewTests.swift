import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct SessionOverviewTests {
    private func sample() throws -> AppModel {
        let hosts = (0..<2).map { HostStore(offer: .direct(serverId: "host-\($0)", endpoint: "localhost:1", useTls: false, password: nil), label: "测试机器 \($0)", clientId: "test", appVersion: "test") }
        for (index, host) in hosts.enumerated() {
            for (i, state) in ["running", "idle", "error", "initializing"].enumerated() {
                host.agents["agent-\(i)"] = try #require(Agent(["id": .string("agent-\(i)"), "title": .string(["梳理项目体验优化", "检查表格复制", "检查失败的构建", "正在启动会话"][i]),
                    "provider": .string(index == 0 ? "codex" : "claude"), "cwd": "/test/project", "status": .string(state)]))
            }
        }
        return AppModel(testHosts: hosts)
    }

    @Test func crossHostIdentityAndFilters() throws {
        let model = try sample()
        let all = model.overviewEntries(hostID: nil, provider: nil, query: "")
        #expect(all.count == 8)
        #expect(Set(all.map(\.id)).count == 8)
        #expect(all.filter { OverviewLane.of($0.agent) == .running }.count == 4)
        #expect(model.overviewEntries(hostID: "host-0", provider: "claude", query: "").isEmpty)
        #expect(model.overviewEntries(hostID: nil, provider: "codex", query: "表格").count == 1)
        let permission = try #require(Agent(["id": "permission", "status": "running", "pendingPermissions": [["id": "p", "kind": "tool"]]]))
        #expect(OverviewLane.of(permission) == .input)
    }

    @Test func renderOverviewAtPhoneAndDesktopWidths() throws {
        let model = try sample()
        for width in [390, 1200] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = NSHostingView(rootView: SessionOverview().environment(model).environment(\.colorScheme, .light))
            view.sizingOptions = []
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 740)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/paseo-overview-\(width).png"))
        }
    }
}
