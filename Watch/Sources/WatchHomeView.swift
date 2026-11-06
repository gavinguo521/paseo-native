import PaseoWatchBridge
import SwiftUI

struct WatchHomeView: View {
    @Environment(WatchClient.self) private var client
    @Environment(\.scenePhase) private var phase
    @State private var path = NavigationPath()
    @State private var choosingHost = false

    private struct RefreshKey: Equatable {
        var hostID: String?
        var section: Int
        var active: Bool
        var connectionRevision: Int
    }
    private var key: RefreshKey { .init(hostID: client.selectedHostID, section: client.section, active: phase == .active && path.isEmpty, connectionRevision: client.connectionRevision) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("会话") { client.section = 0 }
                            .foregroundStyle(client.section == 0 ? .primary : .secondary)
                        Button("任务") { client.section = 1 }
                            .foregroundStyle(client.section == 1 ? .primary : .secondary)
                        Spacer(minLength: 0)
                        Button { choosingHost = true } label: { Image(systemName: "line.3.horizontal.decrease") }
                            .accessibilityLabel("筛选主机")
                    }
                    .font(.headline).buttonStyle(.plain).padding(.vertical, 5)

                    if client.overview.hosts.count > 1 {
                        Button { choosingHost = true } label: {
                            HStack {
                                Text(client.visibleHosts.count == 1 ? client.visibleHosts[0].name : String(localized: "全部主机")).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                            }.font(.caption2)
                        }.watchActionStyle()
                    }

                    if let error = client.error { WatchProblem(message: error) }
                    ForEach(client.visibleHosts) { host in
                        if let error = client.hostErrors[host.id] { WatchProblem(message: host.name + "：" + error) }
                    }

                    if client.section == 0 {
                        ForEach(client.sessions) { session in
                            NavigationLink(value: session.ref) { WatchSessionRow(session: session) }
                                .buttonStyle(.plain)
                        }
                        if client.sessions.isEmpty && !client.refreshing { emptyState }
                    } else {
                        ForEach(client.schedules) { schedule in
                            NavigationLink(value: ScheduleDestination(value: schedule)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(schedule.title).font(.headline).lineLimit(2)
                                    Text(schedule.hostName + " · " + WatchTheme.scheduleLabel(schedule.status))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let next = schedule.nextRunAt, schedule.status == "active" {
                                        Text("下次 \(next.formatted(.relative(presentation: .numeric)))").font(.caption2).foregroundStyle(WatchTheme.accent)
                                    }
                                }.watchCard()
                            }.buttonStyle(.plain)
                        }
                        if client.schedules.isEmpty && !client.refreshing { emptyState }
                    }
                    if client.refreshing { ProgressView().frame(maxWidth: .infinity).padding(6) }
                    if client.section == 0, client.overview.pages.contains(where: { $0.hasMore && (client.selectedHostID == nil || $0.hostID == client.selectedHostID) }) {
                        Text("显示最近会话").font(.caption2).foregroundStyle(.secondary)
                    }
                    if client.section == 1, client.visibleHosts.contains(where: { client.schedulePages[$0.id]?.hasMore == true }) {
                        Text("显示最近 50 项任务").font(.caption2).foregroundStyle(.secondary)
                    }
                    WatchFreshness(date: client.refreshedAt).padding(.top, 6)
                    Button { Task { await client.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .watchActionStyle(prominent: true).disabled(client.refreshing)
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("Paseo")
            .navigationDestination(for: WatchSessionRef.self) { ref in WatchSessionView(ref: ref) }
            .navigationDestination(for: ScheduleDestination.self) { value in WatchScheduleView(initial: value.value) }
            .sheet(isPresented: $choosingHost) { WatchHostPicker() }
            .task(id: key) {
                guard key.active else { client.invalidateRefresh(); return }
                while !Task.isCancelled {
                    await client.refresh()
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                }
            }
            .onChange(of: client.pendingRoute) { _, ref in openNotification(ref) }
            .onAppear { openNotification(client.pendingRoute) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: client.section == 0 ? "bubble.left.and.bubble.right" : "calendar").font(.title2)
            if client.overview.hosts.isEmpty {
                Text("先在 iPhone 上连接主机")
            } else { Text(client.section == 0 ? "暂无会话" : "暂无计划任务") }
        }
        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private func openNotification(_ ref: WatchSessionRef?) {
        guard let ref else { return }
        path = NavigationPath()
        path.append(ref)
        client.pendingRoute = nil
    }
}

private struct ScheduleDestination: Hashable {
    let value: WatchSchedule
    static func == (a: Self, b: Self) -> Bool { a.value.id == b.value.id }
    func hash(into hasher: inout Hasher) { hasher.combine(value.id) }
}

private struct WatchHostPicker: View {
    @Environment(WatchClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                choice(String(localized: "全部主机"), id: nil)
                ForEach(client.overview.hosts) { choice($0.name, id: $0.id) }
            }.navigationTitle("主机")
        }
    }
    private func choice(_ title: String, id: String?) -> some View {
        Button { client.selectedHostID = id; dismiss() } label: {
            HStack {
                Text(title)
                Spacer()
                if client.selectedHostID == id { Image(systemName: "checkmark").foregroundStyle(WatchTheme.accent) }
            }
        }
    }
}

private struct WatchSessionRow: View {
    let session: WatchSessionSummary
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(WatchTheme.color(session.status)).frame(width: 7, height: 7).padding(.top, 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.headline).lineLimit(2)
                Text(session.hostName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(WatchTheme.label(session.status))
                    if session.status == .running, let start = session.startedAt { Text(start, style: .timer).monospacedDigit() }
                }.font(.caption2).foregroundStyle(WatchTheme.color(session.status))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 7)
        }.watchCard()
    }
}
