import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct InteractionPerformanceTests {
    private func history(_ count: Int, label: String = "回复") -> AgentTimeline {
        var entries: [JSONValue] = []
        for i in 0..<count {
            entries.append(["seqStart": .number(Double(i * 2)), "seqEnd": .number(Double(i * 2)),
                            "item": ["type": "user_message", "text": .string("问题\(i)"), "messageId": .string("u\(i)")]])
            entries.append(["seqStart": .number(Double(i * 2 + 1)), "seqEnd": .number(Double(i * 2 + 1)),
                            "item": ["type": "assistant_message", "text": .string("\(label)\(i)")]])
        }
        var result = AgentTimeline()
        result.applyPage(["direction": "tail", "epoch": "e1", "entries": .array(entries)])
        return result
    }

    @Test func fileSearchMatchesLegacyAndCancels() async throws {
        let source = (0..<20000).map { "let value\($0) = \"中文 👨‍👩‍👧‍👦 İ Ａ\"" }.joined(separator: "\n") + "\n"
        let index = FileSearchIndex()
        var old = Duration.zero, new = Duration.zero
        for query in ["v", "va", "value", "value19", "中文", "İ", "👨‍👩‍👧‍👦", "", "missing"] {
            let start = ContinuousClock.now
            let folded = query.lowercased()
            let expected = query.isEmpty ? [] : source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap {
                $1.lowercased().contains(folded) ? $0 + 1 : nil
            }
            old += start.duration(to: .now)
            let next = ContinuousClock.now
            let actual = try await index.matches(in: source, query: query)
            new += next.duration(to: .now)
            #expect(actual == expected)
        }
        let cancelled = Task { try await index.matches(in: source + "replacement", query: "value") }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("取消搜索没有停止") } catch is CancellationError { }
        #expect(try await index.matches(in: "新文件\nvalue\n", query: "value") == [2])
        print("INTERACTION fileSearch20000 old=\(old) indexedIncludingPrepare=\(new)")
    }

    @Test func markdownFenceAppendMatchesParser() {
        for sample in [
            "前言\n\n```swift\na\n\n b\n```\n后文",
            "~~~python\n你好 👨‍👩‍👧‍👦\n  ~~~suffix\n尾部",
            "```\na\n```", "```\na\n```\nx", "```\n\n``\n```\n~~~\nx",
            "```swift\r\nlet x = 1\r\n```\r\n",
            "```swift\na\r\n```\r\n后文",
            "前言\n\n```swift\na\r\n```\r\n后文",
            "| A | B |\n| --- | --- |\n| x | y |\n\n```\nx\n```"
        ] {
            let cache = MarkdownRenderCache()
            var growing = ""
            for char in sample {
                growing.append(char)
                #expect(String(reflecting: cache.blocks(growing)) == String(reflecting: MarkdownBlock.parse(growing)))
            }
            for rewritten in [sample + "追加", String(sample.prefix(7)), "", "```\n重写\n", sample] {
                #expect(String(reflecting: cache.blocks(rewritten)) == String(reflecting: MarkdownBlock.parse(rewritten)))
            }
        }
    }

    @Test func mixedNewlineFenceDoesNotSwallowFollowingParagraph() {
        let cache = MarkdownRenderCache()
        let closed = "```swift\na\r\n```\r\n"
        _ = cache.blocks(closed)
        #expect(String(reflecting: cache.blocks(closed + "后文")) == String(reflecting: MarkdownBlock.parse(closed + "后文")))
    }

    @Test func reportMarkdownTail() {
        let legacy = LegacyMarkdownCache1556(), cache = MarkdownRenderCache()
        var text = "说明\n\n```swift\n" + String(repeating: "let value = \"中文\"\n", count: 4000)
        var old = Duration.zero, new = Duration.zero
        for i in 0..<80 {
            text += "let tail\(i) = \(i)\n"
            let start = ContinuousClock.now
            let expected = legacy.blocks(text)
            old += start.duration(to: .now)
            let next = ContinuousClock.now
            let actual = cache.blocks(text)
            new += next.duration(to: .now)
            #expect(String(reflecting: actual) == String(reflecting: expected))
        }
        print("INTERACTION markdown4000x80 old=\(old) new=\(new)")
    }

    @Test func reportNativeSessionReentry() async throws {
        let host = HostStore(offer: .direct(serverId: "switch-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "切换测试", clientId: "test", appVersion: "test")
        host.agents["a"] = try #require(Agent(["id": "a", "status": "idle", "title": "切换测试", "cwd": "/test"]))
        let timeline = history(1500)
        host.timelines["a"] = timeline
        let model = AppModel(testHosts: [host])
        let cache = DisplayItemCache()
        _ = cache.items(timeline, lastTurnActive: false, collapse: true, separateReasoning: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var cold = Duration.zero, warm = Duration.zero
        for round in 0..<8 {
            for reused in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                window.contentView = nil
                await Task.yield()
                let start = ContinuousClock.now
                let view = NSHostingView(rootView: AgentView(host: host, agentId: "a", workspace: nil,
                    displayCache: reused ? cache : DisplayItemCache()).environment(model))
                view.sizingOptions = []
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
                view.layoutSubtreeIfNeeded()
                let elapsed = start.duration(to: .now)
                // 第一轮只预热 SwiftUI 和字体，两种方案交替顺序。
                if round > 0 {
                    if reused { warm += elapsed } else { cold += elapsed }
                }
            }
        }
        print("INTERACTION nativeReentry7 cold=\(cold) reused=\(warm)")
    }

    @Test func scrollAnchorAndSessionReuse() {
        let timeline = history(1500)
        let cache = DisplayItemCache()
        let items = cache.items(timeline, lastTurnActive: false, collapse: false, separateReasoning: true)
        var old = Duration.zero, new = Duration.zero
        for i in 0..<300 {
            let ids = Array(items.suffix(16 + i % 100).prefix(16).map(\.id).reversed()) + ["not-visible"]
            let start = ContinuousClock.now
            let visible = Set(ids)
            let expected = items.first { visible.contains($0.id) }?.id
            old += start.duration(to: .now)
            let next = ContinuousClock.now
            let actual = cache.firstVisibleID(in: ids)
            new += next.duration(to: .now)
            #expect(actual == expected)
        }
        #expect(cache.firstVisibleID(in: []) == nil)
        let pool = SessionDisplayCaches()
        let a = AgentRef(serverId: "host", agentId: "a"), b = AgentRef(serverId: "host", agentId: "b")
        let retained = pool.cache(for: a)
        _ = retained.items(timeline, lastTurnActive: false, collapse: false, separateReasoning: true)
        var cold = Duration.zero, warm = Duration.zero
        for _ in 0..<30 {
            _ = pool.cache(for: b)
            let start = ContinuousClock.now
            let original = DisplayItemCache().items(timeline, lastTurnActive: false, collapse: false, separateReasoning: true)
            cold += start.duration(to: .now)
            let next = ContinuousClock.now
            let cached = pool.cache(for: a).items(timeline, lastTurnActive: false, collapse: false, separateReasoning: true)
            warm += next.duration(to: .now)
            #expect(original.map(\.id) == cached.map(\.id))
        }
        let replaced = history(2, label: "替换后的内容")
        let refreshed = retained.items(replaced, lastTurnActive: true, collapse: true, separateReasoning: false)
        #expect(String(reflecting: refreshed) == String(reflecting: DisplayItem.build(replaced.rows, lastTurnActive: true, collapse: true, separateReasoning: false)))
        #expect(retained.firstVisibleID(in: [items.last!.id]) == nil)
        #expect(pool.cache(for: a) === retained)
        for i in 0..<9 { _ = pool.cache(for: AgentRef(serverId: "host", agentId: "other\(i)")) }
        #expect(pool.cache(for: a) !== retained)
        print("INTERACTION scroll300 old=\(old) newIncludingIndex=\(new); switch30 cold=\(cold) reused=\(warm)")
    }
}

@MainActor final class LegacyMarkdownCache1556 {
    private var text: String?
    private var stablePrefix = ""
    private var stableBlocks: [MarkdownBlock] = []
    private var value: [MarkdownBlock] = []
    private var inlines: [String: (query: String, value: AttributedString)] = [:]

    func blocks(_ next: String) -> [MarkdownBlock] {
        if text == next { return value }
        if !next.hasPrefix(stablePrefix) { stablePrefix = ""; stableBlocks = [] }
        let tail = String(next.dropFirst(stablePrefix.count))
        // 只有完整空行且不在代码围栏内才是稳定边界；表格、列表、未闭合围栏都留在尾部。
        var fence: String?
        var boundary = tail.startIndex
        var cursor = tail.startIndex
        while let newline = tail[cursor...].firstIndex(of: "\n") {
            let line = tail[cursor..<newline].trimmingCharacters(in: .whitespaces)
            let end = tail.index(after: newline)
            if let active = fence {
                if line.hasPrefix(active) { fence = nil }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
            } else if line.isEmpty { boundary = end }
            cursor = end
        }
        if boundary > tail.startIndex {
            let committed = String(tail[..<boundary])
            stableBlocks += MarkdownBlock.parse(committed)
            stablePrefix += committed
        }
        value = stableBlocks + MarkdownBlock.parse(String(tail[boundary...]))
        text = next
        let strings = Set(value.flatMap(\.inlineStrings))
        inlines = inlines.filter { strings.contains($0.key) }
        return value
    }

    func inline(_ text: String, query: String, _ make: () -> AttributedString) -> AttributedString {
        if let hit = inlines[text], hit.query == query { return hit.value }
        let value = make()
        inlines[text] = (query, value)
        return value
    }
}
