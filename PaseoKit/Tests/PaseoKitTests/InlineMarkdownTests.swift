import Foundation
import Testing
@testable import PaseoKit

private func links(_ s: String) -> [String] {
    let a = InlineMarkdown.parse(s)
    return a.runs.filter { $0.link != nil }.map { String(a[$0.range].characters) }
}

private func bold(_ s: String) -> [String] {
    let a = InlineMarkdown.parse(s)
    return a.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.map { String(a[$0.range].characters) }
}

/// 用户报告：中文里加粗的裸链接把后面的「（公开，Apache-2.0）。看板」吞进链接，两边的 ** 原样显示。
@Test func bareURLInChineseStopsAtURLEnd() {
    let s = "项目已经开源了：**https://github.com/52216108/paseo-native**（公开，Apache-2.0）。看板 #1520 已置为待验收。"
    #expect(links(s) == ["https://github.com/52216108/paseo-native"])
    #expect(bold(s) == ["https://github.com/52216108/paseo-native"])
    #expect(!String(InlineMarkdown.parse(s).characters).contains("**"))
}

@Test func bareURLPunctuationAndBrackets() {
    #expect(links("（https://example.com/x）末尾。") == ["https://example.com/x"])
    #expect(links("见 https://example.com/a_(b)，然后") == ["https://example.com/a_(b)"])
    #expect(links("普通 https://d.com/p?q=1&r=2. 结尾") == ["https://d.com/p?q=1&r=2"])
}

@Test func existingLinksAndCodeUntouched() {
    #expect(InlineMarkdown.fenceBareURLs("代码 `https://x.com/a**b` 不动") == "代码 `https://x.com/a**b` 不动")
    #expect(links("[https://a.com](https://a.com) 和 <https://b.com> 和 [文档](https://c.com/d)") == ["https://a.com", "https://b.com", "文档"])
}
