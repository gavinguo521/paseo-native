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
