import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct InterfaceEvidenceTests {
    @Test func questionAndAnswerLayout() async throws {
        let question = "请在模拟器来回切换几个底部 Tab，再打开「我的 → 联系客服」弹窗并停留。完成后回复我，我会直接截图核对顶部是否被遮罩覆盖。"
        let host = HostStore(offer: .direct(serverId: "question-layout-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "测试机器", clientId: "test", appVersion: "test")
        let request = try #require(PermissionRequest(["id": "question-layout", "kind": "question", "input": [
            "questions": [["header": "操作完成", "question": .string(question),
                "options": [["label": "已切换并打开弹窗"]]]]
        ]]))
        for width in [390, 800] {
            for dark in [false, true] {
                let style = dark ? "dark" : "light"
                try await capture(VStack(alignment: .leading, spacing: 20) {
                    TimelineItemView(item: .turnSummary(id: "question-layout-reference", label: "1 个其他操作", hidden: []))
                    UserBubble(text: "Answers to your questions:\n\n\(question)\n已切换并打开弹窗")
                }
                    .padding(20).frame(maxHeight: .infinity, alignment: .top),
                    width: width, height: 420, name: "question-complete-\(style)", dark: dark)
                try await capture(PermissionCard(host: host, agentId: "test", request: request)
                    .padding(6).frame(maxHeight: .infinity, alignment: .top),
                    width: width, height: 500, name: "question-pending-\(style)", dark: dark)
            }
        }
    }

    @Test func pastedTextCardPreview() async throws {
        for width in [390, 800] {
            try await capture(PastedTextCardFixture(), width: width, name: "pasted-text-card")
        }
    }

    @Test func macComposerLargePasteAndEditing() async throws {
        let state = MacComposerPerformanceState()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 740, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MacComposerPerformanceFixture(state: state))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> MacComposerEditor? {
            (view as? MacComposerEditor) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let view = try #require(editor(in: host))
        window.makeFirstResponder(view)
        let payload = String(repeating: "这是一段用于验证粘贴性能的中文文本，包含代码 let value = 1; 和 Emoji 👨‍👩‍👧‍👦。", count: 20000)
        let pasteboard = NSPasteboard(name: .init("paseo-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(payload, forType: .string)
        let start = ContinuousClock.now
        #expect(view.readSelection(from: pasteboard, type: .string))
        host.layoutSubtreeIfNeeded()
        let elapsed = start.duration(to: .now)
        print("COMPOSER_ATTACHMENT utf16=\((payload as NSString).length) elapsed=\(elapsed)")
        #expect(state.text.isEmpty)
        #expect(view.string.isEmpty)
        #expect(state.attachment?.data == Data(payload.utf8))
        #expect(elapsed < .seconds(1))
        let scroll = try #require(view.enclosingScrollView)
        #expect(scroll.bounds.height <= 300)
        #expect(scroll.bounds.height > 30)
        // 普通文字仍原位插入，选区替换和撤销不受附件分流影响。
        let short = "这是一段普通文字 👨‍👩‍👧‍👦\n第二行"
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText(short, replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        #expect(state.text == short)
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.insertText("替换", replacementRange: view.selectedRange())
        view.undoManager?.endUndoGrouping()
        #expect(state.text.hasPrefix("替换"))
        view.undoManager?.undo()
        #expect(view.string == short)
        undo.groupsByEvent = true
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let composed = view.string
        state.text = "外部更新不能覆盖正在组词"
        host.layoutSubtreeIfNeeded()
        #expect(view.string == composed)
        view.unmarkText()
        for code: UInt16 in [36, 48, 126, 125, 53] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        #expect(state.returns == 1)
        #expect(state.keys == 4)
    }

    @Test func longPasteKeepsAllBytesAndNormalTextStaysInline() {
        #expect(!PastedTextAttachment.shouldAttach(String(repeating: "a", count: 12_000)))
        #expect(PastedTextAttachment.shouldAttach(String(repeating: "a", count: 12_001)))
        #expect(!PastedTextAttachment.shouldAttach(String(repeating: "a\n", count: 199)))
        #expect(PastedTextAttachment.shouldAttach(String(repeating: "a\n", count: 200)))
        let original = "  日志头 👨‍👩‍👧‍👦\r\n" + String(repeating: "Error: 未处理异常\n", count: 2000) + "\n\n结尾  "
        let attachment = PastedTextAttachment(original)
        #expect(String(data: attachment.data, encoding: .utf8) == original)
        #expect(attachment.preview.count <= 160)
        #expect(!attachment.preview.contains("\n"))
    }

    @Test func queuedLogAttachmentSurvivesEditAndFailedSendRestoration() {
        let content = PastedTextAttachment(String(repeating: "完整日志\n", count: 2000))
        let item = UploadItem(name: "log.txt", file: UploadedFile(id: "uploaded-log", fileName: "log.txt", size: content.data.count,
                              attachment: ["type": "uploaded_file", "id": "uploaded-log"]), pastedText: content)
        let queued = QueuedMessage(text: "分析日志", images: [], files: [item.file!.attachment], uploads: [item])
        let other = UploadItem(name: "other.txt")
        let restored = UploadItem.restoring(queued.uploads, into: [other])
        #expect(restored.map(\.id) == [item.id, other.id])
        #expect(restored.first?.pastedText?.data == content.data)
        #expect(restored.first?.file?.attachment == queued.files.first)
        let failedAgain = UploadItem.restoring(queued.uploads, into: restored)
        #expect(failedAgain.map(\.id) == restored.map(\.id))
    }

    @Test func macComposerHeightMeasurementIsBounded() {
        let measurement = ComposerTextMeasurement()
        let short = measurement.size("你好", width: 700, fontSize: 14)
        let long = measurement.size(String(repeating: "长草稿\n", count: 10000), width: 700, fontSize: 14)
        #expect(long.height > short.height)
        #expect(long.height <= short.height * 4 + 1)
        #expect(measurement.size("你好", width: 700, fontSize: 14) == short)
    }

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

    @Test func messageSenderNamesAndNavigation() async throws {
        let model = try SidebarTestFixture.model(projects: 1)
        let host = try #require(model.hosts.first)
        let lookup = MessageSenderLookup(host: host, model: model)
        let sender: JSONValue = ["id": "p0-w0-s0", "title": "过时的标题"]
        let resolved = lookup.lookup(sender)
        #expect(resolved.name == "项目 0 的工作区 0 会话 0")
        let ref = try #require(resolved.ref)
        let origin = AgentRef(serverId: host.id, agentId: "p0-w0-s1")
        model.open(origin)
        let reading = model.readingState(for: origin)
        reading.hasPosition = true
        reading.atBottom = false
        reading.offset = 230
        lookup.open(ref)
        #expect(model.destination == .agent(ref))
        #expect(model.messageReturnSource == origin)
        model.returnToMessageSource()
        #expect(model.destination == .agent(origin))
        #expect(reading.restoreOnNextAppearance)
        #expect(reading.offset == 230)
        #expect(reading.shouldRestorePosition(enabled: reading.restoreOnNextAppearance, liveFirstRowID: nil))
        #expect(model.messageReturnSource == nil)
        lookup.open(ref)
        model.destination = .history
        #expect(model.messageReturnPath.isEmpty)
        model.open(origin)
        let url = try #require(PaseoActivityLink.url(serverId: ref.serverId, agentId: ref.agentId))
        #expect(PaseoActivityLink.parse(url)?.agentId == ref.agentId)
        var windowTarget: AgentRef?
        let windowLookup = MessageSenderLookup(host: host, model: model, navigate: { windowTarget = $0 })
        windowLookup.open(ref)
        #expect(windowTarget == ref)
        #expect(model.destination == .agent(origin))
        #expect(lookup.lookup(["id": "p0-w0-s"]).ref == nil)
        let remote = lookup.lookup(["id": "p0-w0-s0", "serverId": "unknown-host", "title": "远程会话"])
        #expect(remote.ref == nil)
        #expect(remote.name == "远程会话")
        #expect(lookup.lookup(["id": "missing-session"]).name == "missing")
        for width in [390, 960] {
            try await capture(UserBubble(text: "这是来自另一个工作区会话的消息。", sender: "客户端界面优化工作区 / 检查 iPhone、iPad 和 Mac 的输入栏与会话跳转体验", openSender: { lookup.open(ref) }).padding(16), width: width, name: "message-sender")
        }
    }

    @Test func crossSessionReplyCard() async throws {
        let sender: JSONValue = ["id": "agent-1", "serverId": "server-1", "title": "检查消息来源排版"]
        let body = "Agent agent-1 (检查消息来源排版) finished.\n\nServer: server-1\n\n<agent-response>\n## 检查结果\n\n已修复 **iPhone 与 iPad** 的按钮排版。\n\n- 保留会话名称\n- 支持点击来源跳转\n\n`swift test` 已通过。\n</agent-response>"
        let parsed = AgentMessageContent(text: body, sender: sender, event: "finished")
        #expect(parsed.response?.hasPrefix("## 检查结果") == true)
        #expect(parsed.note.isEmpty)
        #expect(parsed.trailing.isEmpty)
        #expect(AgentMessageContent(text: body, sender: sender, event: "message").note == body)
        let wrong: JSONValue = ["id": "different-agent"]
        #expect(AgentMessageContent(text: body, sender: wrong, event: "finished").note == body)
        let incomplete = body.replacingOccurrences(of: "</agent-response>", with: "")
        #expect(AgentMessageContent(text: incomplete, sender: sender, event: "finished").response == nil)
        #expect(AgentMessageContent(text: incomplete, sender: sender, event: "finished").note == incomplete)
        let withTail = body + "\n后续补充不能丢失"
        #expect(AgentMessageContent(text: withTail, sender: sender, event: "finished").trailing == "后续补充不能丢失")
        for width in [390, 960] {
            for dark in [false, true] {
                try await capture(CrossSessionMessageCard(message: ["event": "finished", "sender": sender], text: body).padding(16),
                                  width: width, name: "source-card-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    private func agentMessageRow(_ id: String, event: String, sender: JSONValue, text: String) -> TimelineRow {
        TimelineRow(id: id, turnId: nil, timestamp: Date(),
                    item: .toolCall(callId: id, name: "paseo", status: "completed", detail: .unknown(.null),
                                    error: nil, agentMessage: ["event": .string(event), "sender": sender, "text": .string(text)]),
                    isStreaming: false, isPending: false)
    }

    @Test func completionFoldsOnlyAfterDirectMessage() async throws {
        let helper: JSONValue = ["id": "helper", "serverId": "studio"]
        let other: JSONValue = ["id": "helper", "serverId": "mini"]
        let finished = { (id: String) in "Agent \(id) (助手) finished.\n\n<agent-response>\n结果\n</agent-response>" }
        let rows = [
            agentMessageRow("m1", event: "message", sender: helper, text: "主动发来的结果"),
            agentMessageRow("f1", event: "finished", sender: helper, text: finished("helper")),
            // 同一来源下一轮没再主动发消息：最后回复就是结果，展开。
            agentMessageRow("f2", event: "finished", sender: helper, text: finished("helper")),
            // 另一台机器上同 id 的会话不算同一来源。
            agentMessageRow("f3", event: "finished", sender: other, text: finished("helper")),
            agentMessageRow("e1", event: "errored", sender: helper, text: "Agent helper (助手) errored."),
        ]
        #expect(DisplayItemCache.foldedCompletions(rows) == ["f1"])
        #expect(DisplayItemCache.foldedCompletions([rows[0], rows[4], rows[1]]) == ["f1"])

        let sender: JSONValue = ["id": "8179073", "serverId": "studio", "title": "给 Mac mini 加密传测网 RDS/SSH 配置"]
        let reply = "打包、加密和清理都做完了，下面是回报。\n\n**打包的文件（共 5 个）**\n- `dgbj-test-rds.cnf`\n- `ssh-config-dgbj-test`\n\n**说明**\n- **私钥口令：** 没有口令。"
        let completion = "Agent 8179073 (给 Mac mini 加密传测网 RDS/SSH 配置) finished.\n\nServer: studio\n\n<agent-response>\n\(reply)\n</agent-response>"
        let direct = [agentMessageRow("d-msg", event: "message", sender: sender, text: "测网配置已经加密好，密文在下面：\n\n```\n-----BEGIN AGE ENCRYPTED FILE-----\n...\n```"),
                      agentMessageRow("d-done", event: "finished", sender: sender, text: completion.replacingOccurrences(of: reply, with: "已把密文发给你的会话。"))]
        let onlyDone = [agentMessageRow("o-done", event: "finished", sender: sender, text: completion)]
        let longReply = reply + "\n- **外部代理：** 不依赖 ssh-agent。\n- **跳板：** 没有 ProxyJump。\n- **known_hosts：** 已存进 `known_hosts-dgbj-test`。\n\n**密文（age）**\n\n```\n-----BEGIN AGE ENCRYPTED FILE-----\n" + String(repeating: "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBkblFyMTFMTGE2dm1nanBG\n", count: 30) + "-----END AGE ENCRYPTED FILE-----\n```"
        let longDone = [agentMessageRow("l-done", event: "finished", sender: sender, text: completion.replacingOccurrences(of: reply, with: longReply))]
        let statuses = [
            agentMessageRow("s-err", event: "errored", sender: sender, text: "Agent 8179073 (给 Mac mini 加密传测网 RDS/SSH 配置) errored.\n\nServer: studio\n\n<agent-response>\n连接测网服务器超时，没能打包。\n</agent-response>"),
            agentMessageRow("s-perm", event: "permission-required", sender: sender, text: "Agent 8179073 (给 Mac mini 加密传测网 RDS/SSH 配置) needs permission.\n\nServer: studio\n\n<agent-response>\n要读取 ~/.ssh/config，需要你批准。\n</agent-response>"),
            agentMessageRow("s-closed", event: "closed", sender: sender, text: "Agent 8179073 (给 Mac mini 加密传测网 RDS/SSH 配置) was closed."),
        ]
        for (name, rows) in [("with-direct-message", direct), ("completion-only", onlyDone), ("completion-long", longDone), ("statuses", statuses)] {
            try await capture(VStack(alignment: .leading, spacing: 20) {
                ForEach(rows) { TimelineItemView(item: .row($0, footer: false)) }
            }
            .environment(\.foldedCompletions, DisplayItemCache.foldedCompletions(rows))
            .padding(16).frame(maxHeight: .infinity, alignment: .top), width: 800, name: "completion-\(name)")
            try await capture(VStack(alignment: .leading, spacing: 20) {
                ForEach(rows) { TimelineItemView(item: .row($0, footer: false)) }
            }
            .environment(\.foldedCompletions, DisplayItemCache.foldedCompletions(rows))
            .padding(16).frame(maxHeight: .infinity, alignment: .top), width: 390, name: "completion-\(name)-dark", dark: true)
        }
    }

    private func toolRow(_ id: String, name: String, status: String = "completed", input: JSONValue) -> TimelineRow {
        TimelineRow(id: id, turnId: nil, timestamp: Date(),
                    item: .toolCall(callId: id, name: name, status: status, detail: .unknown(["input": input]),
                                    error: nil, agentMessage: nil),
                    isStreaming: false, isPending: false)
    }

    @Test func sentMessageShowsAsCardOutsideCollapsedWork() async throws {
        let prompt = "【跨机器消息】来自 office 上「订单服务」项目的会话「邀请函」（id f6ae738）\n\n从 Studio 钥匙串读这两项：`com.example.app.test-login.phone` / `.password`。\n\n- 通过管道直接用 Mac mini 的 age 公钥加密，不落明文文件。\n- 只把 ASCII 装甲密文写在这一轮的最后回复里。"
        let send = toolRow("send", name: "mcp__paseo__send_agent_prompt",
                           input: ["agentId": "81790731-cf63-4158-a94b-5ae6d1935628", "serverId": "srv_studio", "prompt": .string(prompt)])
        let message = try #require(send.item.outgoingMessage)
        #expect(message.agentId == "81790731-cf63-4158-a94b-5ae6d1935628" && message.serverId == "srv_studio")
        #expect(message.prompt?.hasPrefix("从 Studio 钥匙串") == true)
        let codex = try #require(toolRow("s2", name: "paseo.send_agent_prompt", input: ["agentId": "a", "prompt": "hi"]).item.outgoingMessage)
        #expect(codex.agentId == "a" && codex.serverId == nil)
        #expect(toolRow("s3", name: "mcp__paseo__get_agent_status", input: ["agentId": "a"]).item.outgoingMessage == nil)
        #expect(toolRow("s4", name: "mcp__other__send_agent_prompt", input: ["agentId": "a", "prompt": "hi"]).item.outgoingMessage == nil)

        // paseo-peer tell：真实会话里出现过的写法。
        let tell = { (command: String) in OutgoingAgentMessage.peerTell(command) }
        #expect(tell(#"~/.claude/scripts/paseo-peer studio tell cfcc721 "方3 r2 已推送。\n复审只看 \"diff\"。" 2>&1 | tail -1"#)
                == OutgoingAgentMessage(agentId: "cfcc721", machine: "studio", prompt: "方3 r2 已推送。\\n复审只看 \"diff\"。"))
        #expect(tell("git push -q 2>&1 | tail -1; paseo-peer mini tell d05a873 '第一行\n第二行'")
                == OutgoingAgentMessage(agentId: "d05a873", machine: "mini", prompt: "第一行\n第二行"))
        #expect(tell("~/.claude/skills/paseo-peer-zh/scripts/paseo-peer studio tell 535994e --file /tmp/reply.md")
                == OutgoingAgentMessage(agentId: "535994e", machine: "studio", file: "/tmp/reply.md"))
        #expect(tell("paseo-peer studio tell 535994e \"$(cat <<'EOF'\n多行\n正文\nEOF\n)\"")?.prompt == "多行\n正文")
        #expect(tell("paseo-peer studio who orders-service") == nil)
        #expect(tell("paseo-peer studio logs 535994e --tail 40") == nil)
        #expect(tell("echo paseo-peer studio tell") == nil)
        let shellTell = TimelineRow(id: "pt", turnId: nil, timestamp: Date(),
                                    item: .toolCall(callId: "pt", name: "Bash", status: "completed",
                                                    detail: .shell(command: "paseo-peer studio tell cfcc721 \"好的\"", cwd: nil, output: nil, exitCode: 0),
                                                    error: nil, agentMessage: nil), isStreaming: false, isPending: false)
        #expect(shellTell.item.outgoingMessage?.machine == "studio")

        let model = try SidebarTestFixture.model(projects: 1)
        let host = try #require(model.hosts.first)
        let lookup = MessageSenderLookup(host: host, model: model)
        #expect(lookup.hostNamed("local") === host)
        #expect(lookup.hostNamed(host.label.uppercased()) === host)
        #expect(lookup.hostNamed("no-such-machine") == nil)

        // create_agent 带 initialPrompt：新开会话并发送；会话 id 在输出里（几种包法都认）。
        let createInput: JSONValue = ["title": "#1632 orders main 原有 16 项测试失败", "provider": "claude/claude-opus-5-5",
                                      "initialPrompt": "【跨项目消息】来自「订单服务」项目的会话（id f6ae738），Gavin 让我把这件事派给你。\n\n处理看板 #1632：orders main 全量测试原有 16 项失败。"]
        let create = TimelineRow(id: "c", turnId: nil, timestamp: Date(),
                                 item: .toolCall(callId: "c", name: "mcp__paseo__create_agent", status: "completed",
                                                 detail: .unknown(["input": createInput,
                                                                   "output": ["output": ["agentId": "f91c5375-4bf1-4301-bc7d-881d95966f35", "availableModes": []]]]),
                                                 error: nil, agentMessage: nil), isStreaming: false, isPending: false)
        let created = try #require(create.item.outgoingMessage)
        #expect(created.creates && created.agentId == "f91c5375-4bf1-4301-bc7d-881d95966f35")
        #expect(created.title == "#1632 orders main 原有 16 项测试失败")
        #expect(created.prompt?.hasPrefix("Gavin 让我把这件事派给你。\n\n处理看板 #1632") == true)
        #expect(OutgoingAgentMessage.createdAgentId(["content": [["type": "text", "text": #"{"agentId":"abc-1","status":"idle"}"#]]]) == "abc-1")
        #expect(toolRow("c2", name: "mcp__paseo__create_agent", status: "running", input: createInput).item.outgoingMessage?.agentId == "")
        #expect(toolRow("c3", name: "mcp__paseo__create_agent", input: ["title": "空会话"]).item.outgoingMessage == nil)

        // 查询类调用：一句话，会话名可点。
        let check = toolRow("q1", name: "mcp__paseo__get_agent_status", input: ["agentId": "81790731-cf63-4158", "serverId": "srv_studio"])
        let action = try #require(check.item.paseoAgentAction)
        #expect(action.agentId == "81790731-cf63-4158" && action.serverId == "srv_studio")
        #expect(check.item.toolSummary == "查看「8179073」的状态")
        #expect(toolRow("q2", name: "paseo.get_agent_activity", input: ["agentId": "abc"]).item.toolSummary == "查看「abc」的最近活动")
        #expect(toolRow("q3", name: "mcp__paseo__list_agents", input: [:]).item.toolSummary == "列出会话")
        #expect(toolRow("q4", name: "mcp__paseo__list_agents", input: [:]).item.paseoAgentAction == nil)
        #expect(send.item.paseoAgentAction == nil)

        // paseo-peer 其他子命令：针对会话的可点，其余一句话。
        let peer = { (c: String) in PeerCommand(c) }
        #expect(peer("~/.claude/scripts/paseo-peer studio wait cfcc721 --timeout 90") == .agent(PaseoAgentAction(leaf: "peer_wait", agentId: "cfcc721", machine: "studio")))
        #expect(peer("paseo-peer studio logs 535994e --tail 40 > /tmp/l.txt; tail -5 /tmp/l.txt") == .agent(PaseoAgentAction(leaf: "peer_logs", agentId: "535994e", machine: "studio")))
        #expect(peer("paseo-peer studio permit allow 535994e req-1") == .agent(PaseoAgentAction(leaf: "permit_allow", agentId: "535994e", machine: "studio")))
        #expect(peer("paseo-peer studio agent mode 535994e bypassPermissions") == .agent(PaseoAgentAction(leaf: "set_agent_mode", agentId: "535994e", machine: "studio")))
        #expect(peer("paseo-peer studio who orders-service")?.summary == "在 studio 上查看做「orders-service」的会话")
        #expect(peer("paseo-peer local find 部署 deploy -a --days 7")?.summary == "在本机上找做「部署 / deploy」的会话")
        #expect(peer("paseo-peer studio mine")?.summary == "列出本会话在 studio 上开的配合会话")
        #expect(peer("paseo-peer ls")?.summary == "列出所有机器")
        #expect(peer("paseo-peer whoami --header --remote")?.summary == "查看本会话的来源说明")
        #expect(peer("paseo-peer studio wait cfcc721")?.summary == "等「studio · cfcc721」跑完这一轮")
        #expect(peer("paseo-peer join") == nil)
        #expect(peer("ls -la ~/.paseo") == nil)
        let waitRow = TimelineRow(id: "w", turnId: nil, timestamp: Date(),
                                  item: .toolCall(callId: "w", name: "Bash", status: "completed",
                                                  detail: .shell(command: "paseo-peer studio wait cfcc721", cwd: nil, output: "done", exitCode: 0),
                                                  error: nil, agentMessage: nil), isStreaming: false, isPending: false)
        #expect(waitRow.item.paseoAgentAction?.leaf == "peer_wait")
        #expect(waitRow.item.toolSummary == "等「studio · cfcc721」跑完这一轮")
        #expect(workSummary([waitRow]) == "1 个其他操作")

        // tell 输出里的 serverId：本条直接用，同一会话里其他 paseo-peer 行也学到。
        let toldRow = TimelineRow(id: "t", turnId: nil, timestamp: Date(),
                                  item: .toolCall(callId: "t", name: "Bash", status: "completed",
                                                  detail: .shell(command: "paseo-peer studio tell cfcc721 \"好的\"", cwd: nil,
                                                                 output: "Queued\n已发送：studio（serverId srv_-cIHYMZUxi3_）", exitCode: 0),
                                                  error: nil, agentMessage: nil), isStreaming: false, isPending: false)
        #expect(toldRow.item.outgoingMessage?.serverId == "srv_-cIHYMZUxi3_")
        #expect(DisplayItemCache.peerServers([waitRow, toldRow]) == ["studio": "srv_-cIHYMZUxi3_"])

        // run：在那台机器上新开会话并发送；$(…) 整段算一个词。
        let run = try #require(OutgoingAgentMessage.peerRun(#"paseo-peer studio run --no-wait --workspace wks_1 --title "测网发布" --mode bypassPermissions $(paseo-peer whoami --labels) --cwd ~/p "把后端发到测网""#,
                                                            output: "Agent started: 1a2b3c4d-0000-4000-8000-123456789abc"))
        #expect(run.creates && run.title == "测网发布" && run.prompt == "把后端发到测网" && run.agentId == "1a2b3c4d-0000-4000-8000-123456789abc")

        // 工作区、终端、定时任务等工具：中文一句话。
        #expect(toolRow("w1", name: "mcp__paseo__create_workspace", input: ["path": "/Users/me/projects/demo"]).item.toolSummary == "新建工作区「demo」")
        #expect(toolRow("w2", name: "mcp__paseo__start_workspace_script", input: ["scriptName": "dev"]).item.toolSummary == "启动脚本「dev」")
        #expect(toolRow("w3", name: "mcp__paseo__create_schedule", input: ["name": "每日巡检", "cron": "0 9 * * *"]).item.toolSummary == "新建定时任务「每日巡检」")
        #expect(toolRow("w4", name: "mcp__paseo__capture_terminal", input: ["terminalId": "t1"]).item.toolSummary == "读取终端输出")

        let user = TimelineRow(id: "u", turnId: nil, timestamp: Date(), item: .userMessage(text: "去要测网凭证", messageId: nil),
                               isStreaming: false, isPending: false)
        let shell = TimelineRow(id: "sh", turnId: nil, timestamp: Date(),
                                item: .toolCall(callId: "sh", name: "Bash", status: "completed",
                                                detail: .shell(command: "paseo-peer studio who", cwd: nil, output: nil, exitCode: 0),
                                                error: nil, agentMessage: nil), isStreaming: false, isPending: false)
        let status = toolRow("st", name: "mcp__paseo__get_agent_status", input: ["agentId": "81790731"])
        let reply = TimelineRow(id: "r", turnId: nil, timestamp: Date(), item: .assistantMessage(text: "消息已发给 Studio 上的会话。", messageId: nil),
                                isStreaming: false, isPending: false)
        let items = DisplayItem.build([user, shell, status, send, reply], lastTurnActive: false, collapse: true)
        #expect(items.map(\.id) == ["u", "turn-sh", "send", "r"])
        if case .turnSummary(_, let label, _) = items[1] { #expect(label == "2 个其他操作") }

        let failed = TimelineRow(id: "f", turnId: nil, timestamp: Date(),
                                 item: .toolCall(callId: "f", name: "mcp__paseo__send_agent_prompt", status: "failed",
                                                 detail: .unknown(["input": ["agentId": "8179073", "prompt": "再试一次"]]),
                                                 error: ["message": "Host srv_studio is offline"], agentMessage: nil),
                                 isStreaming: false, isPending: false)
        try await capture(VStack(alignment: .leading, spacing: 20) {
            ForEach([send, failed, shellTell, create]) { TimelineItemView(item: .row($0, footer: false)) }
        }.environment(\.messageSender, lookup)
         .padding(16).frame(maxHeight: .infinity, alignment: .top), width: 800, name: "sent-message")
        let activity = toolRow("q5", name: "mcp__paseo__get_agent_activity", input: ["agentId": "p0-w0-s0"])
        try await capture(VStack(alignment: .leading, spacing: 20) {
            ToolGroupView(rows: [check])
            ToolGroupView(rows: [activity])
            ToolGroupView(rows: [shell, check, activity])
            ToolGroupView(rows: [waitRow])
            ToolGroupView(rows: [toolRow("w5", name: "mcp__paseo__create_schedule", input: ["name": "每日巡检"])])
        }.environment(\.messageSender, lookup)
         .padding(16).frame(maxHeight: .infinity, alignment: .top), width: 800, name: "agent-queries")
        try await capture(VStack(alignment: .leading, spacing: 20) {
            ForEach([send, failed]) { TimelineItemView(item: .row($0, footer: false)) }
        }.padding(16).frame(maxHeight: .infinity, alignment: .top), width: 390, name: "sent-message-dark", dark: true)
    }

    /// README 配图：一段完整的跨机器协作（示例项目名，不含真实数据）。
    /// 英文图用 `xcodebuild … -testLanguage en` 再跑一次；输出 /tmp/paseo-readme-cross-session-<zh|en>-800.png。
    @Test func readmeCrossSessionShowcase() async throws {
        let en = Locale.current.language.languageCode?.identifier == "en"
        func t(_ zh: String, _ english: String) -> String { en ? english : zh }
        let office = HostStore(offer: .direct(serverId: "srv_office", endpoint: "localhost:1", useTls: false, password: nil),
                               label: t("公司的 iMac", "Office iMac"), clientId: "test", appVersion: "test")
        let home = HostStore(offer: .direct(serverId: "srv_home", endpoint: "localhost:2", useTls: false, password: nil),
                             label: t("家里的 MacBook", "Home MacBook"), clientId: "test", appVersion: "test")
        home.agents["pay-1"] = try #require(Agent(["id": "pay-1", "cwd": "/projects/payments", "title": .string(t("退款回调改造", "Refund callback rework")),
                                                    "status": "idle", "createdAt": .string(Date().ISO8601Format())]))
        let model = AppModel(testHosts: [office, home])
        let lookup = MessageSenderLookup(host: office, model: model)
        let base = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: Date()) ?? Date()
        func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes * 60)) }
        func row(_ id: String, _ minutes: Int, _ item: TimelineItem) -> TimelineRow {
            TimelineRow(id: id, turnId: nil, timestamp: at(minutes), item: item, isStreaming: false, isPending: false)
        }
        let sender: JSONValue = ["id": "pay-1", "serverId": "srv_home", "title": .string(t("退款回调改造", "Refund callback rework"))]
        let find = row("who", 1, .toolCall(callId: "who", name: "Bash", status: "completed",
                                           detail: .shell(command: t("paseo-peer home who 支付服务", "paseo-peer home who payments"), cwd: nil, output: nil, exitCode: 0),
                                           error: nil, agentMessage: nil))
        let prompt = t("【跨机器消息】来自 公司的 iMac 上「订单服务」项目的会话「退款接口联调」（id 1a2b3c4）\n\n订单服务这边退款接口已改好，需要支付服务配合：\n\n- 退款回调改用 `refund_id` + `status` 两个字段\n- 改完部署到测试环境，告诉我一声就开始联调",
                       "[Cross-machine message] From session \"Refund API integration\" in project \"orders\" on Office iMac (id 1a2b3c4)\n\nThe refund API on the orders side is ready. Need the payments side to:\n\n- Switch the refund callback to `refund_id` + `status`\n- Deploy to staging and ping me so we can start integration testing")
        let send = row("send", 1, .toolCall(callId: "send", name: "mcp__paseo__send_agent_prompt", status: "completed",
                                            detail: .unknown(["input": ["agentId": "pay-1", "serverId": "srv_home", "prompt": .string(prompt)]]),
                                            error: nil, agentMessage: nil))
        let incoming = row("msg", 9, .toolCall(callId: "msg", name: "paseo", status: "completed", detail: .unknown(.null), error: nil,
                                               agentMessage: ["event": "message", "sender": sender,
                                                              "text": .string(t("回调已改成 `refund_id` + `status`，已部署到测试环境（payments-staging），可以开始联调。",
                                                                                "Callback now uses `refund_id` + `status` and is deployed to staging (payments-staging). Ready for integration testing."))]))
        let doneText = t("Agent pay-1 (退款回调改造) finished.\n\nServer: srv_home\n\n<agent-response>\n已通知订单服务，等待联调结果。\n</agent-response>",
                         "Agent pay-1 (Refund callback rework) finished.\n\nServer: srv_home\n\n<agent-response>\nNotified the orders session, waiting for integration results.\n</agent-response>")
        let done = row("done", 9, .toolCall(callId: "done", name: "paseo", status: "completed", detail: .unknown(.null), error: nil,
                                            agentMessage: ["event": "finished", "sender": sender, "text": .string(doneText)]))
        let reply = row("reply", 12, .assistantMessage(text: t("联调通过：退款下单 → 支付回调 → 订单状态更新，全链路 6 个用例都过了。两边都已在测试环境，可以安排上线。",
                                                              "Integration passed: refund request → payment callback → order status update, all 6 end-to-end cases green. Both sides are on staging and ready to ship."),
                                                       messageId: nil))
        let rows = [send, incoming, done]
        try await capture(VStack(alignment: .leading, spacing: 20) {
            UserBubble(text: t("让家里那台机器上的支付服务把退款回调改一下，改完和我们联调", "Ask the payments session on the home machine to update the refund callback, then run integration tests with us"))
                .frame(maxWidth: .infinity, alignment: .trailing)
            ToolGroupView(rows: [find])
            ForEach(rows) { TimelineItemView(item: .row($0, footer: false)) }
            TimelineItemView(item: .row(reply, footer: false))
        }
        .environment(\.messageSender, lookup)
        .environment(\.foldedCompletions, DisplayItemCache.foldedCompletions(rows))
        .padding(24).frame(maxHeight: .infinity, alignment: .top), width: 800, height: en ? 600 : 556, name: "readme-cross-session-\(en ? "en" : "zh")")
    }

    private func capture<V: View>(_ content: V, width: Int, height: Int = 620, name: String, dark: Bool = false) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).background(dark ? Color.black : Color.white))
        view.sizingOptions = []
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
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

@MainActor @Observable private final class MacComposerPerformanceState {
    var text = ""
    var returns = 0
    var keys = 0
    var attachment: PastedTextAttachment?
}
private struct MacComposerPerformanceFixture: View {
    @Bindable var state: MacComposerPerformanceState
    @FocusState private var focused: Bool
    var body: some View {
        MacComposerTextView(text: $state.text, placeholder: "下一句建议", focused: $focused, fontSize: 14,
                            onReturn: { _ in state.returns += 1; return true },
                            onKey: { _ in state.keys += 1; return true }, onPaste: { false },
                            onLongText: { text in
                                guard PastedTextAttachment.shouldAttach(text) else { return false }
                                state.attachment = PastedTextAttachment(text)
                                return true
                            })
            .frame(width: 700)
    }
}

private struct PastedTextCardFixture: View {
    @State private var text = "帮我分析这些错误日志，看看卡死的原因。"
    @State private var images: [ImageAttachment] = []
    @State private var uploads: [UploadItem] = {
        let content = PastedTextAttachment(String(repeating: "Date/Time: 2026-11-07 22:33:05\nEvent: hang\nThread 0: SwiftUI layout\n", count: 12000))
        return [UploadItem(name: "粘贴的文本.txt", file: UploadedFile(id: "preview", fileName: "粘贴的文本.txt", size: content.data.count, attachment: [:]), pastedText: content)]
    }()
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("粘贴长日志后").font(.system(size: 20, weight: .semibold))
            Text("完整内容已收进文本附件，可以继续输入你的问题。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            ComposerShell(text: $text, images: $images, focused: $focused, error: nil,
                          placeholder: "发送消息", uploads: $uploads) { EmptyView() }
            controls: { Text("GPT-6  ▾").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            trailing: { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 30, height: 30).background(Theme.accent, in: Circle()) }
            onSubmit: {}
        }.padding(24)
    }
}
