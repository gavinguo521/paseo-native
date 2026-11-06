import UIKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct MobileFeatureTests {
    @Test func overviewDetailsAndTableUseNativeDeviceLayout() async throws {
        let model = try SidebarTestFixture.model(projects: 2)
        let host = try #require(model.hosts.first)
        host.agents["needs-input"] = try #require(Agent(["id": "needs-input", "cwd": "/test/mobile", "title": "等待确认文件读取", "status": "running", "pendingPermissions": [["id": "p", "kind": "tool", "title": "读取配置文件"]]]))
        var timeline = AgentTimeline()
        timeline.applyPage(["direction": "tail", "epoch": "e", "entries": [["seqStart": 0, "seqEnd": 0,
            "item": ["type": "tool_call", "callId": "shell", "name": "shell", "status": "completed", "detail": ["type": "shell", "command": "swift test", "output": "测试开始\n编译通过\n所有测试通过"]]]]])
        let row = try #require(timeline.rows.first)
        try await capture(NavigationStack { SessionOverview() }.environment(model), name: "overview")
        try await capture(ToolDetailsPanel(rows: timeline.rows, selectedID: .constant(row.id)), name: "details")
        try await capture(ScrollView { MarkdownView(text: "## 测试结果\n\n| 项目 | 状态 | 数量 |\n| --- | --- | ---: |\n| 会话总览 | 通过 | 8 |\n| 表格复制 | 通过 | 2 |").padding() }, name: "table")
    }

    private func capture<V: View>(_ content: V, name: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller = UIHostingController(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        #expect(controller.view.bounds.width == window.bounds.width)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { controller.view.layer.render(in: $0.cgContext) }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feature-\(name)-\(device).png")
        try #require(image.pngData()).write(to: url)
        print("FEATURE_SCREENSHOT \(url.path)")
    }
}
