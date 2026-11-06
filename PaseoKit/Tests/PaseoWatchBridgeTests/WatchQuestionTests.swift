import Foundation
import Testing
@testable import PaseoWatchBridge

private func formData(_ questions: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
    var input = extra
    input["questions"] = questions
    return try JSONSerialization.data(withJSONObject: input)
}

private func yesNoQuestion(header: String = "问题 1") -> [String: Any] {
    ["id": "0", "header": header, "question": "能在手表上直接选择并提交吗？", "isOther": true,
     "options": [["label": "是"], ["label": "否"]]]
}

@Test func questionSnapshotBecomesReadableTextAndChoices() throws {
    let form = try WatchQuestionForm(inputData: formData([yesNoQuestion()]))
    #expect(form.questions.count == 1)
    #expect(form.questions[0].text == "能在手表上直接选择并提交吗？")
    #expect(form.questions[0].options.map(\.label) == ["是", "否"])
    #expect(form.questions[0].allowsOther)
    #expect(!form.questions[0].multiSelect)
}

@Test func noIsAnAnswerAndUpdatedInputPreservesProviderFields() throws {
    let data = try formData([yesNoQuestion()], extra: ["providerToken": "keep", "answers": ["old": "old"]])
    let form = try WatchQuestionForm(inputData: data)
    let updated = try form.updatedInput(data, answers: ["问题 1": .init(selectedOptions: ["否"])])
    let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
    #expect(object["answers"] as? [String: String] == ["问题 1": "否"])
    #expect(object["providerToken"] as? String == "keep")
    let questions = try #require(object["questions"] as? [[String: Any]])
    #expect(questions[0]["id"] as? String == "0")
    #expect(questions[0]["isOther"] as? Bool == true)
}

@Test func multiSelectDoesNotSplitLabelsContainingCommas() throws {
    let form = try WatchQuestionForm(inputData: formData([
        ["header": "targets", "question": "Choose targets", "multiSelect": true,
         "options": [["label": "iPhone, iPad"], ["label": "Watch"]]]
    ]))
    let answers = try form.validatedAnswers(["targets": .init(selectedOptions: ["Watch", "iPhone, iPad"])])
    #expect(answers == ["targets": "iPhone, iPad, Watch"])
}

@Test func freeTextUsesQuestionAsMissingHeaderAndTrimsWhitespace() throws {
    let form = try WatchQuestionForm(inputData: formData([["question": "下一步做什么？"]]))
    #expect(try form.validatedAnswers(["下一步做什么？": .init(text: "  继续测试 👋\n")]) == ["下一步做什么？": "继续测试 👋"])
}

@Test func answersMustCoverEveryQuestionWithoutUnknownKeys() throws {
    let form = try WatchQuestionForm(inputData: formData([yesNoQuestion(header: "one"), yesNoQuestion(header: "two")]))
    #expect(throws: WatchQuestionError.self) { try form.validatedAnswers(["one": .init(selectedOptions: ["是"])]) }
    #expect(throws: WatchQuestionError.self) {
        try form.validatedAnswers(["one": .init(selectedOptions: ["是"]), "two": .init(selectedOptions: ["否"]), "extra": .init(text: "unknown")])
    }
    #expect(try form.validatedAnswers(["one": .init(selectedOptions: ["是"]), "two": .init(selectedOptions: ["否"])]) == ["one": "是", "two": "否"])
}

@Test func invalidSelectionsAndEmptyAnswersCannotBeSubmitted() throws {
    let form = try WatchQuestionForm(inputData: formData([yesNoQuestion()]))
    let invalid: [WatchQuestionAnswer] = [
        .init(), .init(text: " \n"), .init(selectedOptions: ["unknown"]),
        .init(selectedOptions: ["是", "否"]), .init(selectedOptions: ["是", "是"]),
        .init(selectedOptions: ["是"], text: "another answer"), .init(text: String(repeating: "x", count: 4_001))
    ]
    for answer in invalid {
        #expect(throws: WatchQuestionError.self) { try form.validatedAnswers(["问题 1": answer]) }
    }
}

@Test func explicitOtherRestrictionIsRespected() throws {
    var question = yesNoQuestion()
    question["isOther"] = false
    let form = try WatchQuestionForm(inputData: formData([question]))
    #expect(!form.questions[0].allowsOther)
    #expect(throws: WatchQuestionError.self) { try form.validatedAnswers(["问题 1": .init(text: "custom")]) }
    #expect(try form.validatedAnswers(["问题 1": .init(selectedOptions: ["否"])]) == ["问题 1": "否"])
}

@Test func duplicateAndUnsupportedFormsAreNotPartiallyDisplayed() throws {
    var secret = yesNoQuestion(); secret["isSecret"] = true
    var duplicateOptions = yesNoQuestion(); duplicateOptions["options"] = [["label": "是"], ["label": "是"]]
    var empty = yesNoQuestion(); empty["question"] = "  "
    let invalid: [[[String: Any]]] = [[], [yesNoQuestion(), yesNoQuestion()], [secret], [duplicateOptions], [empty],
                                     [["question": "No input", "options": [], "isOther": false]]]
    for questions in invalid {
        #expect(throws: (any Error).self) { try WatchQuestionForm(inputData: formData(questions)) }
    }
    #expect(throws: WatchQuestionError.self) { try WatchQuestionForm(inputData: Data(repeating: 32, count: 6_001)) }
}

@Test func changedQuestionCannotReuseOldAnswers() throws {
    let data = try formData([yesNoQuestion()])
    let form = try WatchQuestionForm(inputData: data)
    var changed = yesNoQuestion(); changed["question"] = "现在删除文件吗？"
    #expect(throws: WatchQuestionError.self) {
        try form.updatedInput(formData([changed]), answers: ["问题 1": .init(selectedOptions: ["是"])])
    }
    let permission = WatchPermission(id: "q", title: "问答", detail: "问题", revision: "new",
                                     actions: [.init(id: "allow", label: "提交", behavior: "allow")],
                                     kind: "question", questionForm: form)
    #expect(permission.action(id: "allow", expectedRevision: "old") == nil)
}

@Test func questionAnswersSurviveWireRoundTripAndLegacyRequestsDecode() throws {
    let request = WatchRequest(command: .permission(.init(hostID: "mini", agentID: "agent"), requestID: "q", revision: "rev", actionID: "allow"),
                               questionAnswers: ["问题 1": .init(selectedOptions: ["否"])])
    #expect(try WatchEnvelope.decode(WatchEnvelope(request: request).encoded()).request == request)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    legacy.removeValue(forKey: "questionAnswers")
    let decoded = try JSONDecoder().decode(WatchRequest.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.questionAnswers == nil)
    #expect(decoded.command == request.command)
    let permission = try JSONDecoder().decode(WatchPermission.self, from: Data(#"{"id":"q","title":"Test","detail":"npm test","revision":"rev","actions":[],"needsPhone":true}"#.utf8))
    #expect(permission.questionForm == nil)
    #expect(permission.kind == nil)
}

@Test func lostReceiptCannotTurnNoIntoYesOnRetry() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "watch-question-" + UUID().uuidString).appending(path: "ledger.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    var request = WatchRequest(command: .permission(.init(hostID: "mini", agentID: "agent"), requestID: "q", revision: "rev", actionID: "allow"),
                               questionAnswers: ["问题 1": .init(selectedOptions: ["否"])])
    let ledger = WatchActionLedger(file: file)
    _ = await ledger.execute(request) { .init(.uncertain, "awaiting receipt") }
    request.questionAnswers = ["问题 1": .init(selectedOptions: ["是"])]
    let result = await ledger.execute(request) { Issue.record("Changed answer must not be dispatched"); return .init(.confirmed, "wrong") }
    #expect(result.state == .notSent)
    let restarted = WatchActionLedger(file: file)
    let saved = await restarted.request(for: request.id)
    #expect(saved?.questionAnswers?["问题 1"]?.selectedOptions == ["否"])
}
