import Foundation
import Testing
@testable import PaseoKit

private func entry(_ seq: Int, _ item: JSONValue, turn: String = "t1", seqEnd: Int? = nil) -> JSONValue {
    ["turnId": .string(turn), "timestamp": "2026-11-03T03:12:09.000Z", "item": item,
     "seqStart": .number(Double(seq)), "seqEnd": .number(Double(seqEnd ?? seq))]
}

private func page(_ direction: String, _ entries: [JSONValue], start: Int, end: Int, epoch: String = "e1",
                  hasOlder: Bool = false, hasNewer: Bool = false, reset: Bool = false) -> JSONValue {
    ["direction": .string(direction), "epoch": .string(epoch), "reset": .bool(reset),
     "startCursor": ["epoch": .string(epoch), "seq": .number(Double(start))],
     "endCursor": ["epoch": .string(epoch), "seq": .number(Double(end))],
     "hasOlder": .bool(hasOlder), "hasNewer": .bool(hasNewer), "entries": .array(entries)]
}

private func stream(_ seq: Int?, _ item: JSONValue, epoch: String = "e1", turn: String = "t1") -> JSONValue {
    var p: [String: JSONValue] = ["agentId": "a1", "epoch": .string(epoch), "timestamp": "2026-11-03T03:12:10.000Z",
                                  "event": ["type": "timeline", "item": item, "turnId": .string(turn)]]
    if let seq { p["seq"] = .number(Double(seq)) }
    return .object(p)
}

private func text(_ row: TimelineRow) -> String {
    switch row.item {
    case .userMessage(let t, _), .assistantMessage(let t, _), .reasoning(let t): t
    case .toolCall(_, let name, let status, _, _, _): "\(name):\(status)"
    default: "?"
    }
}

@Suite struct AgentTimelineTests {
    func loaded() -> AgentTimeline {
        var t = AgentTimeline()
        t.applyPage(page("tail", [
            entry(1, ["type": "user_message", "text": "hi", "messageId": "m1"]),
            entry(2, ["type": "assistant_message", "text": "hello"]),
        ], start: 1, end: 2, hasOlder: true))
        return t
    }

    @Test func installsTail() {
        let t = loaded()
        #expect(t.rows.map(text) == ["hi", "hello"])
        #expect(t.endSeq == 2 && t.startSeq == 1 && t.hasOlder)
    }

    @Test func rowRevisionKeepsUnchangedHistoryAndInvalidatesReplacements() {
        var t = loaded()
        let before = t.rows.map(\.revision)
        _ = t.applyStream(stream(3, ["type": "assistant_message", "text": " world"]))
        #expect(t.rows[0].revision == before[0])
        #expect(t.rows[1].revision != before[1])
        let streamed = t.rows[1].revision
        t = loaded()
        #expect(t.rows[1].revision != streamed)
    }

    @Test func searchHistoryKeepsOlderRowsAndUsesLatestStreamedText() {
        var live = loaded()
        var history = live
        history.applyPage(page("before", [entry(0, ["type": "user_message", "text": "older", "messageId": "m0"])], start: 0, end: 0))
        _ = live.applyStream(stream(3, ["type": "assistant_message", "text": " world"]))
        let combined = history.includingLiveTail(live)
        #expect(combined.rows.map(text) == ["older", "hi", "hello world"])
        #expect(live.rows.map(text) == ["hi", "hello world"])
        #expect(history.rows.map(text) == ["older", "hi", "hello"])
        #expect(combined.window(around: "m1", radius: 0)?.rows.map(text) == ["hi"])
    }

    @Test func streamsAndMergesAssistantChunks() {
        var t = loaded()
        #expect(t.applyStream(stream(3, ["type": "assistant_message", "text": " world"])) == .applied)
        #expect(t.rows.map(text) == ["hi", "hello world"])
        #expect(t.applyStream(stream(3, ["type": "assistant_message", "text": " dup"])) == .stale)
        #expect(t.rows.last.map(text) == "hello world")
    }

    @Test func historyMergeDoesNotDuplicateCompletedBackgroundTool() {
        var live = loaded()
        var history = live
        history.applyPage(page("before", [entry(0, ["type": "tool_call", "callId": "background", "name": "Bash", "status": "running"])], start: 0, end: 0))
        _ = live.applyStream(stream(3, ["type": "tool_call", "callId": "background", "name": "Bash", "status": "completed"]))
        let merged = history.includingLiveTail(live)
        #expect(merged.rows.map(text) == ["hi", "hello", "Bash:completed"])
        #expect(Set(merged.rows.map(\.id)).count == merged.rows.count)
        #expect(history.rows.first.map(text) == "Bash:running")
    }

    @Test func detectsGapAndEpochChange() {
        var t = loaded()
        #expect(t.applyStream(stream(5, ["type": "assistant_message", "text": "x"])) == .gap)
        #expect(t.endSeq == 2)
        #expect(t.applyStream(stream(3, ["type": "assistant_message", "text": "x"], epoch: "e2")) == .epochChanged)
    }

    @Test func toolCallsUpsertInPlace() {
        var t = loaded()
        _ = t.applyStream(stream(3, ["type": "tool_call", "callId": "c1", "name": "Bash", "status": "running",
                                     "detail": ["type": "shell", "command": "ls"]]))
        _ = t.applyStream(stream(4, ["type": "assistant_message", "text": "running…", "messageId": "x2"]))
        _ = t.applyStream(stream(5, ["type": "tool_call", "callId": "c1", "name": "Bash", "status": "completed",
                                     "detail": ["type": "shell", "command": "ls", "output": "a\nb", "exitCode": 0]]))
        #expect(t.rows.map(text) == ["hi", "hello", "Bash:completed", "running…"])
    }

    @Test func reasoningStreamsUntilAnotherEvent() {
        var t = loaded()
        _ = t.applyStream(stream(3, ["type": "reasoning", "text": "think"]))
        _ = t.applyStream(stream(4, ["type": "reasoning", "text": "ing"]))
        #expect(t.rows.last.map(text) == "thinking")
        #expect(t.rows.last?.isStreaming == true)
        _ = t.applyStream(stream(5, ["type": "assistant_message", "text": "done"]))
        #expect(t.rows[t.rows.count - 2].isStreaming == false)
    }

    @Test func pendingUserMessageIsClaimedByCanonicalRow() {
        var t = loaded()
        t.appendPendingUserMessage(text: "next", messageId: "msg_9")
        #expect(t.rows.last?.isPending == true)
        _ = t.applyStream(stream(3, ["type": "user_message", "text": "next", "messageId": "msg_9"], turn: "t2"))
        #expect(t.rows.count == 3)
        #expect(t.rows.last?.isPending == false)
        #expect(t.rows.last?.turnId == "t2")
    }

    @Test func afterPageReplacesStraddlingAssistantRow() {
        var t = loaded()
        _ = t.applyStream(stream(3, ["type": "assistant_message", "text": " wor"]))
        // Projected entry merges seq 2…4 into the full text; seq 5 is new.
        t.applyPage(page("after", [
            entry(2, ["type": "assistant_message", "text": "hello world!"], seqEnd: 4),
            entry(5, ["type": "user_message", "text": "again", "messageId": "m2"]),
        ], start: 2, end: 5))
        #expect(t.rows.map(text) == ["hi", "hello world!", "again"])
        #expect(t.endSeq == 5)
    }

    @Test func beforePagePrepends() {
        var t = loaded()
        t.applyPage(page("before", [entry(0, ["type": "user_message", "text": "first", "messageId": "m0"])], start: 0, end: 0))
        #expect(t.rows.map(text) == ["first", "hi", "hello"])
        #expect(t.startSeq == 0 && !t.hasOlder)
    }

    @Test func resetReplacesButKeepsUnclaimedPending() {
        var t = loaded()
        t.appendPendingUserMessage(text: "pending", messageId: "msg_p")
        t.applyPage(page("after", [entry(10, ["type": "assistant_message", "text": "new world"])], start: 10, end: 10, epoch: "e2", reset: true))
        #expect(t.rows.map(text) == ["new world", "pending"])
        #expect(t.epoch == "e2")
    }

    @Test func agentBucketFollowsOfficialRules() throws {
        let base: [String: JSONValue] = ["id": "a", "provider": "claude", "cwd": "/", "status": "running", "pendingPermissions": []]
        #expect(Agent(.object(base))?.bucket == .running)
        var p = base; p["pendingPermissions"] = [["id": "perm1", "kind": "tool"]]
        #expect(Agent(.object(p))?.bucket == .needsInput)
        var e = base; e["status"] = "error"
        #expect(Agent(.object(e))?.bucket == .failed)
        var d = base; d["status"] = "idle"; d["requiresAttention"] = true
        #expect(Agent(.object(d))?.bucket == .attention)
        var u = base; u["status"] = "brand_new_status"
        #expect(Agent(.object(u))?.status == .unknown)
    }
}

@Suite struct BackgroundTaskTests {
    private func bash(_ callId: String, _ command: String, output: String) -> JSONValue {
        ["type": "tool_call", "callId": .string(callId), "name": "Bash", "status": "completed",
         "detail": ["type": "shell", "command": .string(command), "output": .string(output)]]
    }

    private func notification(toolUseId: String, taskId: String, status: String, summary: String) -> JSONValue {
        ["type": "tool_call", "callId": .string("task_notification_\(taskId)"), "name": "task_notification", "status": "completed",
         "detail": ["type": "plain_text", "label": .string(summary), "icon": "wrench"],
         "metadata": ["synthetic": true, "source": "claude_task_notification", "taskId": .string(taskId),
                      "toolUseId": .string(toolUseId), "status": .string(status)]]
    }

    private let bgOutput = "Command running in background with ID: bx4fb0hjb. Output is being written to: /tmp/x.output"

    @Test func sourceReadsAndSearchResultsAreNotBackgroundTasks() {
        let outputs = [
            "/// 输出是「Command running in background with ID: …」的命令行。",
            "    private let bgOutput = \"\(bgOutput)\"",
            "BackgroundTasks.swift:24:/// 输出是「Command running in background with ID: …」的命令行。",
            "// source header\n\(bgOutput)\n// source footer",
        ]
        var t = AgentTimeline()
        t.applyPage(page("tail", outputs.enumerated().map { index, output in
            entry(index + 1, bash("read_\(index)", "sed -n '1,280p' BackgroundTasks.swift", output: output))
        }, start: 1, end: outputs.count))
        #expect(t.backgroundTasks(sessionEnded: false).isEmpty)
    }

    @Test func otherToolsCannotCreateClaudeBackgroundTasks() {
        var t = AgentTimeline()
        t.applyPage(page("tail", [entry(1,
            ["type": "tool_call", "callId": "codex-read", "name": "exec_command", "status": "completed",
             "detail": ["type": "shell", "command": "cat example.txt", "output": .string(bgOutput), "exitCode": 0]])
        ], start: 1, end: 1))
        #expect(t.backgroundTasks(sessionEnded: false).isEmpty)
    }

    @Test func backgroundReceiptRequiresValidIDAndCompleteOutput() {
        #expect(AgentBackgroundTask.taskId(fromOutput: "\n\(bgOutput)\n", toolName: "Bash") == "bx4fb0hjb")
        #expect(AgentBackgroundTask.taskId(fromOutput: "Command running in background with ID: task_1-2.", toolName: "Bash") == "task_1-2")
        let invalid = [
            "Command running in background with ID:",
            "Command running in background with ID: …",
            "Command running in background with ID: \"example\"",
            "Command running in background with ID: task invalid",
            "Command running in background with ID: task. Output is being written to:",
            "\(bgOutput)\nmore source code",
        ]
        for output in invalid {
            #expect(AgentBackgroundTask.taskId(fromOutput: output, toolName: "Bash") == nil)
        }
    }

    @Test func multilineReceiptKeepsKnownCwdNoticeAndPairsCompletion() {
        let first = "Command running in background with ID: b202t0ccr. Output is being written to: /tmp/tasks/b202t0ccr.output. You will be notified when it completes. To check interim output, use Read on that file path."
        let cwd = "Session cwd remains /workspace/sample project; directory changes made by the backgrounded command do not apply to subsequent commands."
        for newline in ["\n", "\r\n"] {
            #expect(AgentBackgroundTask.taskId(fromOutput: first + newline + cwd, toolName: "Bash") == "b202t0ccr")
        }
        for extra in ["more source code", "Session cwd remains ; directory changes made by the backgrounded command do not apply to subsequent commands.", cwd + "\nmore source code", cwd + " unexpected suffix"] {
            #expect(AgentBackgroundTask.taskId(fromOutput: first + "\n" + extra, toolName: "Bash") == nil)
        }
        var timeline = AgentTimeline()
        timeline.applyPage(page("tail", [entry(1, bash("multiline", "build", output: first + "\n" + cwd))], start: 1, end: 1))
        #expect(timeline.backgroundTasks(sessionEnded: false).first?.state == .running)
        _ = timeline.applyStream(stream(2, notification(toolUseId: "multiline", taskId: "b202t0ccr", status: "completed", summary: "done")))
        #expect(timeline.backgroundTasks(sessionEnded: false).first?.state == .completed)
    }

    @Test func runningUntilNotificationArrives() {
        var t = AgentTimeline()
        t.applyPage(page("tail", [
            entry(1, bash("toolu_1", "scripts/install-mac.sh", output: bgOutput)),
            entry(2, bash("toolu_2", "ls", output: "a\nb")),
        ], start: 1, end: 2))
        var tasks = t.backgroundTasks(sessionEnded: false)
        #expect(tasks.count == 1)
        #expect(tasks.first?.taskId == "bx4fb0hjb" && tasks.first?.state == .running && tasks.first?.rowId == "tool-toolu_1")
        #expect(t.backgroundTasks(sessionEnded: true).first?.state == .interrupted)

        _ = t.applyStream(stream(3, notification(toolUseId: "toolu_1", taskId: "bx4fb0hjb", status: "completed",
                                                 summary: "Background command \"Build\" completed (exit code 0)")))
        tasks = t.backgroundTasks(sessionEnded: true)
        #expect(tasks.first?.state == .completed)
        #expect(tasks.first?.summary == "Background command \"Build\" completed (exit code 0)")
    }

    @Test func failedAndStoppedStates() {
        var t = AgentTimeline()
        t.applyPage(page("tail", [
            entry(1, bash("toolu_1", "a", output: bgOutput)),
            entry(2, bash("toolu_2", "b", output: "Command running in background with ID: b2")),
            entry(3, notification(toolUseId: "toolu_1", taskId: "bx4fb0hjb", status: "failed", summary: "x")),
            entry(4, notification(toolUseId: "other", taskId: "b2", status: "stopped", summary: "y")),
        ], start: 1, end: 4))
        #expect(t.backgroundTasks(sessionEnded: false).map(\.state) == [.failed, .stopped])
    }

    @Test func notificationInOlderPageStillPairs() {
        var t = AgentTimeline()
        t.applyPage(page("tail", [entry(5, notification(toolUseId: "toolu_1", taskId: "bx4fb0hjb", status: "completed", summary: "ok"))],
                         start: 5, end: 5, hasOlder: true))
        t.applyPage(page("before", [entry(1, bash("toolu_1", "a", output: bgOutput))], start: 1, end: 4))
        #expect(t.backgroundTasks(sessionEnded: false).first?.state == .completed)
    }
}
