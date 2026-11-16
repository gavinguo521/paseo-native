import SwiftUI
import PaseoKit

/// 输入框上方的「后台任务」胶囊（官方 0.16.0 background work）：daemon 给出列表，可以单独停止。
/// 只在 daemon 有 agentBackgroundWork 能力位时使用；列表为空且快照计数为 0 时不占位。
struct BackgroundWorkPill: View {
    let host: HostStore
    let agentId: String
    @State private var showList = false

    private var state: BackgroundWorkState? { host.backgroundWork[agentId] }
    private var items: [BackgroundWorkItem] { state?.items ?? [] }
    /// 列表到手前用快照里的计数（官方同样：items.length || count）。
    private var visibleCount: Int {
        items.isEmpty ? (host.agents[agentId]?.backgroundWorkCount ?? 0) : items.count
    }

    var body: some View {
        let n = visibleCount
        if n > 0 {
            Button { showList.toggle() } label: {
                Chip {
                    Image(systemName: "terminal")
                    ViewThatFits(in: .horizontal) {
                        Text("\(n) 个后台任务").fixedSize()
                        Text("\(n)").fixedSize()
                    }
                    ProgressView().controlSize(.mini)
                }
            }
            .buttonStyle(.plain)
            .help("\(n) 个后台任务运行中")
            .accessibilityLabel("\(n) 个后台任务运行中")
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                list.compactPopover()
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("后台任务").font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if let error = state?.error {
                HStack(spacing: 8) {
                    Text("无法加载后台任务").font(.system(size: 12)).foregroundStyle(Theme.muted).help(error)
                    Spacer(minLength: 0)
                    Button("重试") { Task { await host.loadBackgroundWork(agentId) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            } else if state?.items == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在等待后台任务详情").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        BackgroundWorkRow(item: item, stop: item.stopToken.flatMap { state?.stops[$0] },
                                          canStop: host.canStopBackgroundWork(item)) {
                            Task { await host.stopBackgroundWork(agentId, item) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 420)
        }
        #if os(iOS)
        .frame(width: 340)
        #else
        .frame(width: 400)
        #endif
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 后台任务列表里的一行：标题（说明或命令）、命令、种类与已运行时长，可停止的带「停止」按钮。
private struct BackgroundWorkRow: View {
    let item: BackgroundWorkItem
    let stop: BackgroundWorkState.Stop?
    let canStop: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? kindLabel).font(.system(size: 13)).lineLimit(2)
                if let command = item.commandDetail {
                    Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Group {
                    if let start = item.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("\(kindLabel) · 已运行 \(formatDuration(max(0, context.date.timeIntervalSince(start))))")
                        }
                    } else {
                        Text(kindLabel)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                if case .failed(let message) = stop {
                    Text("无法确认已停止：\(message)").font(.system(size: 11)).foregroundStyle(Theme.destructive).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if canStop {
                Button(action: onStop) {
                    if stop == .pending {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("正在停止…")
                        }
                    } else {
                        Text("停止")
                    }
                }
                .controlSize(.small)
                .disabled(stop == .pending)
                .accessibilityLabel("停止 \(item.title ?? kindLabel)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var kindLabel: String {
        switch item.kind {
        case .shell: String(localized: "Shell")
        case .monitor: String(localized: "监控")
        case .other: String(localized: "其他任务")
        }
    }

    private var icon: String {
        switch item.kind {
        case .shell: "terminal"
        case .monitor: "waveform.path.ecg"
        case .other: "gearshape"
        }
    }
}
