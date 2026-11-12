import Foundation

/// Display-only interpretation of the daemon's generated question reply. Never changes
/// the original message, which remains available for copying, searching and sending.
public struct QuestionAnswerTranscript: Codable, Equatable, Sendable {
    private static let header = "Answers to your questions:"
    public struct Entry: Codable, Equatable, Sendable {
        public var question: String
        public var answer: String
        public init(question: String, answer: String) { self.question = question; self.answer = answer }
    }

    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    public init?(text: String, role: String) {
        let header = Self.header
        let value = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user", value.hasPrefix(header + "\n\n") else { return nil }
        let body = String(value.dropFirst(header.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [Entry] = []
        // The daemon separates question/answer pairs with a blank line, and puts
        // the answer on the line after the question. Retain continuation paragraphs.
        for block in body.components(separatedBy: "\n\n") where !block.isEmpty {
            let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if lines.count == 2 {
                let question = String(lines[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let answer = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty, !answer.isEmpty else { return nil }
                entries.append(Entry(question: question, answer: answer))
            } else if !entries.isEmpty {
                entries[entries.count - 1].answer += "\n\n" + block
            } else { return nil }
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    public func formatted(questionLabel: String, answerLabel: String) -> String {
        entries.map { "\(questionLabel)\n\($0.question)\n\n\(answerLabel)\n\($0.answer)" }.joined(separator: "\n\n")
    }

    /// Reuse the existing text field on the watch wire, including its size limit.
    /// The watch interprets this projection with the same parser as the main app.
    public func messagePreview(limit: Int) -> (text: String, truncated: Bool) {
        let overhead = Self.header.count + entries.count * 3
        let preview = limited(to: max(0, limit - overhead))
        let text = Self.header + "\n\n" + preview.entries.map { "\($0.question)\n\($0.answer)" }.joined(separator: "\n\n")
        return (String(text.prefix(max(0, limit))), preview != self || text.count > limit)
    }

    /// Keep both sides visible within the watch bridge's message budget.
    public func limited(to characterLimit: Int) -> Self {
        let fields = entries.flatMap { [$0.question, $0.answer] }
        let lengths = fields.map(\.count)
        guard lengths.reduce(0, +) > max(0, characterLimit) else { return self }
        // Short answers leave their unused budget for longer questions (and vice versa).
        var remaining = max(0, characterLimit)
        var limits = Array(repeating: 0, count: fields.count)
        for (offset, index) in lengths.indices.sorted(by: { lengths[$0] < lengths[$1] }).enumerated() {
            limits[index] = min(lengths[index], remaining / (fields.count - offset))
            remaining -= limits[index]
        }
        return Self(entries: entries.enumerated().map { index, entry in
            Entry(question: String(entry.question.prefix(limits[index * 2])),
                  answer: String(entry.answer.prefix(limits[index * 2 + 1])))
        })
    }
}
