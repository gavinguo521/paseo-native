import PaseoKit
import SwiftUI

/// 只在本次运行中保留阅读位置，不持久化聊天内容。
@Observable @MainActor final class TimelineReadingState {
    var expanded: [String: Bool] = [:]
    var historyWindow: AgentTimeline?
    @ObservationIgnored var offset: CGFloat = 0
    @ObservationIgnored var atBottom = true
    @ObservationIgnored var hasPosition = false
    @ObservationIgnored var firstRowID: String?
    @ObservationIgnored var anchorID: String?
}

@MainActor final class TimelineHistoryCache {
    private var key: [Int] = []
    private var value: AgentTimeline?
    func snapshot(_ history: AgentTimeline?, live: AgentTimeline?) -> AgentTimeline? {
        let next = [history?.revision ?? -1, live?.revision ?? -1]
        if key != next { value = history?.includingLiveTail(live) ?? live; key = next }
        return value
    }
}

extension EnvironmentValues {
    @Entry var timelineReadingState: TimelineReadingState? = nil
}
