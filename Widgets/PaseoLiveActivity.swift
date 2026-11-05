// 灵动岛与锁屏实时活动：所有机器合成一个活动，显示运行中 / 等你处理的会话。

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PaseoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PaseoLiveActivity()
    }
}

struct PaseoLiveActivity: Widget {
    typealias State = PaseoActivityAttributes.ContentState

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PaseoActivityAttributes.self) { context in
            ActivityLockScreen(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text("Paseo").font(.headline) } icon: { ActivityStatusIcon(state: s) }
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivitySummary(state: s).font(.subheadline).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ActivityRows(state: s, limit: 3)
                        ActivityFootnote(state: s, isStale: context.isStale)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    ActivityStatusIcon(state: s)
                    Text("\(s.running + s.waiting)").monospacedDigit()
                }
            } compactTrailing: {
                ActivityCompactTrailing(state: s)
            } minimal: {
                if s.waiting > 0 {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                } else {
                    Text("\(s.running)").monospacedDigit().foregroundStyle(.green)
                }
            }
            .widgetURL(firstURL(s))
            .keylineTint(s.waiting > 0 ? .orange : .green)
        }
    }

    /// 点灵动岛本体（不是某一行）：有等你处理的就打开它，否则打开第一行。
    private func firstURL(_ s: State) -> URL? {
        s.rows.first.flatMap { PaseoActivityLink.url(serverId: $0.serverId, agentId: $0.agentId) }
    }
}

#if DEBUG
#Preview("锁屏", as: .content, using: PaseoActivityAttributes()) {
    PaseoLiveActivity()
} contentStates: {
    PaseoActivityAttributes.ContentState.preview
}

#Preview("展开", as: .dynamicIsland(.expanded), using: PaseoActivityAttributes()) {
    PaseoLiveActivity()
} contentStates: {
    PaseoActivityAttributes.ContentState.preview
}
#endif
