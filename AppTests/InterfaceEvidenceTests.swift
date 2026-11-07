import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct InterfaceEvidenceTests {
    @Test func detailsAndTableRenderAtReadableWidths() async throws {
        var timeline = AgentTimeline()
        timeline.applyPage(["direction": "tail", "epoch": "e", "entries": [["seqStart": 0, "seqEnd": 0,
            "item": ["type": "tool_call", "callId": "diff", "name": "edit", "status": "completed",
                     "detail": ["type": "edit", "filePath": "App/Sources/Sidebar.swift", "unifiedDiff": "@@ -1,2 +1,3 @@\n-oldOrder()\n+manualOrder()\n+showUnreadBadge()"]]]]])
        let row = try #require(timeline.rows.first)
        for width in [390, 960] {
            try await capture(ToolDetailsPanel(rows: timeline.rows, selectedID: .constant(row.id)), width: width, name: "details")
            try await capture(ScrollView { MarkdownView(text: "## 项目运行汇总\n\n| 项目 | 状态 | 用时 |\n| --- | --- | ---: |\n| 原生客户端 | 已完成 | 32 秒 |\n| 服务端 | 等待确认 | 18 秒 |\n\n双击单元格，或长按拖动选择一块区域。").padding(16) }, width: width, name: "table")
        }
    }

    @Test func suggestionPlaceholderRendersOnMac() async throws {
        try await capture(MacSuggestionComposerFixture(), width: 720, name: "suggestion-composer")
    }

    private func capture<V: View>(_ content: V, width: Int, name: String) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        view.sizingOptions = []
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: 620)
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/paseo-\(name)-\(width).png"))
    }
}

private struct MacSuggestionComposerFixture: View {
    @State private var text = ""
    @State private var images: [ImageAttachment] = []
    @State private var placeholder = "发送消息"
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            Spacer()
            ComposerShell(text: $text, images: $images, focused: $focused, error: nil, placeholder: placeholder) {
                EmptyView()
            } controls: { Text("模型") } trailing: { Image(systemName: "paperplane.fill") } onSubmit: {}
        }.padding()
        .task { placeholder = "请继续检查输入栏的显示效果，并确认 iPhone、iPad 和 Mac 上都能看到下一句建议。　（Tab 采用）" }
    }
}
