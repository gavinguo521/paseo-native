import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct ResponsivenessTests {
    static let source = (0..<1200).map { "let value\($0) = \"流式代码 \($0)\" // comment" }.joined(separator: "\n")

    @Test func reportStreamingCodeBaseline() throws {
        let lang = try #require(SyntaxHighlight.language(for: "swift"))
        let cache = CodeRenderCache()
        var original = Duration.zero
        var code = Self.source
        var total = Duration.zero
        let clock = ContinuousClock()
        for i in 0..<40 {
            code += "\nlet tail\(i) = \(i)"
            original += clock.measure { _ = SyntaxHighlight.highlight(code, lang) }
            total += clock.measure { _ = cache.code(code, language: "swift") }
        }
        print("RESPONSIVENESS stream1200x40 old=\(original) new=\(total)")
    }

    @Test func reportLongConversationLayout() throws {
        for count in [16, 160] {
          for optimized in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let text = "## 固定历史回复\n\n" + String(repeating: "这是一段用于比较长会话布局的正文，包含 **粗体** 和 `代码`。", count: 5)
            let root = ScrollView {
                let layout = optimized ? AnyLayout(MeasuredStackExperiment()) : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                layout {
                    ForEach(0..<count, id: \.self) { _ in MarkdownView(text: text) }
                }.padding(20)
            }.defaultScrollAnchor(.bottom)
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            let elapsed = ContinuousClock().measure {
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
                view.layoutSubtreeIfNeeded()
            }
            print("RESPONSIVENESS history\(count) optimized=\(optimized) time=\(elapsed)")
          }
        }
    }
    @Test func incrementalHighlightMatchesWholeSnippet() throws {
        for language in ["swift", "python", "sql", "unknown"] {
            var cache = CodeHighlightCache()
            let sample = "let 标题 = \"你好 👨‍👩‍👧‍👦\"\n/* 跨行\n注释 */ let x = 1\n// 注释\nprint(x)"
            var text = ""
            for c in sample {
                text.append(c)
                let expected = SyntaxHighlight.language(for: language).map { SyntaxHighlight.highlight(text, $0) } ?? AttributedString(text)
                #expect(cache.highlight(text, language: language) == expected)
            }
            for replacement in ["", "let rewrite = 2", sample, "\n", "x\r\ny"] {
                let expected = SyntaxHighlight.language(for: language).map { SyntaxHighlight.highlight(replacement, $0) } ?? AttributedString(replacement)
                #expect(cache.highlight(replacement, language: language) == expected)
            }
        }
        var cache = CodeHighlightCache()
        let code = String(repeating: "let x = 1\n", count: 4002)
        for lang in ["swift", "python"] {
            #expect(cache.highlight(code, language: lang) == SyntaxHighlight.highlight(code, try #require(SyntaxHighlight.language(for: lang))))
        }
    }

    private func legacyNumbered(_ source: String) -> AttributedString {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).prefix(20000)
        let width = String(lines.count).count
        let lang = SyntaxHighlight.language(for: "swift")!
        var inBlock = false
        var out = AttributedString()
        for (i, l) in lines.enumerated() {
            var num = AttributedString(String(repeating: " ", count: width - String(i + 1).count) + "\(i + 1)  ")
            num.foregroundColor = Theme.extraMuted
            out += num
            out += i < 5000 ? SyntaxHighlight.line(String(l), lang, inBlock: &inBlock) : AttributedString(String(l))
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    private func textView(in view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @Test func reportLargeFileAndPreserveNativeSelection() async throws {
        let source = (0..<12000).map { "let value\($0) = \"文件 👨‍👩‍👧‍👦 \( $0)\" // comment" }.joined(separator: "\n")
        let clock = ContinuousClock()
        var old = AttributedString()
        let oldPrepare = clock.measure { old = legacyNumbered(source) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let oldView = NSHostingView(rootView: ScrollView([.vertical, .horizontal]) {
            Text(old).font(.system(size: Theme.code, design: .monospaced)).textSelection(.enabled).padding(14)
        })
        oldView.sizingOptions = []
        let oldLayout = clock.measure {
            window.contentView = oldView
            oldView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            oldView.layoutSubtreeIfNeeded()
        }
        let fontSize = Theme.code
        let fontName = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).fontName
        let start = clock.now
        let (document, prepareCPU) = try await Task.detached {
            let start = ContinuousClock.now
            let document = try FileSourceDocument(source, fontName: fontName, fontSize: fontSize)
            return (document, start.duration(to: .now))
        }.value
        let prepare = start.duration(to: clock.now)
        #expect(document.text == String(old.characters))
        let view = NSHostingView(rootView: NativeFileSource(document: document, language: "swift", target: nil))
        view.sizingOptions = []
        let layout = clock.measure {
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            view.layoutSubtreeIfNeeded()
        }
        let native = try #require(textView(in: view))
        let selected = NSRange(location: document.bodies[2].location, length: document.ranges[3].location - document.bodies[2].location + 10)
        native.setSelectedRange(selected)
        let worker = FileSourceHighlighter(lines: document.lines, language: "swift")
        let first = try await worker.through(160)
        #expect(first.count == 160)
        // 等正式视图的后台着色完成，不用固定延时猜完成时间。
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            let color = native.textStorage?.attribute(.foregroundColor, at: document.bodies[1].location, effectiveRange: nil) as? NSColor
            if color == NSColor(SyntaxHighlight.keyword) { break }
            await Task.yield()
        }
        #expect(native.textStorage?.attribute(.foregroundColor, at: document.bodies[1].location, effectiveRange: nil) as? NSColor == NSColor(SyntaxHighlight.keyword))
        #expect(native.selectedRange() == selected)
        #expect(native.string == document.text)
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/paseo-1555-file.png"))
        view.rootView = NativeFileSource(document: document, language: "swift", target: 11000)
        view.layoutSubtreeIfNeeded()
        #expect(native.visibleRect.minY > 1000)
        let manager = try #require(native.layoutManager)
        let container = try #require(native.textContainer)
        let glyphs = manager.glyphRange(forCharacterRange: document.ranges[10999], actualCharacterRange: nil)
        let targetRect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
        #expect(targetRect.intersects(native.visibleRect))
        #expect(native.selectedRange() == selected)
        print("RESPONSIVENESS file12000 oldPrepare=\(oldPrepare) oldLayout=\(oldLayout) newPrepareBackground=\(prepareCPU) awaitWall=\(prepare) newLayout=\(layout)")
    }


}


/// 仅测试中的候选布局：160 项样本未取得收益，不进入生产路径。
private struct MeasuredStackExperiment: Layout {
    var spacing: CGFloat = 14
    struct Cache {
        var width: CGFloat?
        var sizes: [CGSize] = []
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }
    private func measure(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.width == proposal.width, cache.sizes.count == subviews.count { return }
        cache.width = proposal.width
        cache.sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measure(proposal, subviews: subviews, cache: &cache)
        return CGSize(width: proposal.width ?? cache.sizes.map(\.width).max() ?? 0,
                      height: cache.sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, subviews.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(ProposedViewSize(width: bounds.width, height: nil), subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: cache.sizes[index].height))
            y += cache.sizes[index].height + spacing
        }
    }
}
