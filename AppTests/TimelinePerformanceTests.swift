import Testing
import Foundation
import CoreGraphics
import ImageIO
import SwiftUI
import PaseoKit
@testable import Paseo

@Suite @MainActor struct TimelinePerformanceTests {
    private func entry(_ seq: Int, _ item: JSONValue) -> JSONValue {
        ["seqStart": .number(Double(seq)), "seqEnd": .number(Double(seq)), "item": item]
    }

    private func history(turns: Int) -> AgentTimeline {
        var entries: [JSONValue] = []
        for i in 0..<turns {
            entries += [
                entry(i * 3, ["type": "user_message", "text": .string("问题 \(i)"), "messageId": .string("u\(i)")]),
                entry(i * 3 + 1, ["type": "assistant_message", "text": "正在分析。"]),
                entry(i * 3 + 2, ["type": "assistant_message", "text": .string(String(repeating: "已完成的回复。", count: 100))]),
            ]
        }
        var timeline = AgentTimeline()
        timeline.applyPage(["direction": "tail", "epoch": "e1", "entries": .array(entries),
                            "startCursor": ["seq": 0], "endCursor": ["seq": .number(Double(turns * 3 - 1))]])
        return timeline
    }

    @Test func sessionReturnPreferenceDefaultsToLatestAndCanRestoreHistory() {
        let reading = TimelineReadingState()
        reading.hasPosition = true; reading.atBottom = false
        reading.firstRowID = "first"; reading.offset = 420
        #expect(!reading.shouldRestorePosition(enabled: false, liveFirstRowID: "first"))
        #expect(reading.shouldRestorePosition(enabled: true, liveFirstRowID: "first"))
        #expect(!reading.shouldRestorePosition(enabled: true, liveFirstRowID: "replaced"))
        reading.historyWindow = history(turns: 5)
        #expect(reading.shouldRestorePosition(enabled: true, liveFirstRowID: "replaced"))
        #expect(!reading.shouldRestorePosition(enabled: false, liveFirstRowID: "replaced"))
        reading.atBottom = true
        #expect(!reading.shouldRestorePosition(enabled: true, liveFirstRowID: "first"))
        reading.hasPosition = false; reading.atBottom = false
        #expect(!reading.shouldRestorePosition(enabled: true, liveFirstRowID: "first"))
    }

    @Test func renderWindowBoundsFirstLayoutAndPreservesReadingAcrossLiveAppend() {
        let items = DisplayItem.build(history(turns: 100).rows, lastTurnActive: false)
        var window = TimelineRenderWindow()
        #expect(window.visible(items).count == TimelineRenderWindow.pageSize)
        #expect(window.visible(items).last?.id == items.last?.id)
        window.pin(items)
        let first = window.visible(items).first?.id
        let more = DisplayItem.build(history(turns: 101).rows, lastTurnActive: false)
        #expect(window.visible(more).first?.id == first)
        #expect(window.visible(more).last?.id == more.last?.id)
        window.revealOlder(more)
        #expect(window.visible(more).contains { $0.id == first })
        #expect(window.visible(more).first?.id != first)
        for _ in 0..<100 { window.revealOlder(more) }
        #expect(window.visible(more).count == more.count)
        // Persisted reading starts can be restored; a replaced timeline safely falls back to its tail.
        let restored = TimelineRenderWindow(startID: first)
        #expect(restored.visible(more).first?.id == first)
        #expect(restored.visible([]).isEmpty)
        #expect(TimelineRenderWindow(startID: "missing").visible(more).count == TimelineRenderWindow.pageSize)
    }

    private func describe(_ items: [DisplayItem]) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .row(let row, let footer, let turn):
                ["\(row.id)|\(row.item)|\(row.isPending)|\(footer)|\(turn?.text ?? "")"]
            case .group(let id, let rows): [id] + rows.map { "\($0.id)|\($0.item)" }
            case .turnSummary(let id, let label, let hidden): [id, label] + describe(hidden)
            }
        }
    }

    @Test func incrementalTurnsMatchFullBuildAcrossStreamingAndReplacement() {
        let cache = DisplayItemCache()
        var timeline = history(turns: 50)
        for i in 0..<30 {
            _ = timeline.applyStream(["epoch": "e1", "seq": .number(Double(150 + i)),
                "event": ["type": "timeline", "item": ["type": "assistant_message", "text": "新增内容"]]])
            for collapse in [true, false] {
                let actual = cache.items(timeline, lastTurnActive: true, collapse: collapse, separateReasoning: true)
                let expected = DisplayItem.build(timeline.rows, lastTurnActive: true, collapse: collapse, separateReasoning: true)
                #expect(describe(actual) == describe(expected))
            }
        }
        // 同 id 的整页替换不可复用旧文案；完成后底栏和折叠也必须更新。
        timeline = history(turns: 50)
        #expect(describe(cache.items(timeline, lastTurnActive: false, collapse: true, separateReasoning: false))
                == describe(DisplayItem.build(timeline.rows, lastTurnActive: false)))
    }

    @Test func incrementalMarkdownMatchesFullParserAtEveryChunk() {
        let samples = [
            "# 标题\n\n正文 **粗体**\n第二行\n\n- 第一项\n  继续\n- 第二项\n\n结束",
            "前言\n\n```swift\nlet x = 1\n\nprint(x)\n```\n\n后文",
            "| 名字 | 数值 |\n| :--- | ---: |\n| A | 1 |\n\n> 引用\n> 第二行\n\n![截图](file:///tmp/a.png)",
            "~~~\n未闭合代码\n\n仍在代码块内",
        ]
        for sample in samples {
            let cache = MarkdownRenderCache()
            var text = ""
            for character in sample {
                text.append(character)
                #expect(String(reflecting: cache.blocks(text)) == String(reflecting: MarkdownBlock.parse(text)))
            }
            // 服务端重写、回退与清空也要正确。
            for replacement in ["改写\n\n新段落", "", sample] {
                #expect(String(reflecting: cache.blocks(replacement)) == String(reflecting: MarkdownBlock.parse(replacement)))
            }
        }
    }

    @Test func searchWindowIsBoundedAndDoesNotMutateLiveTimeline() {
        let timeline = history(turns: 500)
        let window = timeline.window(around: "u250")
        #expect(window?.rows.count == 81)
        #expect(window?.rows.contains { $0.id == "u250" } == true)
        #expect(timeline.rows.count == 1500)
        #expect(timeline.window(around: "missing") == nil)
    }

    @Test func historyCacheReusesSnapshotAndFollowsLiveChanges() throws {
        let history = history(turns: 20)
        var live = history
        let cache = TimelineHistoryCache()
        let first = try #require(cache.snapshot(history, live: live))
        #expect(cache.snapshot(history, live: live)?.revision == first.revision)
        _ = live.applyStream(["epoch": "e1", "seq": 60,
            "event": ["type": "timeline", "item": ["type": "assistant_message", "text": "后续输出"]]])
        let next = try #require(cache.snapshot(history, live: live))
        #expect(String(reflecting: next.rows.last?.item) == String(reflecting: live.rows.last?.item))
        #expect(next.revision != first.revision)
    }

    @Test func imageThumbnailAndOriginalRespectPhotoOrientation() async throws {
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        let reader = HostFileReader { _ in data }
        let loader = TimelineImageLoader()
        let thumbnail = try #require(await loader.image(key: "oriented", url: "/photo.jpg", snapshotKey: nil, maxPixel: 20, reader: reader))
        let original = try #require(await loader.image(key: "oriented", url: "/photo.jpg", snapshotKey: nil, maxPixel: nil, reader: reader))
        #expect(thumbnail.width == 10 && thumbnail.height == 20)
        #expect(original.width == 40 && original.height == 80)
    }

    @Test func markdownRendersAtPhoneAndDesktopWidths() throws {
        let text = """
        ## 原生体验回归样本

        流式回复包含 **粗体**、`代码` 和可以换行的中文段落。窄屏上正文应当自然折行。

        | 操作 | 预期 |
        | --- | --- |
        | 切回会话 | 保留正在阅读的位置和展开的工具组 |
        | 搜索长历史 | 仅展示命中附近的消息，仍能返回最新内容 |

        ```swift
        let message = "你好"
        print(message)
        ```

        > 这个样本只在测试中渲染。
        """
        var heights: [Int] = []
        for width: CGFloat in [360, 900] {
            let view = MarkdownView(text: text).padding(20).frame(width: width)
                .background(Color.white).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(width) && image.height > 200)
            heights.append(image.height)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-1535-markdown-\(Int(width)).png")
            let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil)
            #expect(CGImageDestinationFinalize(output))
            print("RENDER \(url.path)")
        }
        #expect(heights[0] > heights[1])
    }

    @Test func reportStreamingDerivationCost() {
        var timeline = history(turns: 300)
        let cache = DisplayItemCache()
        _ = cache.items(timeline, lastTurnActive: true, collapse: true, separateReasoning: false)
        let clock = ContinuousClock()
        var cached = Duration.zero
        var full = Duration.zero
        for i in 0..<100 {
            _ = timeline.applyStream(["epoch": "e1", "seq": .number(Double(900 + i)),
                "event": ["type": "timeline", "item": ["type": "assistant_message", "text": "片段"]]])
            cached += clock.measure { _ = cache.items(timeline, lastTurnActive: true, collapse: true, separateReasoning: false) }
            full += clock.measure { _ = DisplayItem.build(timeline.rows, lastTurnActive: true) }
        }
        print("PERF 300 turns / 100 chunks: cached=\(cached), full=\(full)")
    }
}
