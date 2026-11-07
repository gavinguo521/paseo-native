import PaseoKit
import SwiftUI

struct LiveBackgroundWorkPill: View {
    let host: HostStore
    let agentId: String
    @State private var presented = false
    @State private var stopping: Set<String> = []
    @State private var stopError: String?
    private var items: [AgentBackgroundWork] { host.backgroundWork[agentId] ?? [] }
    private var loadError: String? { host.backgroundWorkErrors[agentId] }
    private var loading: Bool { host.backgroundWorkLoading.contains(agentId) }

    var body: some View {
        if !items.isEmpty || loading || loadError != nil {
            Button { presented.toggle() } label: {
                Chip {
                    Image(systemName: loadError == nil ? "terminal" : "exclamationmark.circle")
                    if loading { ProgressView().controlSize(.mini) }
                    else if loadError != nil { Text("后台任务加载失败") }
                    else { Text("\(items.count) 个后台任务") }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $presented) {
                panel
            }
        }
    }

    var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let loadError {
                    Text(loadError).font(.caption).textSelection(.enabled)
                    Button("重试") { Task { await host.refreshBackgroundWork(agentId) } }
                }
                if let stopError { Text(stopError).font(.caption).foregroundStyle(Theme.destructive) }
                ForEach(items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.description ?? item.command ?? String(localized: "后台任务"))
                            if let command = item.command, command != item.description {
                                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                            if let start = item.startedAt {
                                Text(start, style: .relative).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer(minLength: 8)
                        if item.canStop && host.supportsBackgroundWorkStop {
                            Button("停止") { stop(item) }
                                .disabled(stopping.contains(item.id) || host.state != .connected)
                            if stopping.contains(item.id) { ProgressView().controlSize(.small) }
                        }
                    }
                    Divider()
                }
            }.padding(14)
        }
        .frame(idealWidth: 360, maxWidth: 400, maxHeight: 420)
        .compactPopover()
    }

    private func stop(_ item: AgentBackgroundWork) {
        stopping.insert(item.id)
        stopError = nil
        Task {
            defer { stopping.remove(item.id) }
            do { try await host.stopBackgroundWork(item, agentId: agentId) }
            catch { stopError = String(describing: error) }
        }
    }
}
