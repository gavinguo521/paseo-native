import Foundation

public struct WatchQuestionOption: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var description: String?
    public var preview: String?
    public var id: String { label }
}

public struct WatchQuestion: Codable, Equatable, Sendable, Identifiable {
    /// The daemon's question form keys answers by header, not by its optional numeric ID.
    public var header: String
    public var text: String
    public var multiSelect: Bool
    public var allowsOther: Bool
    public var options: [WatchQuestionOption]
    public var id: String { header }

    public func answerText(_ answer: WatchQuestionAnswer) throws -> String {
        let custom = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            guard allowsOther, answer.selectedOptions.isEmpty, custom.utf8.count <= 4_000 else {
                throw WatchQuestionError.invalidAnswer
            }
            return custom
        }
        let selected = Set(answer.selectedOptions)
        guard !selected.isEmpty, selected.count == answer.selectedOptions.count,
              multiSelect || selected.count == 1,
              selected.isSubset(of: Set(options.map(\.label))) else { throw WatchQuestionError.invalidAnswer }
        return options.filter { selected.contains($0.label) }.map(\.label).joined(separator: ", ")
    }
}

public struct WatchQuestionAnswer: Codable, Equatable, Sendable {
    public var selectedOptions: [String]
    public var text: String?
    public init(selectedOptions: [String] = [], text: String? = nil) {
        self.selectedOptions = selectedOptions; self.text = text
    }
}

public struct WatchQuestionForm: Codable, Equatable, Sendable {
    public var questions: [WatchQuestion]

    /// Preserve complete question/option text; oversized or unsupported forms stay on the phone.
    public init(inputData: Data) throws {
        guard inputData.count <= 6_000 else { throw WatchQuestionError.unsupportedForm }
        let input = try JSONDecoder().decode(Input.self, from: inputData)
        guard (1...6).contains(input.questions.count) else { throw WatchQuestionError.unsupportedForm }
        questions = try input.questions.map { question in
            let header = question.header ?? question.question
            let options = question.options ?? []
            let allowsOther = question.isOther ?? true
            guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.isSecret != true, options.count <= 12,
                  !options.isEmpty || allowsOther,
                  options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(options.map(\.label)).count == options.count else { throw WatchQuestionError.unsupportedForm }
            return WatchQuestion(header: header, text: question.question, multiSelect: question.multiSelect ?? false,
                                 allowsOther: allowsOther, options: options)
        }
        guard Set(questions.map(\.id)).count == questions.count else { throw WatchQuestionError.unsupportedForm }
    }

    public func validatedAnswers(_ answers: [String: WatchQuestionAnswer]) throws -> [String: String] {
        guard Set(answers.keys) == Set(questions.map(\.id)) else { throw WatchQuestionError.invalidAnswer }
        return try Dictionary(uniqueKeysWithValues: questions.map { question in
            (question.header, try question.answerText(answers[question.id]!))
        })
    }

    /// Same updatedInput format as the phone's question form, including all original provider fields.
    public func updatedInput(_ inputData: Data, answers: [String: WatchQuestionAnswer]) throws -> Data {
        guard try Self(inputData: inputData) == self,
              var input = try JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
            throw WatchQuestionError.unsupportedForm
        }
        input["answers"] = try validatedAnswers(answers)
        return try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    }

    private struct Input: Decodable { var questions: [Question] }
    private struct Question: Decodable {
        var question: String
        var header: String?
        var multiSelect: Bool?
        var isOther: Bool?
        var isSecret: Bool?
        var options: [WatchQuestionOption]?
    }
}

public enum WatchQuestionError: Error { case unsupportedForm, invalidAnswer }
