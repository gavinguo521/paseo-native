import PaseoWatchBridge
import SwiftUI

struct WatchSessionView: View {
    let ref: WatchSessionRef
    @Environment(WatchClient.self) private var client
    @Environment(\.scenePhase) private var phase
    @State private var detail: WatchSessionDetail?
    @State private var problem: String?
    @State private var loading = false
    @State private var replying = false
    @State private var permission: WatchPermission?
    @State private var question: WatchPermission?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if let detail {
                    Text(detail.session.title).font(.headline)
                    Text(detail.session.hostName).font(.caption2).foregroundStyle(.secondary)
                    Text(WatchTheme.label(detail.session.status)).font(.caption2)
                        .foregroundStyle(WatchTheme.color(detail.session.status))
                    Button { replying = true } label: { Label("回复", systemImage: "mic.fill").frame(maxWidth: .infinity) }
                        .watchActionStyle(prominent: true)
                    ForEach(detail.permissions) { request in
                        Button {
                            if request.questionForm != nil, !request.needsPhone { question = request }
                            else { permission = request }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if request.kind == "question" {
                                    Label("回答问题", systemImage: "questionmark.bubble.fill").foregroundStyle(.orange)
                                    Text(request.detail).lineLimit(2)
                                } else {
                                    Label("请求批准", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                                    Text(request.title).lineLimit(2)
                                }
                            }.font(.caption).watchCard()
                        }.buttonStyle(.plain)
                    }
                    // Keep the bridge's timeline order; show newest messages first on the watch.
                    ForEach(detail.messages.reversed()) { message in
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
                    if detail.messages.isEmpty { Text("暂无消息").font(.caption).foregroundStyle(.secondary) }
                    WatchFreshness(date: detail.refreshedAt)
                }
                if let problem { WatchProblem(message: problem) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .watchActionStyle(prominent: true).disabled(loading)
            }.padding(.horizontal, 2)
        }
        .navigationTitle("会话")
        // Present reply input in the navigation stack. watchOS owns the subsequent system
        // keyboard/dictation presentation; avoid nesting it inside our own modal sheet.
        .navigationDestination(isPresented: $replying) {
            WatchReplyView(ref: ref, title: detail?.session.title ?? String(localized: "会话"))
        }
        .onChange(of: replying) {
            if !replying { Task { await load() } }
        }
        .navigationDestination(isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } })) {
            if let question, let form = question.questionForm {
                WatchQuestionView(ref: ref, sessionTitle: detail?.session.title ?? "", permission: question, form: form)
            }
        }
        .onChange(of: question) {
            if question == nil { Task { await load() } }
        }
        .sheet(item: $permission, onDismiss: { Task { await load() } }) { request in
            WatchPermissionView(ref: ref, sessionTitle: detail?.session.title ?? "", hostName: detail?.session.hostName ?? "", permission: request)
        }
        .task(id: phase) {
            guard phase == .active else { return }
            if detail == nil { detail = client.details[ref.id] }
            while !Task.isCancelled {
                if !replying && permission == nil && question == nil { await load() }
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .onChange(of: client.connectionRevision) {
            if phase == .active, !replying, permission == nil, question == nil { Task { await load() } }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { detail = try await client.loadSession(ref); problem = nil }
        catch is CancellationError { }
        catch { problem = error.localizedDescription }
    }
}

private struct WatchPermissionView: View {
    let ref: WatchSessionRef
    let sessionTitle: String
    let hostName: String
    let permission: WatchPermission
    @Environment(WatchClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var result: WatchActionResult?

    private var pending: WatchRequest? { client.pendingActions[ref.id + "/permission/" + permission.id] }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sessionTitle).font(.caption).lineLimit(3)
                    Text(hostName).font(.caption2).foregroundStyle(.secondary)
                    Text(permission.title).font(.headline)
                    Text(permission.detail).font(permission.kind == "question" ? .caption : .system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true).watchCard()
                    if permission.needsPhone {
                        WatchProblem(message: String(localized: "此请求无法在手表上完整处理，请在 iPhone 上查看"))
                    } else if result?.state != .confirmed {
                        if let pending {
                            Button("重试并核对") { run(pending.command) }.watchActionStyle(prominent: true).disabled(busy)
                        } else {
                            ForEach(permission.actions) { action in
                                Button(action.label) {
                                    run(.permission(ref, requestID: permission.id, revision: permission.revision, actionID: action.id))
                                }.watchActionStyle(prominent: action.behavior == "allow").disabled(busy)
                            }
                        }
                    }
                    if busy { ProgressView("正在处理…") }
                    if let result {
                        Text(result.message).font(.caption)
                            .foregroundStyle(result.state == .confirmed ? WatchTheme.accent : .orange)
                    }
                    if result?.state == .confirmed { Button("完成") { dismiss() }.watchActionStyle() }
                }.padding(.horizontal, 2)
            }.navigationTitle(permission.kind == "question" ? String(localized: "回答问题") : String(localized: "请求批准"))
        }
    }
    private func run(_ command: WatchCommand) {
        busy = true
        Task { result = await client.perform(command); busy = false }
    }
}
