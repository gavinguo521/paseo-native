import Foundation
import Testing
@testable import PaseoWatchBridge

@Test func compactionPreservesQuestionForStructuredDisplay() {
    let input = "Answers to your questions:\n\n请把手表放在 Mac 附近，完成后告诉我。\n已靠近并解锁"
    #expect(WatchMessageText.compact(input, role: "user") == input)
}

@Test func multipleGeneratedAnswersKeepEachChoice() {
    let input = "Answers to your questions:\n\n设备已解锁吗？\n已解锁\n\n现在可以刷新吗？\n刷新和打开会话都正常"
    #expect(WatchMessageText.compact(input, role: "user") == input)
}

@Test func multilineAnswerAndOrdinaryMessagesKeepTheirContent() {
    let answer = "Answers to your questions:\n\n什么情况？\n手机锁屏后连接失败\n解锁后恢复"
    #expect(WatchMessageText.compact(answer, role: "user") == answer)
    let ordinary = "这是我的问题\n这是补充内容"
    #expect(WatchMessageText.compact(ordinary, role: "user") == ordinary)
    let quoted = "Answers to your questions:\n\nExample question\nExample answer"
    #expect(WatchMessageText.compact(quoted, role: "assistant") == quoted)
}

@Test func messagePreviewRemovesSeparatorsAndExcessBlankSpace() {
    #expect(WatchMessageText.compact("\n\n\n---\n\n定位到了：\n\n\n\n已修复。\n\n", role: "assistant") == "定位到了：\n\n已修复。")
}

@Test func codeFormattingAndSeparatorContentsArePreserved() {
    let code = "结果：\n\n```yaml\n---\nitems:\n  - one\n\n\n  - two\n```"
    #expect(WatchMessageText.compact(code, role: "assistant") == code)
}

@Test func messageTimestampRoundTripsAndOlderPayloadsStillDecode() throws {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    let message = WatchMessage(id: "m1", role: "assistant", text: "已完成", timestamp: time)
    let encoded = try JSONEncoder().encode(message)
    #expect(try JSONDecoder().decode(WatchMessage.self, from: encoded).timestamp == time)
    let legacy = Data(#"{"id":"m1","role":"assistant","text":"已完成","truncated":false}"#.utf8)
    #expect(try JSONDecoder().decode(WatchMessage.self, from: legacy).timestamp == nil)
}
