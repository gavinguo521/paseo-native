// 灵动岛 / 锁屏实时活动的各块视图。Widget 扩展用它们拼活动；App 的 DEBUG 渲染（PASEO_RENDER_ACTIVITY）也用，便于在没有模拟器界面时核对排版。

#if os(iOS)
import SwiftUI

struct ActivityStatusIcon: View {
    let state: PaseoActivityAttributes.ContentState
    var body: some View {
        if state.waiting > 0 {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        } else if state.running > 0 {
            Image(systemName: "sparkles").foregroundStyle(.green)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct ActivityCompactTrailing: View {
    let state: PaseoActivityAttributes.ContentState
    var body: some View {
        if state.waiting > 0 {
            Text("待处理").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        } else if let since = state.rows.filter({ $0.status == "running" }).compactMap(\.sinceDate).min() {
            // 最久那个会话已经跑了多久；系统在手机上自己走秒，不用推送。
            Text(since, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 52)
                .foregroundStyle(.green)
        } else {
            Text("运行中").font(.caption).foregroundStyle(.green)
        }
    }
}

struct ActivitySummary: View {
    let state: PaseoActivityAttributes.ContentState
    var body: some View {
        if !state.isActive {
            Text("全部完成").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                if state.waiting > 0 { Text("\(state.waiting) 待处理").foregroundStyle(.orange) }
                if state.running > 0 { Text("\(state.running) 运行中").foregroundStyle(.green) }
                if state.failed > 0 { Text("\(state.failed) 出错").foregroundStyle(.red) }
            }
            .monospacedDigit()
        }
    }
}

struct ActivityRows: View {
    let state: PaseoActivityAttributes.ContentState
    let limit: Int

    var body: some View {
        let shown = Array(state.rows.prefix(limit))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { row in
                if let url = PaseoActivityLink.url(serverId: row.serverId, agentId: row.agentId) {
                    Link(destination: url) { ActivityRowView(row: row, showsHost: state.showsHost) }.tint(.primary)
                } else {
                    ActivityRowView(row: row, showsHost: state.showsHost)
                }
            }
            let rest = state.running + state.waiting + state.failed - shown.count
            if rest > 0 {
                Text("还有 \(rest) 个").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ActivityRowView: View {
    let row: PaseoActivityAttributes.Row
    let showsHost: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            // 机器名放得下才显示（放不下宁可不显示，也不截成一个字母）。
            if showsHost {
                ViewThatFits(in: .horizontal) {
                    names(host: true)
                    names(host: false)
                }
            } else {
                names(host: false)
            }
            Spacer(minLength: 4)
            trailing.font(.caption).monospacedDigit()
        }
    }

    /// 同侧栏两层：先项目名（加粗），后工作区名（灰字）；旧版插件不带项目名时只显示标题。
    @ViewBuilder private func names(host: Bool) -> some View {
        HStack(spacing: 6) {
            if let project = row.project, !project.isEmpty {
                Text(project).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                    .layoutPriority(1)
                Text(row.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            } else {
                Text(row.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
            }
            if host {
                Text(row.host).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    private var color: Color {
        switch row.status {
        case "waiting": .orange
        case "failed": .red
        default: .green
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.status {
        case "waiting": Text("等你处理").foregroundStyle(.orange)
        case "failed": Text("出错").foregroundStyle(.red)
        default:
            if let since = row.sinceDate {
                Text(since, style: .timer).multilineTextAlignment(.trailing).frame(maxWidth: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
            } else {
                Text("运行中").foregroundStyle(.secondary)
            }
        }
    }
}

struct ActivityFootnote: View {
    let state: PaseoActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("可能不是最新：机器连不上或很久没有更新").font(.caption2).foregroundStyle(.secondary)
        } else if !state.offline.isEmpty {
            Text(String(localized: "连不上：\(state.offline.joined(separator: String(localized: "、", comment: "列举时的分隔符（顿号）")))")).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct ActivityLockScreen: View {
    let state: PaseoActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label { Text("Paseo").font(.headline) } icon: { ActivityStatusIcon(state: state) }
                Spacer()
                ActivitySummary(state: state).font(.subheadline)
            }
            if state.isActive {
                ActivityRows(state: state, limit: 3)
            }
            ActivityFootnote(state: state, isStale: isStale)
        }
        .padding(14)
    }
}

#if DEBUG
/// 预览和 PASEO_ACTIVITY_DEMO=1 渲染用的演示数据：两台机器、一个等你处理。
extension PaseoActivityAttributes.ContentState {
    static let preview: Self = {
        // 会话标题是用户数据、不走翻译：英文环境（截英文 README 配图）换一套英文示例
        let en = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
        return Self(
            updatedAt: Date().timeIntervalSince1970, running: 2, waiting: 1, failed: 0,
            rows: [
                .init(serverId: "s1", agentId: "a1", host: "Mac Studio", title: en ? "Fix login page styles" : "修复登录页样式",
                      project: "web-app", status: "waiting", since: nil),
                .init(serverId: "s1", agentId: "a2", host: "Mac Studio", title: en ? "Dynamic Island support" : "灵动岛适配",
                      project: "paseo-native", status: "running", since: Date().addingTimeInterval(-754).timeIntervalSince1970),
                .init(serverId: "s2", agentId: "a3", host: "Mac mini", title: en ? "Database migration" : "数据库迁移",
                      project: "api-server", status: "running", since: Date().addingTimeInterval(-62).timeIntervalSince1970),
            ],
            offline: [])
    }()
}
#endif
#endif
