import Foundation
import Testing
@testable import PaseoWatchBridge

@Test func generatedReplySeparatesQuestionAndAnswerWithoutEnglishHeading() throws {
    let input = "Answers to your questions:\n\n请打开弹窗，完成后回复我。\n已切换并打开弹窗"
    let transcript = try #require(QuestionAnswerTranscript(text: input, role: "user"))
    #expect(transcript.entries == [.init(question: "请打开弹窗，完成后回复我。", answer: "已切换并打开弹窗")])
    #expect(transcript.formatted(questionLabel: "提问", answerLabel: "回答") == "提问\n请打开弹窗，完成后回复我。\n\n回答\n已切换并打开弹窗")
}

@Test func generatedReplyPreservesMultipleQuestionsAndAnswerLines() throws {
    let input = "Answers to your questions:\r\n\r\n设备已解锁吗？\r\n已解锁\r\n\r\n结果如何？\r\n锁屏时失败\r\n解锁后恢复\r\n\r\n补充：现在正常。"
    let transcript = try #require(QuestionAnswerTranscript(text: input, role: "user"))
    #expect(transcript.entries == [
        .init(question: "设备已解锁吗？", answer: "已解锁"),
        .init(question: "结果如何？", answer: "锁屏时失败\n解锁后恢复\n\n补充：现在正常。")
    ])
}

@Test func ordinaryQuotedAndIncompleteMessagesAreNotReinterpreted() {
    #expect(QuestionAnswerTranscript(text: "问题\n回答", role: "user") == nil)
    #expect(QuestionAnswerTranscript(text: "Answers to your questions:\n\n问题\n回答", role: "assistant") == nil)
    #expect(QuestionAnswerTranscript(text: "引用：Answers to your questions:\n\n问题\n回答", role: "user") == nil)
    #expect(QuestionAnswerTranscript(text: "Answers to your questions:\n\n未完成的问题", role: "user") == nil)
}

@Test func watchBudgetKeepsShortAnswersAndUsesSpareSpaceForQuestion() {
    let short = QuestionAnswerTranscript(entries: [.init(question: String(repeating: "问", count: 650), answer: "完成")])
    #expect(short.limited(to: 800) == short)
    let long = QuestionAnswerTranscript(entries: [.init(question: String(repeating: "👨‍👩‍👧‍👦", count: 1000), answer: "已完成")])
    let limited = long.limited(to: 800)
    #expect(limited.entries[0].question.count == 797)
    #expect(limited.entries[0].answer == "已完成")
    #expect(long.limited(to: -1).entries == [.init(question: "", answer: "")])
    #expect(QuestionAnswerTranscript(entries: []).limited(to: 0).entries.isEmpty)
}

@Test func watchProjectionFitsExistingTextBudgetAndRetainsBothSides() throws {
    let transcript = QuestionAnswerTranscript(entries: [
        .init(question: String(repeating: "问题", count: 800), answer: "完成"),
        .init(question: "可以继续吗？", answer: "可以")
    ])
    let preview = transcript.messagePreview(limit: 800)
    #expect(preview.text.count == 800)
    #expect(preview.truncated)
    let parsed = try #require(QuestionAnswerTranscript(text: preview.text, role: "user"))
    #expect(parsed.entries.count == 2)
    #expect(parsed.entries[0].answer == "完成")
    #expect(parsed.entries[1].question == "可以继续吗？")
    #expect(parsed.entries[1].answer == "可以")
    let message = WatchMessage(id: "question", role: "user", text: preview.text, truncated: preview.truncated)
    #expect(try JSONDecoder().decode(WatchMessage.self, from: JSONEncoder().encode(message)) == message)
}
