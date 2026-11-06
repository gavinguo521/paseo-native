import SwiftUI

/// 流式追加时只重新着色未完成的一行；完整行保留块注释状态。
/// 不保留历史文本版本，服务端重写或语言变化时重新计算。
struct CodeHighlightCache {
    private var language = ""
    private var previous = ""
    private var committed = ""
    private var colored = AttributedString()
    private var inBlock = false
    private var lineCount = 0
    private var value = AttributedString()

    mutating func highlight(_ code: String, language: String) -> AttributedString {
        if language == self.language, code == previous { return value }
        if language != self.language || !code.hasPrefix(committed) {
            self = CodeHighlightCache()
            self.language = language
        }
        let lang = SyntaxHighlight.language(for: language)
        let tail = code.dropFirst(committed.count)
        var start = tail.startIndex
        while let newline = tail[start...].firstIndex(of: "\n") {
            let line = String(tail[start..<newline])
            colored += Self.color(line, lang, inBlock: &inBlock, index: lineCount)
            colored += AttributedString("\n")
            committed += line + "\n"
            lineCount += 1
            start = tail.index(after: newline)
        }
        var tailInBlock = inBlock
        value = colored + Self.color(String(tail[start...]), lang, inBlock: &tailInBlock, index: lineCount)
        previous = code
        return value
    }

    private static func color(_ line: String, _ lang: SyntaxHighlight.Language?, inBlock: inout Bool, index: Int) -> AttributedString {
        guard let lang, index < 4000 else { return AttributedString(line) }
        return SyntaxHighlight.line(line, lang, inBlock: &inBlock)
    }
}
