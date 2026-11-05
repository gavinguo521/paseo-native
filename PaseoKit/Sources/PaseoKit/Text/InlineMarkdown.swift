import Foundation

/// Inline Markdown for message text: Foundation's parser (GFM) with bare URLs fenced first.

public enum InlineMarkdown {
    nonisolated(unsafe) private static let url = try! NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()+,;=%]+"#)
    nonisolated(unsafe) private static let codeSpan = try! NSRegularExpression(pattern: "(`+)[\\s\\S]*?\\1")

    public static func parse(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: fenceBareURLs(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// GFM autolinks run until whitespace, so in Chinese text a bare URL swallows what follows it (「（公开）。看板」)
    /// and a closing `**`. Bare URLs get <…> around their ASCII URL characters, trailing punctuation left outside.
    public static func fenceBareURLs(_ s: String) -> String {
        guard s.contains("://") else { return s }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        let code = codeSpan.matches(in: s, range: full).map(\.range)
        var out = "", last = 0
        for m in url.matches(in: s, range: full) {
            var r = m.range
            if code.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let before = ns.substring(to: r.location)
            if before.hasSuffix("<") || before.hasSuffix("](") || before.hasSuffix("[") { continue }
            // trailing punctuation and unbalanced closing brackets belong to the sentence, not the URL
            while r.length > 0 {
                let t = ns.substring(with: r), c = t.last!
                let unbalanced = (c == ")" && t.filter { $0 == ")" }.count > t.filter { $0 == "(" }.count)
                    || (c == "]" && t.filter { $0 == "]" }.count > t.filter { $0 == "[" }.count)
                if ".,;:!?'".contains(c) || unbalanced { r.length -= 1 } else { break }
            }
            if ns.substring(from: r.location + r.length).hasPrefix("](") { continue }
            out += ns.substring(with: NSRange(location: last, length: r.location - last)) + "<" + ns.substring(with: r) + ">"
            last = r.location + r.length
        }
        return last == 0 ? s : out + ns.substring(from: last)
    }
}
