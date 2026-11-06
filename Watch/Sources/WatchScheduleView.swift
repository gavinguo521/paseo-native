import PaseoWatchBridge
import SwiftUI

struct WatchScheduleView: View {
    let initial: WatchSchedule
    @Environment(WatchClient.self) private var client
    @Environment(\.scenePhase) private var phase
    @State private var detail: WatchSchedule?
    @State private var refreshedAt: Date?
    @State private var problem: String?
    @State private var loading = false

    var body: some View {
        let value = detail ?? initial
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(value.title).font(.headline)
                Text(value.hostName).font(.caption2).foregroundStyle(.secondary)
                Text(WatchTheme.scheduleLabel(value.status)).font(.caption).foregroundStyle(WatchTheme.accent)
                if let next = value.nextRunAt, value.status == "active" {
                    Text("下次 \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
                }
                if !value.prompt.isEmpty { Text(value.prompt).font(.caption).watchCard() }
                ForEach(value.runs) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WatchTheme.scheduleLabel(run.status)).font(.headline)
                        if let date = run.startedAt { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                        if !run.output.isEmpty { Text(run.output).font(.caption).fixedSize(horizontal: false, vertical: true) }
                        if let agentID = run.agentID {
                            NavigationLink("查看会话", value: WatchSessionRef(hostID: value.hostID, agentID: agentID)).font(.caption)
                        }
                    }.watchCard()
                }
                if let problem { WatchProblem(message: problem) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                WatchFreshness(date: refreshedAt)
                Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .watchActionStyle(prominent: true).disabled(loading)
            }.padding(.horizontal, 2)
        }
        .navigationTitle("计划任务")
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .onChange(of: client.connectionRevision) {
            if phase == .active { Task { await load() } }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { detail = try await client.loadSchedule(initial); refreshedAt = Date(); problem = nil }
        catch is CancellationError { }
        catch { problem = error.localizedDescription }
    }
}
