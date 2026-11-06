import AppKit
import SwiftUI
import Testing
@testable import Paseo

@MainActor struct TableClipboardTests {
    @Test func markdownCopyRoundTripsSpecialCharacters() throws {
        let values = [["项目", "说明"], ["a|b", "*原文*\\路径"], ["换行", "第一行\n第二行"]]
        let markdown = TableClipboard.markdown(values)
        let block = try #require(MarkdownBlock.parse(markdown).first)
        guard case .table(let rows, _) = block else { Issue.record("未渲染为表格"); return }
        let range = TableCellRange(anchor: .init(row: 0, column: 0), end: .init(row: 2, column: 1))
        #expect(range.cells(from: rows) == values)
        #expect(TableClipboard.rowsFromTSV(range.text(from: rows)) == values)
        #expect(range.markdown(from: rows) == markdown)
    }

    @Test func clipboardDetectionPreservesAmbiguousText() {
        let tsv = "功能\t状态\n总览\t通过"
        #expect(TableClipboard.converted(text: tsv, html: nil, tsv: nil) == nil)
        #expect(TableClipboard.converted(text: tsv, html: nil, tsv: nil, explicit: true) == TableClipboard.markdown([["功能", "状态"], ["总览", "通过"]]))
        #expect(TableClipboard.converted(text: tsv, html: nil, tsv: tsv) != nil)
        #expect(TableClipboard.rowsFromTSV("a\tb\nc") == nil)
        #expect(TableClipboard.rowsFromTSV("\"未闭合\tb") == nil)
        #expect(TableClipboard.rowsFromTSV("a\t\"一\n二\"\n") == [["a", "一\n二"]])
    }

    @Test func htmlTableUsesLocalTextOnly() {
        let html = "<html><head><style>table{color:red}</style></head><body><!--StartFragment--><table><tr><th>项目</th><th>说明</th></tr><tr><td>A&amp;B</td><td>一<br>二&#33;</td></tr></table><!--EndFragment--></body></html>"
        #expect(TableClipboard.rowsFromHTML(html) == [["项目", "说明"], ["A&B", "一\n二!"]])
        #expect(TableClipboard.rowsFromHTML("正文" + html) == nil)
        #expect(TableClipboard.rowsFromHTML("<table><tr><td colspan='2'>合并</td></tr></table>") == nil)
        #expect(TableClipboard.rowsFromHTML("<table><tr><td><img src='https://example.com/private'></td></tr></table>") == nil)
    }

    @Test func markdownWithoutOuterPipesIsPreserved() {
        let value = "项目 | 状态\n--- | ---\nA | 通过"
        #expect(TableClipboard.converted(text: value, html: nil, tsv: nil) == value)
        #expect(MarkdownBlock.parse(value).contains { if case .table(let rows, _) = $0 { rows.count == 2 } else { false } })
        let fenced = "```\n" + value + "\n```"
        #expect(TableClipboard.converted(text: fenced, html: nil, tsv: nil) == nil)
    }

    @Test func userBubbleRendersTableAtPhoneWidth() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = UserBubble(text: "这是我粘贴的表格：\n\n| 功能 | 状态 |\n| --- | --- |\n| 会话总览 | 已完成 |\n| 表格复制 | 待验收 |")
        let view = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        view.sizingOptions = []
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 500)
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/paseo-user-table-1544.png"))
    }
}
