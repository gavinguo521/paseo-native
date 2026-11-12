import PaseoWatchBridge
import SwiftUI

struct WatchQuestionView: View {
    let ref: WatchSessionRef
    let sessionTitle: String
    let permission: WatchPermission
    let form: WatchQuestionForm
    @Environment(WatchClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var answers: [String: WatchQuestionAnswer] = [:]
    @State private var busy = false
    @State private var result: WatchActionResult?

    private var pending: WatchRequest? { client.pendingActions[ref.id + "/permission/" + permission.id] }
    private var editingDisabled: Bool { busy || pending != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sessionTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if form.questions.indices.contains(step) {
                        let question = form.questions[step]
                        if form.questions.count > 1 {
                            Text("第 \(step + 1) / \(form.questions.count) 题")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        WatchQuestionPrompt(text: question.text)
                        WatchQuestionSectionLabel(title: "回答")
                        if question.multiSelect { Text("可多选").font(.caption2).foregroundStyle(.secondary) }
                        ForEach(question.options) { option in optionButton(option, question: question) }
                        if question.allowsOther {
                            TextFieldLink(prompt: Text("回答")) {
                                Label(question.options.isEmpty ? "输入回答" : "其他回答", systemImage: "mic.fill")
                                    .frame(maxWidth: .infinity)
                            } onSubmit: { @Sendable value in
                                Task { @MainActor in
                                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                    answers[question.id] = .init(text: value)
                                    result = nil
                                }
                            }
                            .watchActionStyle().disabled(editingDisabled)
                            if let text = answers[question.id]?.text, !text.isEmpty {
                                Text(text).fixedSize(horizontal: false, vertical: true).watchControlPreviewStyle()
                            }
                        }
                        if step > 0 {
                            Button("上一题") { step -= 1 }.watchActionStyle().disabled(editingDisabled)
                        }
                        if let pending {
                            Button("重试并核对") { run(pending.command, answers: pending.questionAnswers) }
                                .watchActionStyle(prominent: true).disabled(busy)
                        } else if step + 1 < form.questions.count {
                            Button("下一题") { step += 1 }.watchActionStyle(prominent: true)
                                .disabled(busy || !canContinue(question))
                        } else if let action = permission.actions.first(where: { $0.behavior == "allow" }) {
                            Button("提交") { run(command(action), answers: answers) }
                                .watchActionStyle(prominent: true)
                                .disabled(busy || (try? form.validatedAnswers(answers)) == nil)
                        }
                        if pending == nil, let skip = permission.actions.first(where: { $0.behavior == "deny" }) {
                            Button("跳过") { run(command(skip), answers: nil) }.watchActionStyle().disabled(busy)
                        }
                    }
                    if busy { ProgressView("正在提交…").frame(maxWidth: .infinity) }
                    if let result, result.state != .confirmed { WatchProblem(message: result.message) }
                }
                .padding(.horizontal, 2)
                .id("question-top")
            }
            .onChange(of: step) { proxy.scrollTo("question-top", anchor: .top) }
        }
        .navigationTitle("回答问题")
        .onAppear {
            if let saved = pending?.questionAnswers { answers = saved }
        }
    }

    private func optionButton(_ option: WatchQuestionOption, question: WatchQuestion) -> some View {
        let selected = answers[question.id]?.selectedOptions.contains(option.label) == true
        return Button {
            var labels = question.multiSelect ? (answers[question.id]?.selectedOptions ?? []) : []
            if selected { labels.removeAll { $0 == option.label } }
            else { labels.append(option.label) }
            answers[question.id] = .init(selectedOptions: labels)
            result = nil
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: question.multiSelect
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label).fixedSize(horizontal: false, vertical: true)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let preview = option.preview, !preview.isEmpty {
                        Text(preview).font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .watchActionStyle(prominent: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .disabled(editingDisabled)
    }

    private func canContinue(_ question: WatchQuestion) -> Bool {
        guard let answer = answers[question.id] else { return false }
        return (try? question.answerText(answer)) != nil
    }

    private func command(_ action: WatchPermissionAction) -> WatchCommand {
        .permission(ref, requestID: permission.id, revision: permission.revision, actionID: action.id)
    }

    private func run(_ command: WatchCommand, answers: [String: WatchQuestionAnswer]?) {
        busy = true
        Task {
            let response = await client.perform(command, questionAnswers: answers)
            result = response
            busy = false
            if response.state == .confirmed { dismiss() }
        }
    }
}
