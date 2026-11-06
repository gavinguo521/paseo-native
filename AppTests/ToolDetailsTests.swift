import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@MainActor struct ToolDetailsTests {
    @Test func navigationAndFullOutputSurviveReplacement() throws {
        var timeline = AgentTimeline()
        let output = String(repeating: "long log\n", count: 1200) + "FINAL MARKER"
        timeline.applyPage(["direction": "tail", "epoch": "e", "entries": [
            ["seqStart": 0, "seqEnd": 0, "item": ["type": "reasoning", "text": "分析"]],
            ["seqStart": 1, "seqEnd": 1, "item": ["type": "tool_call", "callId": "tool", "name": "shell", "status": "completed", "detail": ["type": "shell", "command": "test", "output": .string(output)]]]
        ]])
        let rows = ToolDetailsSelection.rows(timeline.rows)
        #expect(rows.count == 2)
        let row = try #require(rows.last)
        #expect(ToolDetailsSelection.text(row).contains("FINAL MARKER"))
        #expect(ToolDetailsSelection.text(row).contains(output))
        #expect(ToolDetailsSelection.neighbor(rows[0].id, in: rows, offset: 1) == row.id)
        #expect(ToolDetailsSelection.neighbor(row.id, in: rows, offset: 1) == nil)
        #expect(ToolDetailsSelection.neighbor("missing", in: rows, offset: -1) == nil)
    }
}

@MainActor private final class DetailsTestSelection: ObservableObject {
    @Published var id: String?
}

@MainActor private struct DetailsTestHost: View {
    @ObservedObject var selection: DetailsTestSelection
    let rows: [TimelineRow]
    var body: some View {
        ScrollView {
            Text("会话正文").frame(maxWidth: .infinity, minHeight: 500)
        }
        .modifier(ToolDetailsPresenter(rows: rows, selectedID: $selection.id))
    }
}

@Suite(.serialized) @MainActor struct ToolDetailsLayoutTests {
    @Test(arguments: [760, 960]) func openAndClosePresenter(width: Int) async throws {
        var timeline = AgentTimeline()
        timeline.applyPage(["direction": "tail", "epoch": "e", "entries": [
            ["seqStart": 0, "seqEnd": 0, "item": ["type": "reasoning", "text": "详情内容"]]
        ]])
        let row = try #require(timeline.rows.first)
        let selection = DetailsTestSelection()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: DetailsTestHost(selection: selection, rows: timeline.rows))
        view.sizingOptions = []
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 620)
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        for _ in 0..<3 {
            selection.id = row.id
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            view.layoutSubtreeIfNeeded()
            #expect(selection.id == row.id)
            #expect(view.frame.width == CGFloat(width))
            selection.id = nil
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
}
