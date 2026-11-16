import PaseoWatchBridge
import SwiftUI

/// Completed form replies use the same question/answer order as the pending form.
struct QuestionAnswerHistory: View {
    let transcript: QuestionAnswerTranscript
    var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(transcript.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 14) {
                    QuestionPrompt(text: entry.question)
                    VStack(alignment: .leading, spacing: 6) {
                        QuestionSectionLabel(title: "回答")
                        QuestionContentText(text: entry.answer)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(pending ? 0.6 : 1)
    }
}

struct QuestionPrompt: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuestionSectionLabel(title: "提问")
            QuestionContentText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuestionSectionLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(.system(size: Theme.base)).foregroundStyle(Theme.muted)
    }
}

private struct QuestionContentText: View {
    let text: String
    @Environment(\.findQuery) private var findQuery
    @State private var expanded = false
    private var long: Bool { text.count > 900 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 14 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text({ var value = AttributedString(text); highlight(&value, findQuery); return value }())
                .font(.system(size: Theme.content)).lineSpacing(MarkdownView.lineSpacing)
                .textSelection(.enabled)
                .lineLimit(long && !expanded && findQuery.isEmpty ? 14 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if long {
                Button(expanded ? "收起" : "显示全部") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
    }
}
