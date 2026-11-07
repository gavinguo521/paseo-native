import UIKit
import Testing
@testable import Paseo

@Suite(.serialized) @MainActor struct TablePasteTests {
    @Test func longPasteBecomesAnAttachmentBeforeTextLayout() {
        let pb = UIPasteboard.general
        let previous = pb.items
        defer { pb.items = previous }
        let view = ComposerUITextView()
        view.text = "请检查这些日志"
        view.selectedRange = NSRange(location: 2, length: 2)
        let source = String(repeating: "Error: 日志内容 👨‍👩‍👧‍👦\n", count: 20000)
        var attachment: PastedTextAttachment?
        view.onLongText = { text in
            guard PastedTextAttachment.shouldAttach(text) else { return false }
            attachment = PastedTextAttachment(text)
            return true
        }
        pb.string = source
        view.paste(nil)
        #expect(view.text == "请检查这些日志")
        #expect(view.selectedRange == NSRange(location: 2, length: 2))
        #expect(attachment?.data == Data(source.utf8))
    }

    @Test func nativePasteReplacesSelectionAndKeepsOrdinaryTabs() {
        let pb = UIPasteboard.general
        let previous = pb.items
        defer { pb.items = previous }
        let view = ComposerUITextView()
        view.text = "前面替换后面"
        view.selectedRange = NSRange(location: 2, length: 2)
        let tsv = "项目\t状态\nA\t完成"
        pb.items = [["public.utf8-plain-text": tsv, TableClipboard.tsvType: tsv]]
        view.paste(nil)
        let markdown = TableClipboard.markdown([["项目", "状态"], ["A", "完成"]])
        #expect(view.text == "前面\n\n" + markdown + "\n\n后面")
        pb.string = tsv
        // 普通文本不拦截，交还系统已有的异步粘贴流程。
        #expect(TableClipboard.pasted() == nil)
    }
}
