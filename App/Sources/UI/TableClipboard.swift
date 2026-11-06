import Foundation
import UniformTypeIdentifiers

struct TablePasteRequest {
    let id = UUID()
    let text: String
}
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 仅处理剪贴板中的表格文本，不加载 HTML 资源，也不执行网页内容。
enum TableClipboard {
    static let tsvType = "public.tab-separated-values-text"

    static func insertion(_ table: String, into text: String, range: NSRange) -> String {
        let source = text as NSString
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        return (before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n")
            + table
            + (after.isEmpty || after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n")
    }

    static func markdown(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        let width = rows.map(\.count).max() ?? 0
        func line(_ cells: [String]) -> String {
            "| " + (0..<width).map { index in
                let value = index < cells.count ? cells[index] : ""
                return value.map { "\\|*_`[]<>".contains($0) ? "\\" + String($0) : String($0) }.joined()
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        return ([line(first), "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    /// 电子表格的双引号转义规则；只接受矩形，普通文本不会被猜测为表格。
    static func rowsFromTSV(_ source: String) -> [[String]]? {
        let chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, closed = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append(c); i += 1 }
                    else { quoted = false; closed = true }
                } else { cell.append(c) }
            } else if c == "\t" || c == "\n" {
                row.append(cell); cell = ""; closed = false
                if c == "\n" { rows.append(row); row = [] }
            } else if c == "\"", cell.isEmpty, !closed { quoted = true }
            else {
                guard !closed else { return nil }
                cell.append(c)
            }
            i += 1
        }
        guard !quoted else { return nil }
        if chars.last != "\n" { row.append(cell); rows.append(row) }
        guard let width = rows.first?.count, width > 1, rows.allSatisfy({ $0.count == width }) else { return nil }
        return rows
    }

    /// 常见网页/电子表格的 HTML table。复杂合并单元格和混合正文保留原文，不丢弃内容。
    static func rowsFromHTML(_ html: String) -> [[String]]? {
        func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func replacing(_ pattern: String, _ text: String, _ replacement: String = "") -> String {
            text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        let cleaned = replacing("(?s)<!--.*?-->|<head\\b[^>]*>.*?</head>|<style\\b[^>]*>.*?</style>|<script\\b[^>]*>.*?</script>", html)
        let tables = matches("<table\\b[^>]*>(.*?)</table\\s*>", cleaned)
        guard tables.count == 1, let table = tables.first else { return nil }
        let body = (cleaned as NSString).substring(with: table.range(at: 1))
        guard !body.lowercased().contains("<table"), !body.lowercased().contains("<caption"),
              matches("(?:rowspan|colspan)\\s*=\\s*['\"]?(?!1(?:['\"\\s>]))[0-9]+", body).isEmpty else { return nil }
        let outside = (cleaned as NSString).replacingCharacters(in: table.range, with: "")
        guard replacing("<[^>]*>", outside).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var rows: [[String]] = []
        for tr in matches("<tr\\b[^>]*>(.*?)</tr\\s*>", body) {
            let rowHTML = (body as NSString).substring(with: tr.range(at: 1))
            var row: [String] = []
            for td in matches("<t[dh]\\b[^>]*>(.*?)</t[dh]\\s*>", rowHTML) {
                let raw = (rowHTML as NSString).substring(with: td.range(at: 1))
                // 图片等非文本单元格交回原有粘贴路径。
                guard matches("<(?:img|svg|iframe|object)\\b", raw).isEmpty else { return nil }
                let text = replacing("<[^>]*>", replacing("<br\\s*/?>|</p\\s*>|</div\\s*>", raw, "\n"))
                guard let decoded = decodeEntities(text) else { return nil }
                row.append(decoded.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !row.isEmpty { rows.append(row) }
        }
        guard let width = rows.first?.count, width > 0, rows.allSatisfy({ $0.count == width }) else { return nil }
        return rows
    }

    private static func decodeEntities(_ text: String) -> String? {
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let key = (text as NSString).substring(with: match.range(at: 1))
            let value: String?
            if key.hasPrefix("#") {
                let hex = key.hasPrefix("#x")
                value = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            } else { value = entities[key] }
            guard let value, let range = Range(match.range, in: result) else { return nil }
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    static func converted(text: String?, html: String?, tsv: String?, explicit: Bool = false) -> String? {
        if let text, MarkdownBlock.parse(text).contains(where: { if case .table = $0 { true } else { false } }) { return text }
        if let html, let rows = rowsFromHTML(html) { return markdown(rows) }
        if let tsv, let rows = rowsFromTSV(tsv) { return markdown(rows) }
        if explicit, let text, let rows = rowsFromTSV(text) { return markdown(rows) }
        return nil
    }

    @MainActor static func pasted(explicit: Bool = false) -> String? {
        #if os(macOS)
        let pb = NSPasteboard.general
        return converted(text: pb.string(forType: .string), html: pb.string(forType: .html),
                         tsv: pb.string(forType: .init(tsvType)), explicit: explicit)
        #else
        let pb = UIPasteboard.general
        func string(_ type: String) -> String? {
            if let text = pb.value(forPasteboardType: type) as? String { return text }
            return pb.data(forPasteboardType: type).flatMap { String(data: $0, encoding: .utf8) }
        }
        return converted(text: pb.string, html: string(UTType.html.identifier), tsv: string(tsvType), explicit: explicit)
        #endif
    }

    @MainActor static func copyTSV(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(text, forType: .init(tsvType))
        #else
        UIPasteboard.general.items = [[UTType.utf8PlainText.identifier: text, tsvType: text]]
        #endif
    }
}
