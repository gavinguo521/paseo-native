import SwiftUI
import Testing
@testable import Paseo
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Suite(.serialized) @MainActor struct ReplyTextTests {
    private let source = """
    ## 原位选择长回复

    第一段包含**粗体**、*强调*和中文 👨‍👩‍👧‍👦，从这里开始选择。

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

    @Test func mountedReplyHasOneSelectionSurfaceAndFitsReadingColumn() async throws {
        for width: CGFloat in [390, 820] {
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
            #expect(view.bounds.width <= width - 31)
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
        ScrollView { MarkdownView(text: model.text, continuousSelection: true).padding(16) }
    }
}
