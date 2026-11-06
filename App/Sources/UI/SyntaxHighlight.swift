// Lightweight syntax colouring for code blocks, file previews and diffs: comments, strings, numbers,
// keywords and type-like names. Regex based, per line, no grammar; good enough to read code at a glance.

import SwiftUI

enum SyntaxHighlight {
    /// Language id from a fenced-code tag or a file extension.
    static func language(for tagOrPath: String?) -> Language? {
        guard let raw = tagOrPath?.lowercased(), !raw.isEmpty else { return nil }
        let key = raw.contains(".") ? (raw as NSString).pathExtension : raw
        return aliases[key]
    }

    struct Language: Sendable {
        let keywords: Set<String>
        /// Line comment starters, e.g. "//" or "#".
        let lineComments: [String]
        let blockComment: (String, String)?
    }

    private static let cLike: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
                                             "return", "true", "false", "null", "nil", "try", "catch", "throw", "throws", "new", "this",
                                             "self", "super", "class", "struct", "enum", "interface", "extends", "implements", "import",
                                             "export", "from", "const", "let", "var", "func", "function", "public", "private", "protected",
                                             "static", "final", "async", "await", "in", "of", "is", "as", "where", "guard", "defer",
                                             "typeof", "instanceof", "void", "type", "protocol", "extension", "init", "deinit", "override",
                                             "package", "go", "chan", "map", "range", "fn", "impl", "trait", "mut", "pub", "use", "mod",
                                             "match", "loop", "yield", "undefined", "fileprivate", "internal", "some", "any", "inout",
                                             "lazy", "weak", "unowned", "mutating", "readonly", "abstract", "declare", "namespace", "val",
                                             "fun", "object", "when", "companion", "data", "sealed", "open", "suspend", "elif", "def"]
    private static let python: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as",
                                              "try", "except", "finally", "raise", "with", "lambda", "yield", "pass", "break",
                                              "continue", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await",
                                              "global", "nonlocal", "assert", "del", "self", "match", "case"]
    private static let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case",
                                             "esac", "function", "return", "export", "local", "readonly", "set", "unset", "echo",
                                             "cd", "exit", "source", "true", "false"]
    private static let sql: Set<String> = ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                                           "delete", "create", "table", "index", "alter", "drop", "join", "left", "right", "inner",
                                           "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct",
                                           "null", "is", "in", "primary", "key", "foreign", "references", "default", "unique",
                                           "union", "all", "case", "when", "then", "else", "end", "with", "returning"]

    private static let aliases: [String: Language] = {
        let c = Language(keywords: cLike, lineComments: ["//"], blockComment: ("/*", "*/"))
        let py = Language(keywords: python, lineComments: ["#"], blockComment: nil)
        let sh = Language(keywords: shell, lineComments: ["#"], blockComment: nil)
        let sq = Language(keywords: sql, lineComments: ["--"], blockComment: ("/*", "*/"))
        let data = Language(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComment: nil)
        var m: [String: Language] = [:]
        for k in ["swift", "ts", "tsx", "typescript", "js", "jsx", "javascript", "mjs", "cjs", "go", "rs", "rust", "java", "kt",
                  "kotlin", "c", "h", "cpp", "cc", "hpp", "m", "mm", "objc", "cs", "csharp", "dart", "scala", "php", "css", "scss", "vue"] { m[k] = c }
        for k in ["py", "python"] { m[k] = py }
        for k in ["sh", "bash", "zsh", "shell", "console", "fish"] { m[k] = sh }
        for k in ["sql", "psql", "mysql"] { m[k] = sq }
        for k in ["json", "jsonc", "yaml", "yml", "toml"] { m[k] = data }
        m["rb"] = py; m["ruby"] = py
        return m
    }()

    private static let tokenRegex = try! NSRegularExpression(pattern:
        #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?\b|[A-Za-z_][A-Za-z0-9_]*"#)

    /// Colours one line; `inBlock` carries an open /* */ comment across lines.
    static func line(_ text: String, _ lang: Language, inBlock: inout Bool) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        if inBlock, let (_, end) = lang.blockComment {
            if let r = rest.range(of: end) {
                out += colored(String(rest[..<r.upperBound]), comment)
                rest = rest[r.upperBound...]
                inBlock = false
            } else {
                return colored(text, comment)
            }
        }
        // Earliest comment start that is not inside a string (approximation: count quotes before it).
        var cut: (String.Index, Bool)?
        for marker in lang.lineComments + [lang.blockComment?.0].compactMap({ $0 }) {
            var search = rest.startIndex
            while let r = rest.range(of: marker, range: search..<rest.endIndex) {
                let before = rest[rest.startIndex..<r.lowerBound]
                let quotes = before.filter { $0 == "\"" }.count + before.filter { $0 == "'" }.count
                if quotes % 2 == 0 {
                    if cut == nil || r.lowerBound < cut!.0 { cut = (r.lowerBound, marker == lang.blockComment?.0) }
                    break
                }
                search = r.upperBound
            }
        }
        let codePart = cut.map { String(rest[..<$0.0]) } ?? String(rest)
        out += tokens(codePart, lang)
        if let (start, isBlock) = cut {
            let commentText = rest[start...]
            if isBlock, let end = lang.blockComment?.1 {
                let afterOpen = commentText.index(commentText.startIndex, offsetBy: 2, limitedBy: commentText.endIndex) ?? commentText.endIndex
                if let r = commentText.range(of: end, range: afterOpen..<commentText.endIndex) {
                    out += colored(String(commentText[..<r.upperBound]), comment)
                    var nested = false
                    out += line(String(commentText[r.upperBound...]), lang, inBlock: &nested)
                } else {
                    out += colored(String(commentText), comment)
                    inBlock = true
                }
            } else {
                out += colored(String(commentText), comment)
            }
        }
        return out
    }

    /// Whole snippet (code blocks); stops colouring past `limit` lines to stay fast.
    static func highlight(_ code: String, _ lang: Language, limit: Int = 4000) -> AttributedString {
        var out = AttributedString()
        var inBlock = false
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, l) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += i < limit ? line(String(l), lang, inBlock: &inBlock) : AttributedString(String(l))
        }
        return out
    }

    private static func tokens(_ s: String, _ lang: Language) -> AttributedString {
        var out = AttributedString()
        let ns = s as NSString
        var last = 0
        for m in tokenRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out += AttributedString(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            let tok = ns.substring(with: m.range)
            let first = tok.first!
            if first == "\"" || first == "'" || first == "`" {
                out += colored(tok, string)
            } else if first.isNumber {
                out += colored(tok, number)
            } else if lang.keywords.contains(tok) || lang.keywords.contains(tok.lowercased()) && lang.keywords.contains("select") {
                out += colored(tok, keyword)
            } else if first.isUppercase, tok.count > 1 {
                out += colored(tok, type)
            } else {
                out += AttributedString(tok)
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += AttributedString(ns.substring(from: last)) }
        return out
    }

    private static func colored(_ s: String, _ c: Color) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = c
        return a
    }

    // GitHub-ish palette that reads in light and dark.
    static let keyword = Color(light: 0xcf222e, dark: 0xff7b72)
    static let string = Color(light: 0x0a3069, dark: 0xa5d6ff)
    static let comment = Color(light: 0x6e7781, dark: 0x8b949e)
    static let number = Color(light: 0x0550ae, dark: 0x79c0ff)
    static let type = Color(light: 0x8250df, dark: 0xd2a8ff)
}
