import PaseoWatchBridge
import SwiftUI

struct WatchReplyView: View {
    let ref: WatchSessionRef
    let title: String
    @Environment(WatchClient.self) private var client
    @State private var text = ""
    @State private var busy = false
    @State private var result: WatchActionResult?
    @State private var loadedDraft = false
    @AppStorage("watch.dictationHintSeen") private var dictationHintSeen = false

    private var hasPending: Bool { client.pendingActions[ref.id + "/reply"] != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if !text.isEmpty {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .watchControlPreviewStyle()
                }
                TextFieldLink(prompt: Text("回复")) {
                    Label(text.isEmpty ? "开始听写" : "重新听写", systemImage: "mic.fill").frame(maxWidth: .infinity)
                } onSubmit: { @Sendable value in
                    Task { @MainActor in
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        // Persist before the system input controller returns to this view.
                        // A reappearance must not replace the new transcript with an old draft.
                        client.saveDraft(value, for: ref)
                        dictationHintSeen = true
                        text = value; result = nil
                    }
                }
                .watchActionStyle().disabled(busy || hasPending)
                if !dictationHintSeen {
                    Text("在输入页右下角选择麦克风听写")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button { send() } label: {
                    Text(hasPending ? "重试并核对" : "发送").frame(maxWidth: .infinity)
                }
                    .watchActionStyle(prominent: true)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView("正在发送…") }
                if let result, result.state != .confirmed {
                    Text(result.message).font(.caption)
                        .foregroundStyle(.orange)
                }
            }.padding(.horizontal, 2)
        }.navigationTitle("语音回复")
        .onAppear {
            guard !loadedDraft else { return }
            loadedDraft = true
            text = client.savedReply(for: ref) ?? ""
        }
        .onChange(of: text) { _, value in client.saveDraft(value, for: ref) }
    }

    private func send() {
        busy = true
        Task {
            let value = await client.perform(.reply(ref, text: text))
            result = value
            busy = false
            if value.state == .confirmed { text = ""; client.saveDraft("", for: ref) }
        }
    }
}
