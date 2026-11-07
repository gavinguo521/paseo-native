import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct InterfaceEvidenceTests {
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

    private func capture<V: View>(_ content: V, width: Int, name: String, dark: Bool = false) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).background(dark ? Color.black : Color.white))
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
