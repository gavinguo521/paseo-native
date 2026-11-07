import SwiftUI
@testable import PaseoKit
import Testing
@testable import Paseo
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Suite(.serialized) @MainActor struct ReplyTextTests {
    private let source = """
    ---

    ## 原位选择长回复

    第一段包含**粗体**、*强调*和中文 👨‍👩‍👧‍👦，从这里开始选择。

    ---

    第二段包含 [文件](App/Sources/UI/Theme.swift:12) 和 [网页](https://example.com)。

    - 列表第一项
    - 列表第二项

    > 引用也属于同一选区。

    ```swift
    let message = "你好"
    print(message)
    ```

    最后一段，跨过代码后仍能连续选择。
    """

    private func document(_ source: String) -> ReplyDocument {
        ReplyDocumentCache().document(MarkdownBlock.parse(source), query: "第二段", environment: EnvironmentValues())
    }

    @Test func richDocumentKeepsContentLinksAndCodeAcrossParagraphs() throws {
        let doc = document(source)
        #expect(!doc.text.string.contains("**"))
        #expect(!doc.text.string.contains("─"))
        #expect(document("---\n\n第一段\n\n---\n\n第二段\n\n---").text.string == "第一段\n\n第二段")
        #expect(doc.text.string.contains("👨‍👩‍👧‍👦"))
        #expect(doc.text.string.contains("列表第一项"))
        #expect(doc.text.string.contains("引用也属于同一选区"))
        #expect(doc.codes.count == 1)
        #expect(doc.codes.first?.text == "let message = \"你好\"\nprint(message)")
        let text = doc.text.string as NSString
        let file = try #require(doc.text.attribute(.link, at: text.range(of: "文件").location, effectiveRange: nil) as? URL)
        #expect(FileLink.parse(file)?.line == 12)
        #expect(doc.text.attribute(.backgroundColor, at: text.range(of: "第二段").location, effectiveRange: nil) != nil)
        let sections = ReplyTextSection.split(MarkdownBlock.parse(source))
        #expect(sections.count == 1)
        #expect(sections[0].isText)
        let media = ReplyTextSection.split(MarkdownBlock.parse("段一\n\n![图片](a.png)\n\n段二\n\n段三"))
        #expect(media.count == 3)
        #expect(media.map(\.isText) == [true, false, true])
    }

    @Test func selectionSurvivesStreamAndFinalRewriteUntilDeselected() throws {
        #if os(macOS)
        let view = ReplyNativeTextView(frame: .zero)
        #else
        let view = ReplyNativeTextView()
        #endif
        let coordinator = ReplyTextCoordinator()
        coordinator.view = view
        view.delegate = coordinator
        let first = document(source)
        coordinator.update(first)
        let text = first.text.string as NSString
        let start = text.range(of: "第一段").location
        let end = NSMaxRange(text.range(of: "最后一段"))
        let range = NSRange(location: start, length: end - start)
        view.replySelectedRange = range
        coordinator.changed()
        let selected = view.replyStorage.attributedSubstring(from: range).string
        #expect(selected.contains("列表第二项"))
        #expect(selected.contains("print(message)"))
        coordinator.update(document(source + "\n\n追加内容"))
        coordinator.update(document("服务端修订标题\n\n" + source + "\n\n最终追加内容"))
        #expect(view.replySelectedRange == range)
        #expect(view.replyStorage.attributedSubstring(from: range).string == selected)
        #expect(!view.replyStorage.string.contains("最终追加内容"))
        view.replySelectedRange = NSRange(location: end, length: 0)
        coordinator.changed()
        #expect(view.replyStorage.string.hasSuffix("最终追加内容"))
        #expect(view.replyStorage.string.hasPrefix("服务端修订标题"))
        #expect(coordinator.pending == nil)
    }

    #if os(iOS)
    @Test func unchangedReplyDoesNotReplaceTextAfterLayout() {
        let view = ReplyNativeTextView()
        view.isEditable = false; view.isScrollEnabled = false
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        let coordinator = ReplyTextCoordinator()
        coordinator.view = view
        let doc = document(String(repeating: source + "\n\n", count: 12))
        coordinator.update(doc)
        _ = view.replySize(for: 700)
        let observer = ReplyStorageObserver()
        view.textStorage.delegate = observer
        let start = Date()
        for _ in 0..<12 {
            coordinator.update(doc)
            _ = view.replySize(for: 700)
        }
        print("REPLY_REPEAT seconds=\(Date().timeIntervalSince(start)) edits=\(observer.edits)")
        #expect(observer.edits == 0)
    }
    @Test func replyMeasurementTracksWidthContentAndFontChanges() {
        let view = ReplyNativeTextView()
        view.isEditable = false; view.isScrollEnabled = false
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        let coordinator = ReplyTextCoordinator(); coordinator.view = view
        let doc = document(String(repeating: "这是一段用于验证窄屏换行的连续中文正文。", count: 80) + "\n\n" + source)
        coordinator.update(doc)
        let wide = view.replySize(for: 700)
        let narrow = view.replySize(for: 390)
        #expect(narrow.height > wide.height)
        let start = Date()
        for _ in 0..<100 {
            #expect(view.replySize(for: 700) == wide)
            #expect(view.replySize(for: 390) == narrow)
        }
        print("REPLY_CACHED_200 seconds=\(Date().timeIntervalSince(start))")
        let uncachedStart = Date()
        for _ in 0..<100 {
            _ = view.sizeThatFits(CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
            _ = view.sizeThatFits(CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
        }
        print("REPLY_UNCACHED_200 seconds=\(Date().timeIntervalSince(uncachedStart))")
        #expect(abs(view.sizeThatFits(CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude)).height - wide.height) <= 1)
        coordinator.update(document("短正文"))
        let short = view.replySize(for: 700)
        #expect(short.height < wide.height)
        let larger = NSMutableAttributedString(attributedString: document("短正文").text)
        larger.addAttribute(.font, value: UIFont.systemFont(ofSize: 48), range: NSRange(location: 0, length: larger.length))
        coordinator.update(ReplyDocument(text: larger))
        #expect(view.replySize(for: 700).height > short.height)
        coordinator.update(ReplyDocument(text: NSAttributedString(string: "")))
        #expect(view.replyStorage.length == 0)
        #expect(view.replySize(for: 700).height < wide.height)
    }
    #endif

    #if os(macOS)
    @Test func readOnlyReplyCreationDoesNotRunInsideSwiftUILayout() async throws {
        let coordinator = ReplyTextCoordinator()
        let host = ReplyTextHostView(coordinator: coordinator)
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 300)
        host.update(document("初始内容"))
        #expect(coordinator.view == nil)
        #expect(host.replySize(for: 700).height > 0)
        // 创建前连续更新时必须显示最后一份内容，不能丢失流式追加。
        host.update(document(source))
        for _ in 0..<20 where coordinator.view == nil { await Task.yield() }
        let view = try #require(coordinator.view)
        #expect(!view.isEditable)
        #expect(view.isSelectable)
        #expect(view.replyStorage.string.contains("最后一段"))
        #expect(view.frame.width == 700)
        view.replySelectedRange = NSRange(location: 2, length: 20)
        coordinator.changed()
        host.update(document("新内容"))
        #expect(view.replyStorage.string.contains("最后一段"))
        #expect(coordinator.pending != nil)
    }

    @Test func macReplyMeasurementReusesWidthsAndTracksContentChanges() {
        let view = ReplyNativeTextView(frame: .zero)
        let coordinator = ReplyTextCoordinator(); coordinator.view = view
        let text = String(repeating: "连续中文长正文用于验证宽窄屏排版和重复测量。", count: 100)
        coordinator.update(document(text))
        let wide = view.replySize(for: 820)
        let narrow = view.replySize(for: 350)
        #expect(narrow.height > wide.height)
        let start = Date()
        for _ in 0..<100 {
            #expect(view.replySize(for: 820) == wide)
            #expect(view.replySize(for: 350) == narrow)
        }
        print("MAC_REPLY_MEASURE_200 seconds=\(Date().timeIntervalSince(start))")
        view.replySelectedRange = NSRange(location: 2, length: 20)
        coordinator.update(document("短正文"))
        #expect(view.replySize(for: 820) == wide)
        view.replySelectedRange = NSRange(location: 0, length: 0)
        coordinator.changed()
        let short = view.replySize(for: 820)
        #expect(short.height < wide.height)
        let larger = NSMutableAttributedString(attributedString: document("短正文").text)
        larger.addAttribute(.font, value: NSFont.systemFont(ofSize: 48), range: NSRange(location: 0, length: larger.length))
        coordinator.update(ReplyDocument(text: larger))
        #expect(view.replySize(for: 820).height > short.height)
        coordinator.update(ReplyDocument(text: NSAttributedString(string: "")))
        #expect(view.replySize(for: 820).height < short.height)
    }

    @Test func discardedWidthProbeDoesNotChangeDisplayedWrapping() throws {
        let view = ReplyNativeTextView(frame: CGRect(x: 0, y: 0, width: 820, height: 400))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        let coordinator = ReplyTextCoordinator()
        coordinator.view = view
        coordinator.update(document(String(repeating: "这是用于检查正文宽度和底部状态栏重叠的长段落。", count: 20)))
        let size = view.replySize(for: 820)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let container = try #require(view.textContainer)
        let manager = try #require(view.layoutManager)
        let selected = NSRange(location: 5, length: 30)
        view.replySelectedRange = selected
        // 已采用宽列后，父布局还可能探测一个最终没有采用的窄列。
        _ = view.replySize(for: 350)
        manager.ensureLayout(for: container)
        #expect(abs(container.containerSize.width - view.bounds.width) < 1)
        #expect(manager.usedRect(for: container).maxY <= view.bounds.height + 1)
        #expect(view.replySelectedRange == selected)
    }
    #endif

    @Test func mountedReplyHasOneSelectionSurfaceAndFitsReadingColumn() async throws {
        for width: CGFloat in [390, 820, 1200] {
            let model = ReplyFixture(text: source)
            let content = ReplyFixtureView(model: model)
                .environment(\.colorScheme, .light).background(Color.white)
            #if os(macOS)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            window.contentView = host
            host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            func layout() { host.layoutSubtreeIfNeeded() }
            #else
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            let controller = UIHostingController(rootView: content)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            let host = controller.view!
            func layout() { host.layoutIfNeeded() }
            #endif
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat { layout(); await Task.yield() } while surfaces(host).first?.bounds.height ?? 0 < 150 && ContinuousClock.now < deadline
            let views = surfaces(host)
            #expect(views.count == 1)
            let view = try #require(views.first)
            #expect(abs(view.bounds.width - (width - 32)) < 1)
            #if os(macOS)
            let container = try #require(view.textContainer)
            let manager = try #require(view.layoutManager)
            manager.ensureLayout(for: container)
            #expect(abs(container.containerSize.width - view.bounds.width) < 1)
            #expect(manager.usedRect(for: container).maxY <= view.bounds.height + 1)
            #endif
            #expect(view.bounds.height > 150)
            #expect(view.isSelectable)
            #expect(!view.isEditable)
            let text = view.replyStorage.string as NSString
            let start = text.range(of: "第一段").location
            let end = NSMaxRange(text.range(of: "最后一段"))
            let range = NSRange(location: start, length: end - start)
            view.replySelectedRange = range
            #if os(macOS)
            window.makeFirstResponder(view)
            let saved = NSPasteboard.general.pasteboardItems?.map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
            } ?? []
            defer {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(saved.map { data in
                    let item = NSPasteboardItem(); for (type, bytes) in data { item.setData(bytes, forType: type) }; return item
                })
            }
            view.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == text.substring(with: range))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/paseo-reply-selection-mac-\(Int(width)).png"))
            #else
            let saved = UIPasteboard.general.items
            defer { UIPasteboard.general.items = saved }
            view.copy(nil)
            #expect(UIPasteboard.general.string == text.substring(with: range))
            #expect(!view.isScrollEnabled)
            let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in host.drawHierarchy(in: host.bounds, afterScreenUpdates: true) }
            try #require(image.pngData()).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paseo-reply-selection-ios-\(Int(width)).png"))
            #endif
            let coordinator = try #require(view.delegate as? ReplyTextCoordinator)
            #if os(iOS)
            #expect(view.becomeFirstResponder())
            #endif
            view.replySelectedRange = range
            coordinator.update(document(source + "\n\n切回输入框后恢复"))
            #if os(macOS)
            #expect(window.makeFirstResponder(nil))
            #else
            #expect(view.resignFirstResponder())
            #endif
            coordinator.changed()
            #expect(view.replyStorage.string.hasSuffix("切回输入框后恢复"))
            // 同一容器超过多屏：选择末尾时由外层会话滚动，不能嵌套滚动或裁掉末段。
            let long = (1...60).map { "第\($0)段：" + String(repeating: "跨段选择中文和 emoji 👋。", count: 6) }.joined(separator: "\n\n") + "\n\n末尾定位标记"
            model.text = long
            let longDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat { layout(); await Task.yield() } while (!view.replyStorage.string.hasSuffix("末尾定位标记") || view.bounds.height < 700) && ContinuousClock.now < longDeadline
            #expect(view.replyStorage.string.hasSuffix("末尾定位标记"))
            #expect(view.bounds.height > 700)
            let endRange = (view.replyStorage.string as NSString).range(of: "末尾定位标记")
            #if os(macOS)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 0, length: NSMaxRange(endRange)))
            view.scrollRangeToVisible(endRange)
            let glyphs = view.layoutManager!.glyphRange(forCharacterRange: endRange, actualCharacterRange: nil)
            let endRect = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
            #expect(view.convert(endRect, to: host).minY >= 0)
            #expect(view.enclosingScrollView!.contentView.bounds.origin.y > 0)
            #else
            #expect(view.becomeFirstResponder())
            view.selectedRange = NSRange(location: 0, length: NSMaxRange(endRange))
            view.revealMovingSelection()
            let endRect = view.caretRect(for: view.endOfDocument)
            #expect(view.convert(endRect, to: host).maxY <= host.bounds.maxY + 1)
            #expect(!view.isScrollEnabled)
            #endif
        }
    }

    private func surfaces(_ root: PlatformView) -> [ReplyNativeTextView] {
        if let view = root as? ReplyNativeTextView { return [view] }
        return root.subviews.flatMap { surfaces($0) }
    }
}

@Observable @MainActor private final class ReplyFixture {
    var text: String
    init(text: String) { self.text = text }
}

private struct ReplyFixtureView: View {
    let model: ReplyFixture
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TimelineItemView(item: .row(TimelineRow(id: "reply", turnId: nil, timestamp: Date(),
                    item: .assistantMessage(text: model.text, messageId: nil), isStreaming: false, isPending: false), footer: true))
            }.padding(16)
        }
    }
}

#if os(iOS)
@MainActor private final class ReplyStorageObserver: NSObject, @preconcurrency NSTextStorageDelegate {
    var edits = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { edits += 1 }
    }
}
#endif
