import Foundation

/// A compact display projection. The original conversation and sent messages are never rewritten.
public enum WatchMessageText {
    public static func compact(_ text: String, role: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let answerHeader = "Answers to your questions:"
        if role == "user", value.hasPrefix(answerHeader) {
            value = String(value.dropFirst(answerHeader.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Generated answers contain one question/answer block per paragraph.
            value = value.components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { block in
                let lines = block.components(separatedBy: "\n")
                return lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : block
            }.joined(separator: "\n")
        }
        var result: [String] = []
        var fence: String?
        for line in value.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                result.append(line)
                continue
            }
            if fence == nil {
                let symbols = trimmed.filter { !$0.isWhitespace }
                if symbols.count >= 3, Set(symbols).count == 1, let symbol = symbols.first, "-*_".contains(symbol) { continue }
                if trimmed.isEmpty, result.isEmpty || result.last == "" { continue }
                result.append(trimmed)
            } else { result.append(line) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
