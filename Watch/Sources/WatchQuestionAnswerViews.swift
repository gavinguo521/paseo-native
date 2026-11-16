import PaseoWatchBridge
import SwiftUI

struct WatchQuestionPrompt: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WatchQuestionSectionLabel(title: "提问")
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true).watchCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WatchQuestionSectionLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }
}

struct WatchMessageView: View {
    let message: WatchMessage
    var body: some View {
        if let transcript = QuestionAnswerTranscript(text: message.text, role: message.role) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(transcript.entries.enumerated()), id: \.offset) { _, entry in
                    WatchQuestionPrompt(text: entry.question)
                    VStack(alignment: .leading, spacing: 4) {
                        WatchQuestionSectionLabel(title: "回答")
                        Text(entry.answer).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                footer
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.role == "user" ? "你" : message.role == "error" ? "出错" : "Paseo")
                    Spacer(minLength: 4)
                    if let date = message.timestamp { Text(date, format: .dateTime.hour().minute()).monospacedDigit() }
                }.font(.caption2).foregroundStyle(.secondary)
                Text(message.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                if message.truncated { Text("仅显示部分内容").font(.caption2).foregroundStyle(.secondary) }
            }.watchCard()
        }
    }

    private var footer: some View {
        HStack {
            if message.truncated { Text("仅显示部分内容") }
            Spacer(minLength: 4)
            if let date = message.timestamp { Text(date, format: .dateTime.hour().minute()).monospacedDigit() }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}
